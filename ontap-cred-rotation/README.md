# ONTAP credential rotation — pre-work survey

Quarterly compliance asks for the local ONTAP account passwords (`admin`, `sde`, `svc-sde`,
`sre-rw`, `sre-ro`, break-glass) to be rotated, with a COPS change ticket per cluster linked
back to the Jira story.

This script does none of the rotating. It answers the question that has to be settled
**before** any change ticket is raised:

> Which account is the control plane using to log into this cluster?

That's the `username` column of the `host` table in each region's `cvs` Postgres database,
and it decides everything:

| `username` in the host table | What it means |
|---|---|
| `sde` / `svc-sde` | the control plane isn't using `admin`, so rotating `admin` is self-contained — **go ahead** |
| `admin` | rotating `admin` cuts the control plane off from the cluster and provisioning breaks — **abort**, unless the new credentials are also pushed in with `PUT /v1/host` through the CVI API |

The change tickets spell this out as a hard gate: *"MAKE SURE WHEN YOU RUN THIS ON THE CVS DB
AND MATCH THE IP, USERNAME IS SDE. IF IT IS ADMIN, ABORT THE CHANGE."*

Everything here is read-only. It never logs into a cluster and changes no password, so it's
safe to run before the change ticket exists.

## Run

```bash
./ontap_cred_survey.sh hosts          # read the cvs host table in every region
./ontap_cred_survey.sh hosts us-c1    # one region
./ontap_cred_survey.sh survey         # build the table
./ontap_cred_survey.sh list           # show the inventory
```

Put your `login.sh` next to the script (or set `LOGIN_SH=/path/to/login.sh`). If you're
already sitting on a jumphost, use `MODE=direct` and name that one region.

`hosts` needs no ONTAP credentials — the query runs on the jumphost, not on the clusters. It
brings up the `cloud-sql-proxy` port-forward itself if one isn't already listening, reads the
postgres password from the `sde/postgres-credentials` secret, and runs exactly the query the
change ticket asks for:

```sql
select ip_address, username, external_name
  from host where type='ontap' and deleted_at is null;
```

If a region comes back empty it says so, prints kubectl's own error, and points at the session
log. The usual cause is that jumphost having no kubeconfig for the current user, so the
postgres password can't be read:

```bash
gcloud auth login
gcloud container clusters list
gcloud container clusters get-credentials <name> --region <region>
```

Then rerun `hosts` for just those regions. Clusters in a region that was never read are marked
`NO-DATA`, never `NO-ROW` — a region you couldn't reach is a gap in the survey, not a finding
about the cluster, and the summary says plainly that the run is incomplete.

## Output

`report/rotation_survey.csv` is the table, one row per cluster:

```
region,cluster,ip,cvs_username,cvs_name,secrets,local_accounts,verdict
us-c1,US-OMA-GC-CL01-D001C220R0204,192.168.31.4,sde,US-OMA-...,US-OMA-...-SRE-RW,admin;sde;sre-rw,SAFE
us-c1,NDC-220-R1-R2-STO,192.168.1.4,admin,NDC-220-R1-R2-STO,NDC-220-...,admin;sre-ro,ABORT
```

`rotation_safe.txt` and `rotation_abort.txt` split that into the two work streams, which is
how the waves get planned. Clusters the database knows about but the inventory doesn't are
listed separately — the database is the source of truth for what exists, so anything extra is
a cluster nobody is currently planning to rotate.

The `secrets` column is every Secret Manager secret holding a password for that cluster.
Those are the ones needing a new version added (and the old version disabled, not deleted —
the backout plan is to set the password back) once the rotation is done. `NO_SECRETS=1` skips
the column and the `gcloud` calls.

The `local_accounts` column is filled from the access review's captures if they're present at
`../ontap-access-review-user/output`, which is where the list of what actually needs rotating
per cluster comes from. Without them the column is just blank.

## Then what

The survey is step zero. The per-cluster procedure after it is, from the change tickets:

1. create a volume from a pool in the region — the pre-check that provisioning works
2. re-run the host-table query for that one IP and confirm the username, as evidence
3. generate a new password (change tickets say 24 characters; the runbook says 12 with mixed
   case and digits for `sde` — confirm which applies to the account you're rotating)
4. `security login password -username <account>` on the cluster, then log out and back in to
   prove the new password works
5. add a new version of the Secret Manager secret and disable the old one
6. for an `sde`/`svc-sde` account, also `PUT /v1/host/<uuid>` through the CVI API, refresh
   resources, poll the job to `COMPLETED`, and confirm the `cvs` and `scheduler` databases
   picked it up
7. create another volume from the same pool — the post-check

Plus the process wrapper: notify Google through the maintenance form before the change, paste
the pre-check, query output, session and post-check into the COPS ticket, and link it to the
story.

There is already a [runbook](https://confluence.ngage.netapp.com/spaces/~jsamuel/pages/1421372186/Runbook+for+rotation+of+ONTAP+username+and+password)
and, from the March 2026 round, a `paramiko`-based automation script and a
[tracking sheet](https://docs.google.com/spreadsheets/d/1i2P-7GNK2spcpTQuA-IgE8g3cy5zY_ec1BIVd-AN5oA/edit?gid=62907598#gid=62907598).
Get hold of those before writing anything new for steps 3–6.
