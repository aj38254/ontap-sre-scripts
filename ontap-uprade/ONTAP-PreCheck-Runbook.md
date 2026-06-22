# ONTAP Pre-Check Runbook (real, step-by-step)

Simple walkthrough for running ONTAP upgrade **pre-checks**, based on what we
actually did for **US-E4 AP TST**. Replace the env-specific values when reusing.

Example values used here:

- Cluster CLI: `ssh admin@192.168.208.20`  (prompt `us-qas-gc-cl-d11c11305r102-aptst::>`)
- Jumphost VM: `cv-ap-tst-us-east4-k8s-lmgmt-2-a`  (internal IP `192.168.214.20`, zone `us-east4-a`)
- Project: `netapp-us-e4-autopush-sde-tst`  | Region: `us-east4`
- Target build: **9.18.1P4** (note the X3 — use the exact string the repo shows)

Login steps: see `ONTAP-Login-Access-Reference.md`.
Full doc: [https://netapp.atlassian.net/wiki/spaces/COPS/pages/105975461/How+To+-+GCP+-+Upgrade+ONTAP+cluster](https://netapp.atlassian.net/wiki/spaces/COPS/pages/105975461/How+To+-+GCP+-+Upgrade+ONTAP+cluster)

> Tip: turn on terminal logging / copy all output — paste results into the ticket for audit.
> Know your prompt: `...::>` = ONTAP cluster CLI (ONTAP commands only).
> `user@...-lmgmt...:~$` = jumphost Linux shell (gsutil/gcloud/python3).

---



## PART 0 — Login & gcloud auth

You go: **laptop → jumphost VM → ONTAP cluster CLI**. (Full detail in `ONTAP-Login-Access-Reference.md`.)

### 0.1 One-time prerequisites

- IAM account on the project + correct role.
- Your SSH public key in **Compute Engine → Settings → Metadata → SSH keys**.
  - Check: `ls ~/.ssh/*.pub` then `cat ~/.ssh/id_rsa.pub`
  - Create if missing: `ssh-keygen -t rsa -b 4096 -C "your_email@netapp.com"`



### 0.2 SSH into the jumphost VM (from laptop)

```bash
gcloud auth login
gcloud config set project netapp-us-e4-autopush-sde-tst
gcloud compute instances list                 # find the jumphost name + zone
gcloud compute ssh cv-ap-tst-us-east4-k8s-lmgmt-2-a --zone us-east4-a --tunnel-through-iap
```

Prompt becomes: `aj38254@cv-ap-tst-us-east4-k8s-lmgmt-2-a:~$`

### 0.3 Become root + auth gcloud (do BEFORE any gsutil/kubectl)

```bash
sudo su
gcloud auth login        # copy URL into an INCOGNITO browser, sign in with NetApp SSO,
                         # paste the verification code back
gcloud auth list         # confirm your @netapp.com account is ACTIVE
```

Why: skipping this gives `Failed to retrieve access token ... invalid_grant: Bad Request`
on gsutil/kubectl. Also `kubectl: command not found` after `sudo su` = PATH issue → use
full path or `sudo kubectl ...`.

### 0.4 SSH into the ONTAP cluster (from the jumphost)

```bash
ssh admin@192.168.208.20        # admin password from berglas (Manage GCP Secrets doc)
```

First time it asks to trust the host key → type `yes`.
Prompt becomes: `us-qas-gc-cl-d11c11305r102-aptst::>` — you're now on the ONTAP CLI.

> To bounce back to the jumphost (e.g. to run gsutil), type `exit` on the cluster prompt.

---



## PART A — Health pre-checks (NO image needed)

These run straight on the cluster CLI. Do these first; they don't depend on the image.

### A0. Record identity & current version

```
cluster show
version
cluster image show
system node show
```

Note the current version (we saw **9.16.1P6**, model AFF-A700s, 2 nodes).

### A1. Enter diag mode

```
set -privilege diagnostic
rows 0
```

(answer `y`)

### A2. Health checks — each MUST return "There are no entries matching your query."

```
volume show -state !online
volume show -is-inconsistent true
storage aggregate show -state !online
storage aggregate show -inconsistent true
storage aggregate show -raidstatus !*normal*
storage disk show -state maintenance|pending|reconstructing|broken
storage disk show -state !spare,!present
storage failover show -possible false
system chassis show -status !ok
system controller config show-errors -description !"sysconfig: There are no configuration errors."*
system controller environment show -status !ok
system controller memory dimm show -status !ok
system fru-check show -fru-status !pass
system node environment sensors show -state !normal
storage port show -errors
disk partition show -container-type !aggregate,!spare
net int show -status-admin !up
net int show -status-oper !up
net int show -is-home false
security key-manager external show-status -key-server-status !available
security key-manager external gcp check -category service_reachability -status !OK

system health subsystem show -health !ok
system health alert show
flexcache show
debug smdb table ssh show -vserver !svm*

### Extra checks ###
debug smdb table ssh show #### any bare numeric vserver (no svm_ name, host-key-algorithms = "-") is a stale orphan → delete before upgrading
```

Any output = a finding → raise a COPS pre-check ticket and fix.
Special case: `storage disk show -state !spare,!present` showing **Container type = unknown**
→ open an NFSAAS support case (not a blocker).

### A3. Network redundancy

```
ifgrp show
```

Every node must list its ifgrp with **>= 2 ports** (we saw `a0a = e2a, e4a`).

### A4. Bootargs

```
run -node * -command "priv set diag;bootargs get bootarg.keymanager.ekmip.svm_context"
run -node * -command "priv set diag;bootargs get bootarg.cloud_optimized"
run -node * -command "priv set diag;bootargs get bootarg.disable.volume_handler"
run -node * -command "priv set diag;bootargs get bootarg.vsun.connect_timeout"

----------------------------------------------------------------------------------
run -node * -command "priv set diag; bootargs set bootarg.disable.volume_handler true"
run -node * -command "priv set diag; bootargs set bootarg.vsun.connect_timeout 10"
```

Expected: `svm_context = false`, `cloud_optimized = true`, `disable.volume_handler = true`.

### A5. Capture config baseline (for pre/post compare)

```
version
date
ntp server show
dns show
sp show
network device-discovery show
system cluster-switch show
disk error show
cluster show
cluster ring show
storage disk show -broken
system health alert show
system health status show
system controller show
system controller flash-cache show
storage disk show -fields firmware-revision,model
storage shelf show -connectivity -shelf *
cluster image show-update-progress -subsystem-status !completed
```



### A6. Large-volume flag

```
vol show -size >98T -fields is-large-size-enabled
```

If any volume returns, its flag must be **enabled**.

---



## PART B — Stage the image (needed ONLY for `cluster image validate`)

`cluster image validate` fails with **"package does not exist on the system"** until the
image is staged. Health checks (Part A) don't need this.

### Problems we hit (and the fixes)

1. `**gsutil` not recognized** → you were on the **cluster CLI**. `gsutil` runs on the
  **jumphost** Linux shell. `exit` the cluster, run it on the jumphost.
2. **403 AccessDenied on** `gs://ontap-images/` → no access to the shared bucket.
  Fix: we were told to **use any non-prod bucket we can write to** in our own project.
3. `**gcloud compute scp` Permission denied (publickey)** → don't bother; use a bucket.



### B1. Put the image in a bucket you own (laptop or jumphost)

```bash
gcloud auth login
gcloud config set project netapp-us-e4-autopush-sde-tst
gsutil mb -l us-east4 gs://ontap-img-aptst-aj/        # create (name must be globally unique)
```

Upload the image (Console: Cloud Storage → bucket → UPLOAD, or gsutil):

```bash
gsutil cp 9181P4_q_image.tgz gs://ontap-img-aptst-aj/
```

(For post-checks later also upload `all.zip`, `all_shelf_fw.zip`, `qual_devices.zip`.)

### B2. On the jumphost — pull the image to /root

```bash
sudo su
cd /root
gsutil cp gs://ontap-img-aptst-aj/9181P4_q_image.tgz .
md5sum 9181P4_q_image.tgz          # compare with NetApp Support Site md5; record in ticket
hostname -I                          # note jumphost internal IP (192.168.214.20)
```



### B3. Serve it over HTTP (keep this terminal open)

```bash
cd /root
sudo python3 -m http.server 80
```

If port 80 is busy: `sudo lsof -i :80` then `sudo kill <pid>`.

### B4. Firewall (only if the cluster can't reach the jumphost)

Internal cluster→jumphost traffic was already allowed for us, so **try B5 first**.
If the pull hangs, create a temporary rule (delete it at closeout):

```bash
gcloud compute firewall-rules create temp-ontap-image-pull-aptst \
  --project netapp-us-e4-autopush-sde-tst --network <jumphost-vpc> \
  --direction INGRESS --action ALLOW --rules tcp:80,tcp:8080 \
  --source-ranges 192.168.208.20/32 --priority 900
# closeout:
# gcloud compute firewall-rules delete temp-ontap-image-pull-aptst --project netapp-us-e4-autopush-sde-tst

# delete it
gcloud compute firewall-rules delete tmp-ontap-img-pull-80 -q
```



### B5. Pull the image onto the cluster (cluster CLI)

```
cluster image package get -url http://192.168.214.20/9181P4_q_image.tgz
cluster image package show-repository
```

`show-repository` should list the new build — for us it registered as **9.18.1P4**
(use that exact string from here on; it's not plain `9.17.1P9`).

---



## PART C — Validate (the image-dependent pre-check)



### C1. Run validate

```
set diag
cluster image validate -version 9.18.1P4 -show-validation-details true
```

This kicks off async checks; the WARNING about "manual checks" is normal.

### C2. Read the results

```
cluster image show-update-progress -subsystem-status !completed
```

Re-run until **Status = completed**, then check every row:

- `OK` = good
- `Warning` = scan it (encryption warnings below are standard)
- `Error` = must fix before upgrade

Our result: **completed, 0 errors**, 2 standard warnings:

- **Cloud keymanager connectivity check** (Warning)
- **External keymanager key server status check** (Warning)

> `cluster image show-update-progress` is read-only — it only shows validation
> status, it does NOT start an upgrade. Do **not** run `cluster image update` during pre-checks.

---



## Findings to log for US-E4 AP TST

1. **GCP KMS AUTH_FAILED** (`security key-manager external gcp check` returned FAILED;
  validate also warned on cloud keymanager). **BLOCKER** — get SRE to fix the GCP KMS
   service-account auth before the upgrade window. Verify with:
2. **Switchless-cluster alert** (`Switch-Health degraded` / `ClusterSwitchlessConfig_Alert`)
  on this 2-node cluster. Verify then fix:
   Confirm `system health alert show` clears.

---



## Pre-checks DONE when

- Part A clean (findings logged), bootargs match, baseline captured.
- Image staged (Part B), `cluster image validate` (Part C) = **completed, no errors**.
- Findings ticketed (KMS = blocker).
- **STOP here.** `cluster image update` happens only in the scheduled upgrade window.

