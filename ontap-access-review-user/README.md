# ONTAP Quarterly Access Review — helper script

One command from your admin machine collects `security login show` from all 50 ONTAP
clusters and turns it into the lists you need for the review ticket.

## What it does for each region
```
./login.sh <region>          ->  lands on that region's jumphost
ssh admin@<cluster-ip>       ->  for every cluster in that region
security login show          ->  output pulled back to your machine
```
You don't do any of those hops by hand — the script drives them.

## Setup
Put `login.sh` next to the script (or point at it):
```bash
export LOGIN_SH=/path/to/login.sh     # only if it isn't alongside this script
chmod +x ontap_access_review.sh
```
`sshpass` must exist **on the jumphosts** (the script tells you if it's missing):
```bash
sudo apt-get install -y sshpass
```

## Run
```bash
./ontap_access_review.sh list             # 49 clusters across 14 regions
./ontap_access_review.sh collect all      # every region, end to end
./ontap_access_review.sh collect na-ne2   # just one region
./ontap_access_review.sh collect CA-TOR-GC-CL01-D002C21315R0102   # one cluster
./ontap_access_review.sh report           # build the user lists
```

Every cluster reports its own result as it goes, so you can see what landed and what didn't:
```
    DE-FRA-GC-STO-FRA1HE1303R0102          <- secret DE-FRA-GC-STO-FRA1HE1303R0102-SRE-RW (user sre-rw)
    DE-FRA-GC-STO-FRA1HE1303R0102          OK       31 users
    DE-FRA-GC-CL-B00HC304R001              FAILED   bad username/password
```
`FAILED` says why where it can tell — `bad username/password`, `unreachable`, `no output`, or the
last line the cluster actually printed.

Raw per-cluster output lands in `output/<region>/<vserver>.txt` — **that is your pre-check
evidence for the ticket.** The full jumphost session is kept in `output/<region>/_session_<n>.log`
if you need to debug a failure.

### Passwords
Resolved per cluster, in this order — never written to disk:
1. `ONTAP_PASSWORD` env var (if the clusters share one password)
2. **GCP Secret Manager** (see below)
3. Interactive prompt for that cluster

All prompting happens **before** `login.sh` takes over the terminal.

The prompt tells you where to find the secret, so you can look it up without leaving the run, and
asks for the **username as well as the password** — press Enter to accept the default (`admin`, or
whatever `SSH_USER` is set to) or type a different one for clusters that don't use it:
```
    DE-FRA-GC-CL-B00HC304R001  [eu-w3]
      project : netapp-eu-w3-sde
      secrets : https://console.cloud.google.com/security/secret-manager?project=netapp-eu-w3-sde
      search  : DE-FRA-GC-CL-B00HC304R001
      username [admin]:
      password:
```
The password is not echoed. When the password comes from Secret Manager there's no prompt at all,
so those clusters use the default user.

### Wrong credentials / retries
A bad login only fails once you're inside the jumphost session, so the script checks which
clusters came back empty and **re-runs the region for just those**, prompting again — 3 attempts
by default (`MAX_ATTEMPTS=5` to change it). The retry always prompts, skipping Secret Manager and
`ONTAP_PASSWORD`, since whatever they returned is what just failed. Clusters still empty after the
last attempt are listed so you know exactly what to chase:
```
    !! no output after 3 attempt(s): DE-FRA-GC-CL-B00HC304R001
```
Within a run, clusters that already succeeded are never re-asked. Across runs there's no such
memory — every `collect` clears the previous output for the clusters it targets and pulls them
again, so the post-check re-run is genuinely fresh evidence.

### Secret Manager
Searching a cluster name returns several secrets. The script tries them in this order, and **the
name it lands on decides the username too**:

| Secret name | Username used |
|-------------|---------------|
| `<vserver>` (exact, no suffix) | `admin` (or `SSH_USER`) |
| `<vserver>-SRE-RW` | `sre-rw` |
| `<vserver>-SRE-RO` | `sre-ro` |
| `<vserver>-admin` | `admin` (or `SSH_USER`) |

So a cluster with no exact-name secret still works if it has an `-SRE-RW` or `-SRE-RO` one. Only
when none of those exist does it stop and ask you for a username and password.

Anything else matching the cluster name — `-OKM-passphrase`, `..._svc-backup_svc-backup` — is never
treated as a login credential. Payloads are JSON (`{"password":"..."}`), so the `password` key is
extracted automatically; plain-text payloads work too.

Secrets live in the region's own project; the default is `netapp-<region>-sde`. Override with
`GCP_PROJECT` (all regions) or `project_map.txt` (`region project` per line).

**Not every cluster follows the convention.** Resolve them all once instead of searching by hand:
```bash
./ontap_access_review.sh secrets all > secrets_map.txt
```
Lines are `vserver secret-name user`; the ones it couldn't resolve are marked `???` and list the
candidate secrets it did find, so you only look up the handful that actually need it. Fix those
lines, keep the file, and `collect` uses it from then on. The `user` column is optional — leave it
off and it falls back to `SSH_USER`.

The mappings worked out so far are already inside the script, as `SECRETS_BUILTIN` — a
`secrets_map.txt` is read *on top of* that, never instead of it, so a short file adds to the list
rather than shrinking it. Anything you resolve permanently is worth pasting into the script too, so
it survives being copied to a fresh VM.

## Running it on a fresh VM

`ontap_access_review.sh` is one self-contained file. Copy its contents into a new file on the box,
`chmod +x`, run it — the inventory and the secret-name map are inside it, and it needs no other file
from this repo. It does expect your own `login.sh` (or `MODE=direct` on a jumphost), plus `sshpass`
and `gcloud` on that host, and a `users_to_remove.txt` when you get to `delete`.

`ontap_verify_account.sh` is the one exception: it reuses this script's functions, so copy both
files, side by side, if you need it.

## Removing users
After `collect` and once the COPS change is approved. The account list lives in
`users_to_remove.txt` — one ONTAP account name per line (that's the **GCP TVC SSO**, not the NetApp
SSO), `#` starts a comment.

```bash
./ontap_access_review.sh plan       # dry run — prints the exact commands, changes nothing
./ontap_access_review.sh delete     # pre-check -> delete -> post-check
./ontap_access_review.sh removed    # removed-users list + summary for the ticket
```

**Which clusters get touched is derived from what `collect` actually saw**, never guessed — a user
who isn't on a cluster generates no command for it. The command itself follows the form the other
teams' `delete_ontap_users.sh` uses:

```
set d; row 0; security login delete -user-or-group-name <user> -vserver <vserver> \
    -authentication-method * -application *
```

`set d` is diagnostic privilege (plain admin can't delete every login), `row 0` disables pagination,
and the wildcards clear every application/auth-method for that user in one call. `plan` writes
`report/delete_plan.txt`, which is what you paste into the CR as the exact steps.

`delete` asks you to type `DELETE` before it touches anything (`ASSUME_YES=1` skips that). For each
cluster it writes three logs to `logs/`:

| File | Contents |
|------|----------|
| `PRE_CHECK_<vserver>.txt` | `security login show` before — the audit baseline |
| `DELETE_<vserver>.txt` | output of each delete |
| `POST_CHECK_<vserver>.txt` | `security login show` after |
| `FAILED_<vserver>.txt` | whatever came back when the login didn't return a table |

`removed` diffs each PRE/POST pair and writes `report/ONTAP_users_removed.txt` (one line per removed
entry, tagged with the cluster) plus `report/removal_summary.txt` in the shape the ticket wants —
file pairs compared, total removed entries, unique users, each user's system count, and the clusters
that produced no usable capture so the gaps are visible rather than silently missing.

Re-run `collect` + `report` afterwards so `users_by_cluster.csv` reflects the post-removal state.

### Checking an account that a report claims was removed
`ontap_verify_account.sh` proves against the live clusters whether an account is
actually gone, and is read-only unless you act on what it writes:

```bash
./ontap_verify_account.sh check            # defaults to vsadmin
./ontap_verify_account.sh plan srisaran    # + restore commands for anything really missing
```

It reconstructs the before-state from the `PRE_CHECK_*.txt` captures, which keep the vserver each
row belonged to, and re-runs an **unscoped** `security login show`. That matters: a scoped show
doesn't return data-SVM rows, and `ONTAP_users_removed.txt` can't be used for this at all because
its diff dropped the vserver column and attributes every row to the cluster it was captured from.
`plan` never executes anything — `security login create` prompts for a password, so restoring a
service account non-interactively would silently rotate its credential.

### Retrying a partial run
Name regions or individual clusters to limit the run, which is how you finish a run where some
clusters failed without re-touching the ones that already worked:

```bash
./ontap_access_review.sh delete eu-w3 eu-w6                      # whole regions
./ontap_access_review.sh delete CH-ZRH-CL01-D001C03R0113         # one cluster
./ontap_access_review.sh plan users.txt na-ne2 los1-360-m02-01-01-sto
```

Cluster names are matched case-insensitively, and a name that is neither a region, a cluster in the
inventory nor a readable file is rejected rather than silently ignored. Everything a targeted run
removes is added to `ONTAP_users_removed.txt` and the summary, because `removed` re-derives them
from every pre/post pair in `logs/`, not just the last run's.

If a cluster returns nothing, `delete` retries it up to `MAX_ATTEMPTS` (3) and asks for a username
and password instead of re-reading the secret that just failed — the secret named after the cluster
is often the wrong account, and only `sre-rw` can log in. It stops as soon as the cluster answers,
and never re-prompts for clusters that already worked. To skip Secret Manager from the start:

```bash
ASK_CREDS=1 ./ontap_access_review.sh delete ca-lon-gc-sto-dmtl10cg115br105
```

Two rules make a retry safe. A cluster is only reported from captures **this run** produced, so one
that couldn't be reached says `NO CAPTURE THIS RUN` instead of borrowing the previous run's files and
reading as `NOTHING REMOVED`. And the first valid pre-check for a cluster is kept as the baseline
forever, so re-running a region that was only partly successful doesn't re-baseline the clusters that
already worked and drop their removals out of the `removed` report.

Read the per-cluster status like this:

| Line | Meaning |
|------|---------|
| `removed 3/3` | verified against the post-check |
| `removed 1/3 — PARTIAL` | some deletes didn't land; read `DELETE_<vserver>.txt` |
| `NOTHING REMOVED` | the cluster answered, but nothing changed — the accounts may already be gone |
| `NO CAPTURE THIS RUN` | never reached it; read `FAILED_<vserver>.txt` or the session log |
| `!! no cluster returned output` | the whole `login.sh <region>` hop failed |

## Reports
`./ontap_access_review.sh report` writes to `report/`:

| File | What it is |
|------|-----------|
| `unique_users.txt` | deduplicated user list — **this is what you email for confirmation** |
| `privileged_users.txt` | `admin` / `super-users` / `admin-no-fsa` / `sre-admins` accounts (the privileged-access half of the review) |
| `users_by_cluster.csv` | full detail for the ticket — `Vserver,User/Group Name,Application,Authentication Method,Role Name,Acct Locked,Second Authentication Method` (opens straight into Excel for the `ONTAP_current_users.xls` attachment) |
| `user_cluster_counts.txt` | each user and how many clusters they exist on |

Only the **cluster vserver** is parsed; the per-volume `svm_*` vservers (which only ever contain
`vsadmin`) are skipped. Use `INCLUDE_SVM=1` to include them. SSH banners and other noise in the
captured output are ignored by the parser.

## Modes
Auto-detected: if `login.sh` is found it drives the jumphost hop; if not (i.e. you're already
sitting on a jumphost) it ssh's to the clusters directly. Force with `MODE=login` or `MODE=direct`.

## Where this fits in the ticket
1. `collect all` → raw logs = current-access evidence.
2. `report` → `unique_users.txt`.
3. Email `unique_users.txt` to the SRE Manager / ManagedAD owner to confirm who has left.
4. Confirmed list → COPS change ticket → run the team's `delete_ontap_usr.sh`.
5. Re-run `collect all` + `report` as the post-check.

See `../ONTAP-Access-Review-Runbook.md` for the full process.
