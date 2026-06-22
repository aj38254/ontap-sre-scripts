# ONTAP / Non-Prod Login — Quick Reference

Login flow for the GCP non-prod jumphost (example: US-E4 AP TST,
`cv-ap-tst-us-east4-k8s-lmgmt-2-a`).

> Which VM to connect to (to reach ONTAP):
>
> - Look for the VM with `**mgmt**` or `**lmgmt**` or `**us-oma**` in its name (e.g. `...-k8s-lmgmt-2-a`) —
> that's the management host used to reach the ONTAP cluster.
> - If there's **no `mgmt`/`lmgmt`** VM, use the `**jmp**` / jump host instead.
> - Find it with: `gcloud compute instances list --project <project>` and pick the
> `*mgmt*` / `*lmgmt*` (or `*jmp*`) instance.

## Steps

```bash
# 1. SSH into the jumphost VM
gcloud auth login
gcloud config set project netapp-us-e4-autopush-sde-tst
gcloud compute ssh <jumphost-vm-name> --zone <zone> --tunnel-through-iap

# 2. Become root
sudo su

# 3. Auth gcloud (do this BEFORE kubectl/psql — avoids token error)
gcloud auth login

# 4. Access SDE Postgres (this DB holds the ONTAP cluster IPs)
kubectl port-forward svc/cloud-sql-proxy -n sde 5432:5432 &
PASS=$(kubectl get secret -n sde postgres-credentials -o yaml | grep -i password | awk '{print $NF}' | base64 -d && echo)
/usr/bin/psql "host=localhost port=5432 user=postgres password=$PASS"

# 5. ONTAP cluster CLI (for upgrade pre-checks)
ssh admin@<ONTAP-IP>        # <ONTAP-IP> from step 4; admin password from Secret Manager (see below)
```

## Finding the ONTAP cluster IP (via the SDE Postgres DB)

The cluster IP is in the `host` table of the `cvs` database. After connecting in step 4
(`postgres=#`):

```sql
\c cvs                                 -- switch to the cvs database
\x on                                  -- expanded/vertical output (much easier to read)
--
select * from host where type = 'ontap' and deleted_at is null;
--
select name, ip_address, port, protocol, version
  from host
 where type = 'ontap' and deleted_at is null;
\q                                     -- quit psql
```

The `ip_address` column is your `<ONTAP-IP>` (e.g. `192.168.208.20`); `name` is the
cluster (e.g. `us-qas-gc-cl-d11c11305r102-aptst`). Use it in step 5: `ssh admin@<ONTAP-IP>`.

> Readability: `select * from host ...` dumps ~30 columns and wraps unreadably. Either
> run `\x on` first (vertical layout), or select only the columns you need as shown above.

## Getting the ONTAP `admin` password (GCP Secret Manager)

Open **GCP Console → Secret Manager**. Search for the secret with `**sto`** and `**cl**`
in its name ending in `**_admin**` (the cluster `admin` user). Open it, view the latest
version, and copy the value — that's the password for `ssh admin@<ONTAP-IP>` in step 5.

## If kubectl can't connect ("localhost:8080 ... connection refused")

That means kubectl has no cluster configured — fetch the GKE kubeconfig first (run as the
**same user** you'll run kubectl as; kubeconfig is per-user, root has its own):

```bash
gcloud auth login
gcloud config set project netapp-us-e4-autopush-sde-tst
gcloud container clusters list                                  # get name + location
gcloud container clusters get-credentials <gke-cluster-name> --region us-east4
kubectl get nodes                                               # verify it works
```

Then re-run the step-4 port-forward / psql commands.

- If it complains about an auth plugin: `gcloud components install gke-gcloud-auth-plugin`
(or `export USE_GKE_GCLOUD_AUTH_PLUGIN=True`).
- If `clusters list` shows a zonal cluster, use `--zone <zone>` instead of `--region us-east4`.

## Fixes for errors seen

- `kubectl: command not found` → use full path or `sudo kubectl ...` (PATH lost after `sudo su`).
- `Failed to retrieve access token ... invalid_grant` → run `gcloud auth login` (Step 3),
then re-run the kubectl/psql commands.

## Docs

- [Login to non-prod systems](https://netapp.atlassian.net/wiki/spaces/CLOUDVOL/pages/108142262)
- [GCP secrets / berglas](https://netapp.atlassian.net/wiki/spaces/COPS/pages/105668215)
- [Upgrade ONTAP cluster](https://netapp.atlassian.net/wiki/spaces/COPS/pages/105975461)

