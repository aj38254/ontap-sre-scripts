# ONTAP credential rotation

Quarterly compliance asks for the local ONTAP account passwords (`admin`, `sde`, `svc-sde`,
`sre-rw`, `sre-ro`, break-glass) to be rotated, with a COPS change ticket per cluster linked
back to the Jira story.

One script, and a manual procedure:


|                        |                                                                     |
| ---------------------- | ------------------------------------------------------------------- |
| `ontap_cred_survey.sh` | read-only pre-work. Who does the control plane log in as?           |
| [The rotation](#2-the-rotation--done-by-hand) | done by hand, one cluster at a time, from its change ticket |


**The rotation is deliberately not automated.** These are production clusters, and a scripted
password change that goes wrong locks you out of one. Run the survey first — never rotate a
cluster the survey hasn't covered — then work the change tickets by hand.

**Current scope is** `admin` **only.** `sre-rw` and `sre-ro` are not rotated — see
[Scope](#scope-admin-only) for why that matters to the safety of the whole thing.

## The rule everything hangs off

> Which account is the control plane using to log into this cluster?

That's the `username` column of the `host` table in each region's `cvs` Postgres database,
and it decides everything:


| `username` in the host table | What it means                                                                                                                                                                           |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sde` / `svc-sde`            | the control plane isn't using `admin`, so rotating `admin` is self-contained — **go ahead**                                                                                             |
| `admin`                      | rotating `admin` cuts the control plane off from the cluster and provisioning breaks — **abort**, unless the new credentials are also pushed in with `PUT /v1/host` through the CVI API |


The change tickets spell this out as a hard gate: *"MAKE SURE WHEN YOU RUN THIS ON THE CVS DB
AND MATCH THE IP, USERNAME IS SDE. IF IT IS ADMIN, ABORT THE CHANGE."*

As of the August 2026 survey, across 50 clusters: 45 use `sde`, 4 use `svc-sde`, and one —
`us-oma-gc-sto-ndc220r1r4` in us-c1 — still uses `admin`.

---



# 1. `ontap_cred_survey.sh` — the survey

Read-only. It never logs into a cluster and changes no password, so it's safe to run before
the change ticket exists.

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
us-c1,us-oma-gc-sto-ndc220r1r4,192.168.2.4,admin,us-oma-...,...,admin;sre-ro,ABORT
```

`rotation_safe.txt` and `rotation_abort.txt` split that into the two work streams. Clusters the
database knows about but the inventory doesn't are listed separately — the database is the
source of truth for what exists, so anything extra is a cluster nobody is planning to rotate.

The `local_accounts` column fills in from `security login show` captures dropped at
`accounts/<region>/<cluster>.txt`. It is a nice-to-have — leave the directory empty and the column
comes back blank, nothing else changes. `NO_SECRETS=1` skips the `secrets` column and the `gcloud`
calls.

## Running it on a fresh VM

`ontap_cred_survey.sh` is one self-contained file. Copy its contents into a new file on the box,
`chmod +x`, run it — the cluster inventory and the odd-named-secret map are both inside the script.
Nothing else from this repo is needed.

What it does expect on the host: your own `login.sh` (or `MODE=direct` if you are already on a
jumphost), plus `gcloud`, `kubectl` and `psql`.

`secrets_map.txt` next to the script is optional. Lines in it are read *on top of* the list built
into the script, so a one-line file adds a mapping rather than replacing the ones already worked
out.

---



# 2. The rotation — done by hand

**There is no rotation script.** These are production clusters and the risk of an automated
password change going wrong is not worth the time it saves. Do them one at a time, from the
change ticket, following the order below.

What follows was the design of the script that used to live here. The reasoning still applies;
you are now the one enforcing it.

## The order, and why it is that order

```
1. add the new password to Secret Manager      <- old version still enabled
2. change it on the cluster
3. log in with the new password to prove it
4. only then disable the old version
```

Secret Manager goes first because the alternative — change the cluster, then store it — has a
window where the live password exists only on your screen. Lose the terminal there and you are
locked out of a production cluster, and recovery means console or service-processor access.

Do not disable the old version until step 3 has actually succeeded.

## If the new password does not work

Ask the cluster a follow-up question: does the **old** password still work? The answer decides
what to do with the secret.

| new password | old password | What happened           | What to do                                                                     |
| ------------ | ------------ | ----------------------- | ------------------------------------------------------------------------------ |
| works        | —            | rotated                 | disable the old version                                                        |
| refused      | works        | the change never landed | disable the **new** version so `latest` is the truth again. Safe to retry      |
| refused      | refused      | indeterminate           | **disable nothing.** Leave both versions enabled and readable. Get help        |

That third row is the one that matters. Disabling either version there could destroy the only
copy of a working password. A cluster that did not answer at all counts as indeterminate too —
no answer tells you nothing about the password.

## Before touching a cluster

Log in as every account you have a credential for and see which ones actually answer:

```
admin     OK
sre-rw    OK
sre-ro    REFUSED Permission denied.
```

Three things follow from that:

- **If nothing answers, stop.** Don't start a rotation you can't finish.
- **Issue the change as an account you are not rotating**, where one exists. Its password
  doesn't move under your session, ONTAP won't stop to ask for a current password, and it's
  still a working login afterwards. It also means a cluster whose `admin` secret has gone stale
  can still be rotated, as long as `sre-rw` gets in.
- **If the only thing that answers is** `admin` **itself**, open a second SSH session and keep it
  open for the whole change. Every account that works there is the one being rotated, so
  otherwise your only recovery is the service processor.

Test the fallback before the wave, not during it. A fallback nobody has logged into is not a
fallback.

## Do not rotate

- the account the cvs host table names for that cluster — that is the abort condition
- anything in a region the survey never covered; unknown is unsafe
- an account with no `ssh` + `password` login, because you cannot verify it afterwards
- an account no Secret Manager secret holds, because there is nowhere to put the result

## Scope: `admin` only

This quarter only `admin` rotates. `sre-rw` and `sre-ro` are deliberately left alone, and that is
not just scope — it is the safety net. An account you did not touch, whose password still works,
is the way back in when an `admin` rotation goes wrong.

If the scope widens later, do `admin` last. Until it is done it is the fallback for everything
else.

## The commands

Get the current password from Secret Manager for the region, then:

```
<cluster>::> security login password -username admin
Enter your current password:
Enter a new password:
Enter it again:
<cluster>::> exit
```

Then log back in with the new password before doing anything else:

```
ssh admin@<ip>
Password:
<cluster>::>
```

Only now add the new version in Secret Manager and disable the old one. Disable, never delete —
the backout is to set the password back to it.

## Passwords

24 characters. Avoid quotes, backslashes, backticks, `$` and spaces — the password has to survive
being typed and pasted across shells and SSH sessions without being mangled.

If the existing secret payload is JSON like `{"username":..., "password":...}`, keep that shape
and replace only the password. A bare-text secret stays bare text.

## Evidence to keep on the ticket

- `security login show` output from before the change
- the host-table query for that IP, showing `sde` or `svc-sde`
- the pre-check and post-check volume creations
- confirmation of the new Secret Manager version, and the old one disabled

## What is out of scope

`sde` and `svc-sde` are not rotated here. Those need the CVI API leg — `PUT /v1/host/<uuid>`,
`POST /v1/resource/refresh`, poll the job to `COMPLETED`, then confirm the `cvs` and `scheduler`
databases picked it up.

`us-oma-gc-sto-ndc220r1r4` needs its host entry migrated from `admin` to an `sde` account before
its `admin` password can be rotated at all. Its `sre-rw` and `sre-ro` are fine today.

## Around every cluster, regardless

1. create a volume from a pool in the region — the pre-check that provisioning works
2. notify Google through the maintenance form before the change (Chromebook only)
3. re-run the host-table query for that one IP as evidence
4. the rotation
5. create another volume from the same pool — the post-check
6. link the COPS change ticket to the Jira story

## Change tickets

The COPS change tickets are raised by [`jira-bulk`](../jira-bulk/README.md), which used to live here
as `cops/make_cops_tickets.py` and was pulled out so the Jira half is reusable for other batches.
This round is the job at `jira-bulk/jobs/ontap-admin-rotation-2026q3/`.

```bash
cd ../jira-bulk
export JIRA_TOKEN=...
export JIRA_JOB=jobs/ontap-admin-rotation-2026q3
./jira_bulk.py probe
./jira_bulk.py create --limit 1
./jira_bulk.py create
```

One COPS **Change** per cluster, modelled on
[COPS-64000](https://jira.ngage.netapp.com/browse/COPS-64000) from the Sept 2025 round, each linked
to the parent story. They are created in `COPS`, not `NFSAAS` — only the parent story lives in
`NFSAAS`. The description is COPS-64000's reproduced verbatim, in `description.tmpl`; the only
per-cluster substitution is the Step 1 host-table row. Rows come from `rows.tsv` and anything whose
`cvs_username` is `admin` gets no ticket, for the same reason you must not rotate it by hand.

See the [jira-bulk README](../jira-bulk/README.md) for assigning, review transitions, and how to
cancel or archive the ones that drop out of scope.

There is already a [runbook](https://confluence.ngage.netapp.com/spaces/~jsamuel/pages/1421372186/Runbook+for+rotation+of+ONTAP+username+and+password)
and, from the March 2026 round, a `paramiko`-based automation script and a
[tracking sheet](https://docs.google.com/spreadsheets/d/1i2P-7GNK2spcpTQuA-IgE8g3cy5zY_ec1BIVd-AN5oA/edit?gid=62907598#gid=62907598).
Worth comparing against before the first wave.