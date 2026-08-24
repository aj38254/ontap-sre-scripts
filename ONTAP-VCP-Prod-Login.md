# VCP ONTAP production login (us-c1)

How to find a customer’s production GCNV / VCP ONTAP VM and SSH in as `admin` from
the **us-c1** jumphost (`us-c1-gke-jmp-01`).

This is the **production VCP** path (`vcp` database, tenant project, Secret Manager in
`netapp-us-c1-sde`). For non-prod jumphost / `cvs` DB login, use
`ONTAP-Login-Access-Reference.md`.

Example used below (swap for the customer you are working):

| What | Example |
|------|---------|
| GCP customer project number | `56990896620` |
| VCP `accounts.id` | `4248` |
| Regional tenant project | `352459829240` |
| Cluster / VM search name | `gcnv-ee9e6c4e189489d-01` |
| ONTAP SSH | `ssh admin@34.61.14.255` from the jumphost |

---

## 1. Land on the us-c1 jumphost

You should already be on `us-c1-gke-jmp-01` (prompt like
`ashishjaiswal_google_com@us-c1-gke-jmp-01:~$`).

## 2. Fetch GKE credentials

```bash
gcloud container clusters get-credentials us-c1-gke \
  --region us-central1 \
  --project netapp-us-c1-sde
```

## 3. Port-forward Cloud SQL, then connect to Postgres

```bash
kubectl port-forward svc/cloud-sql-proxy -n sde 5432:5432 &

PASS=$(kubectl get secret -n sde postgres-credentials -o yaml \
  | grep -i password | awk '{print $NF}' | base64 -d && echo)

/usr/bin/psql "host=localhost port=5432 user=postgres password=$PASS"
```

**If port-forward says `bind: address already in use` on 5432:** something is already
listening (often a previous port-forward). You can still run `psql` against
`localhost:5432`. The background job will exit with status 1; that is expected.

In `psql`:

```sql
\c vcp
\x
\pset pager off
```

You should be on `vcp=>` with expanded display and no pager.

---

## 4. Get the GCP project number (from QIR / Buganizer)

Open open Flex Unified customer issues:

https://partnerissuetracker.corp.google.com/issues?q=status:open%20componentid:1303631%20type:customer_issue%20flex%20unified

Find the QIR / Buganizer ticket for the customer. Copy **Project Number(s)**.

Example ticket: https://buganizer.corp.google.com/issues/544987237  
Project Number(s): `56990896620`

---

## 5. Resolve the account and pool in VCP

```sql
select * from accounts where name = '56990896620';
```

Note `id` (example: `4248`) and confirm `state` is `ENABLED`.

```sql
select * from pools where account_id = 4248;
```

In `cluster_details` (JSON) take:

- **`regional_tenant_project`** — GCP project that holds the ONTAP VM  
  Example: `"regional_tenant_project": "352459829240"`
- **`external_name`** / names starting with **`gcnv-`** — used to find the VM and the
  Secret Manager secret  
  Example: `"external_name": "gcnv-ee9e6c4e189489d-r34"`  
  VM / secret search string: `gcnv-ee9e6c4e189489d-01`

Other useful fields in the same JSON: `ontap_version`, `intercluster_lifs`,
`sn_host_project`, subnet names.

---

## 6. Raise AccessHub grants

Request (if you do not already have them):

- `Gcnv-prod-producer-project-owner-ext`
- `Gcnv-prod-tenant-project-owner-ext`

Wait until the grants are active before opening the tenant project / VM.

---

## 7. Find the VM IP and the admin password

1. In GCP Console, open project **`regional_tenant_project`** (example `352459829240`).
2. Find the Compute Engine VM whose name matches the `gcnv-...` string (example
   `gcnv-ee9e6c4e189489d-01`). Note its **external IP** (example `34.61.14.255`).
3. In Secret Manager of **`netapp-us-c1-sde`** (us-c1 region), search for that same
   `gcnv-` name and copy the **admin** password.

For other regions, use that region’s SDE project / jumphost instead of
`netapp-us-c1-sde` / `us-c1-gke-jmp-01`.

---

## 8. SSH to ONTAP as admin (from the jumphost)

Stay on the **us-c1 jumphost**. Do not SSH from your laptop.

```bash
ssh admin@34.61.14.255
```

First connect: accept the host key (`yes`). Then enter the password from Secret Manager.

```
(admin@34.61.14.255) Password:
```

You should land on the ONTAP CLI (Last login time shown).

---

## Quick command recap

```bash
# On us-c1-gke-jmp-01
gcloud container clusters get-credentials us-c1-gke --region us-central1 --project netapp-us-c1-sde
kubectl port-forward svc/cloud-sql-proxy -n sde 5432:5432 &
PASS=$(kubectl get secret -n sde postgres-credentials -o yaml | grep -i password | awk '{print $NF}' | base64 -d && echo)
/usr/bin/psql "host=localhost port=5432 user=postgres password=$PASS"
```

```sql
\c vcp
\x
\pset pager off
select * from accounts where name = '<gcp-project-number>';
select * from pools where account_id = <accounts.id>;
-- then cluster_details → regional_tenant_project + gcnv-* name
```

```bash
ssh admin@<vm-external-ip>
```
