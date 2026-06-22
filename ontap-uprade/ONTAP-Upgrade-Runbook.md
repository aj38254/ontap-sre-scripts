# ONTAP Upgrade Runbook (execution + post-upgrade)

Simple step-by-step for the **actual upgrade**, continuing after pre-checks pass.
Based on the How-To: GCP - Upgrade ONTAP cluster
(https://netapp.atlassian.net/wiki/spaces/COPS/pages/105975461).

Do `ONTAP-PreCheck-Runbook.md` first. Login: `ONTAP-Login-Access-Reference.md`.

Example values (US-E4 AP TST — swap per env):
- Cluster CLI: `ssh admin@192.168.208.20`  (`us-qas-gc-cl-d11c11305r102-aptst::>`)
- Jumphost: `cv-ap-tst-us-east4-k8s-lmgmt-2-a`  (internal IP `192.168.214.20`)
- Target build: **9.18.1P4** (use the exact string `cluster image package show-repository` shows)

> ⚠ Only run this during the approved change window. Don't start until:
> pre-checks clean, image staged + validated, change approved, alerts silenced,
> and the **GCP KMS check is healthy** (no AUTH_FAILED).

---

## PART 1 — Just before the upgrade (pre-upgrade tasks)

1. **Inform Google** a few days ahead (External GCNV G-Chat "(External) ONTAP Upgrade").
   Per the doc this is also where probers are handled — confirm with Google on-call before proceeding.
2. **Multi-stamp regions:** pin an internal project (e.g. cv-car-customer-zero) to the stamp
   and test volume creation (Jenkins / slack bot / GCP console).
3. **Run the region workflow:** `control_and_data_plane` for your region (GCP Workflows).
4. *(optional)* Reboot the SPs one node at a time:
   ```
   sp show
   reboot-sp -node <node>
   ```
5. **Start-of-maintenance autosupport:**
   ```
   autosupport invoke -node * -type all -message "MAINT=<no_of_hours>h Starting ANDU"
   ```
6. **Change approved** (reviewed & approved) and status/maintenance entry set.
7. **Silence ONTAP alerts** — via the incident manager / linked Service Request.
8. **Large volumes flag:**
   ```
   vol show -size >98T -fields is-large-size-enabled      (any output must be 'enabled')
   ```
9. **Encryption-keys edge case** — only if validate flagged "encryption keys unavailable":
   ```
   security key-manager key query -restored false          (expect: no entries)
   ```
   If keys are confirmed restored, the upgrade can use `-skip-validation true` (Part 2).

---

## PART 2 — Upgrade

> Inform Google on-call: **upgrade START time**.

1. **Start the update** (exact version string):
   ```
   cluster image update -version 9.18.1P4
   ```
   (Only add `-skip-validation true` if you handled step 9 above and keys are restored.)
2. **Monitor to completion:**
   ```
   cluster image show-update-progress
   ```
   Re-run until it reports the update completed across both nodes.
3. **First device in a region only** — update default limits via rt-api-server from the
   jumphost (full curl block is in the How-To; needs ONTAP model + major.minor version,
   e.g. `9.17.1` not `9.18.1P4`).
4. **Re-add SMDB roles** (wiped by the reboot during upgrade):
   ```
   debug smdb table profile create -role external-peer -access readonly -tablename xc_vserver_by_name
   debug smdb table profile create -role external-peer -access readonly -tablename xc_nameVvolTable
   ```

---

## PART 3 — Post-upgrade tasks

1. **Confirm completion:**
   ```
   cluster image show-update-progress        (must show completed)
   version                                   (shows the new build)
   ```
2. **Re-run ALL health checks** from `ONTAP-PreCheck-Runbook.md` Part A — everything must
   still be clean (compare against the baseline you captured).
3. **Run the region workflow** (`control_and_data_plane`) again.
4. **Update backup image + disk firmware + DQP + shelf firmware** (jumphost http.server must
   be serving the files — `all.zip`, `qual_devices.zip`, `all_shelf_fw.zip`):
   ```
   set -privilege advanced
   system node image show
   system node image update -node * -package http://192.168.214.20/<image-name>
   storage firmware download -node * -package-url http://192.168.214.20/all.zip
   storage firmware download -node * -package-url http://192.168.214.20/qual_devices.zip
   storage firmware download -node * -package-url http://192.168.214.20/all_shelf_fw.zip
   ```
5. **NFSv4.2 volumes present?** Apply the fix in KB CONTAP-120160.
6. **Re-enable ONTAP alerts** (inform the incident manager — undo the silence).

> Inform Google on-call: **upgrade END time**.

---

## PART 4 — Closeout

1. **End-of-maintenance autosupport:**
   ```
   autosupport invoke -node * -type all -message "MAINT=END ANDUCOMPLETE"
   ```
2. **Close the change** and update the status/maintenance entry to completed.
3. **Update Slack** (upgrade channel) with the result.
4. **Revert the firewall** — remove ports `80,8080` and the ONTAP IP from the iap rule
   (or delete the temp rule):
   ```
   gcloud compute firewall-rules delete temp-ontap-image-pull-aptst --project netapp-us-e4-autopush-sde-tst
   ```
   Stop the jumphost `python3 -m http.server` (Ctrl-C).
5. **Check 1P metrics flow** (and 3P if applicable).
6. *(PO regions only)* enable bi-directional SnapMirror after upgrade:
   ```
   run -node * -command "priv set diag;bootargs set bootarg.dsmf.xc.allow_gcnv true"
   ```

---

## Notes / gotchas
- Always use the **exact build string** (`9.18.1P4`), except the rt-api-server step which
  wants major.minor only (`9.17.1`).
- **Firmware mismatch** after step 4 → check expected `firmware-revision` per model
  (`storage disk show -fields firmware-revision,model`) and re-run the relevant download.
- **GCP KMS AUTH_FAILED must be fixed before Part 2** — upgrading with broken KMS auth can
  leave encrypted volumes offline.
- If a node shows "unknown"/down during the upgrade, see the BMC power-cycle KB linked in the How-To.

Reference: https://netapp.atlassian.net/wiki/spaces/COPS/pages/105975461/How+To+-+GCP+-+Upgrade+ONTAP+cluster
