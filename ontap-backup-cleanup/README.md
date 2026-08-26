# ONTAP config-backup cleanup

ONTAP writes a `system configuration backup` every six hours and never ages them out, so nodes
fill up. Until the ONTAP team gives us a real retention setting, this script finds the ones older
than two weeks and removes them.

One self-contained script. The 49-cluster inventory, the `login.sh` hop, the Secret Manager lookup
and the credential prompt all live inside `ontap_backup_cleanup.sh` — copy that one file to a VM
and it works.

**Nothing is deleted unless you pass** `--execute`**.** A bare `delete` prints the commands and stops.

## Start here (EU-W6)

```bash
./ontap_backup_cleanup.sh            # collect + plan: eu-w6 only (1 cluster)
./ontap_backup_cleanup.sh delete     # dry run — prints the exact commands, deletes nothing
```

"Collect + plan" means: log into each cluster, read every node's backup list, and write
`report/delete_plan.txt`. It deletes nothing.

The second command is the review artefact. `report/delete_plan.txt` holds the same thing as a file,
one `system configuration backup delete` line per backup, ready to read line by line.

Once that's approved, the first real deletes:

```bash
./ontap_backup_cleanup.sh delete --execute --limit 2 # --limit 0 for all, be carefull before using it
```

That does two backups, re-reads the cluster, and tells you which ones actually went. Scale up by
raising `--limit`; `--limit 0` means no cap.

Other regions once EU-W6 is proven. Same command as above, only the scope changes:

```bash
./ontap_backup_cleanup.sh eu-w4          # collect + plan: the 6 clusters in EU-W4
./ontap_backup_cleanup.sh all            # collect + plan: all 49 clusters, 14 regions
```

A bare run only touches `eu-w6` on purpose — rolling out one region at a time is the plan, so a
run with no arguments follows it rather than hitting all 49 clusters.

## Deleting across the whole fleet

**The plan is rebuilt from every capture saved so far, not just the region you last collected.**
Collect `eu-w6` today and `eu-w4` tomorrow and `report/delete_plan.txt` covers both, so a plain
`delete --execute` would work through both. Name a region or a cluster to pin it down:

```bash
./ontap_backup_cleanup.sh delete --execute --limit 2 eu-w6
```

Once every region is collected, `--limit 0` would in principle do the lot:

```bash
./ontap_backup_cleanup.sh all
./ontap_backup_cleanup.sh delete                        # dry run, read the plan
./ontap_backup_cleanup.sh delete --execute --limit 0    # don't — see below
```

**Don't run that last line in one shot.** A node holding 322 backups is about 80 days' worth at one
every six hours, so roughly 260 of them are past the window. Times six nodes times 49 clusters is
somewhere near 75,000 deletes; at `DELETE_BATCH=20` that's a few thousand ssh logins and several
hours, and if it dies halfway there's nothing telling you where it stopped.

Go region by region, so each one is a checkpoint:

```bash
./ontap_backup_cleanup.sh delete --execute --limit 0 eu-w6
./ontap_backup_cleanup.sh delete --execute --limit 0 eu-w4
./ontap_backup_cleanup.sh delete --execute --limit 0 eu-w3
```

Each finishes, re-reads its clusters and writes `report/deleted.txt` before you start the next, so
a region in trouble is the only thing you have to sort out. Add `--yes` to skip the typed `DELETE`
confirmation once you are happy to leave one running unattended.

The big run is a one-off. Once the backlog is cleared only about four backups per node fall out of
the window each day, so the routine run after that is small and quick.

## What it runs on the cluster

One command, one login, every node:

```
set d; row 0; system configuration backup show
```

`set d` raises privilege — `system configuration backup` isn't recognised at the default level — and
`row 0` stops the output being cut off at one screen.

Typing `set d` at a terminal prompts *"These diagnostic commands are for use by NetApp personnel
only. Do you want to continue? {y|n}"*, which makes the longer `set -confirmations off; set
-privilege diagnostic; set -rows 0` look like the safer thing to send. It isn't. ONTAP doesn't prompt
for a command passed on the ssh line, and the short form is what `ontap_vol0_check.sh` already sends
through these same jumphosts every run.

With no `-node`, the show covers all six nodes in one pass and the node name is the table's first
column, so there's nothing to gain from listing the nodes first and then asking once per node. Node
names do **not** match the cluster name — cluster `CH-ZRH-CL01-D001C03R0113` has nodes
`CH-ZRH-NC01-...` through `CH-ZRH-NC06-...` — so the node in each delete command is taken from the
row it came from, never from the cluster. Check the node count in the summary: eu-w6 should say 6.

If a capture does come back paginated anyway, the script says so loudly and tells you the plan is
incomplete, rather than planning from a partial list.

## Which backups get deleted

Three rules, applied in that order. A backup has to survive all of them to be deleted.

**1. The name must match** `backup_YYYYMMDD_HHMMSS.7z`**.** Anything else in the table is ignored
entirely — it is never counted, never planned and never deleted. The timestamp is read from the
name, not from the `Time` column, because that column has no year in it.

This matters more than it first looks, because a node holds **three different families** of backup:

```
CH-ZRH-CL01-D001C03R0113.8hour.2026-08-25.18_15_00.7z    <- scheduled, named after the CLUSTER
CH-ZRH-CL01-D001C03R0113.daily.2026-08-26.00_10_00.7z    <- scheduled
CH-ZRH-CL01-D001C03R0113.weekly.2026-08-09.00_15_00.7z   <- scheduled
ontap-configuration-2024-01-26-08-52-59.7z               <- ad-hoc, from a 2024 upgrade
CH-ZRH-NC01-D001C03R0113_backup_20260801_000003.7z       <- named after the NODE, this is ours
```

The `.8hour`/`.daily`/`.weekly` ones are ONTAP's own scheduled backups, which it already rotates by
itself. The `ontap-configuration-*` ones are ad-hoc captures someone took by hand — on eu-w6 they're
from January 2024 and would all be "older than 14 days", which is exactly why the pattern rule runs
*before* the age rule and not after. Only the `_backup_` family is ever touched.

**2. Strictly older than 14 days.** A backup dated exactly two weeks ago is *kept*. "Older than 2
weeks" should never be read as "including the boundary" by something that deletes, so the boundary
falls on the safe side. Change with `RETAIN_DAYS=n`.

**3. Not in the newest 5 on its node.** This is a floor, applied after the age rule and regardless
of age. If a node's backup job has been dead for a month then every backup it has is "old", and
without this the cleanup would take the last good config backup with it. Change with `MIN_KEEP=n`.

Each backup lands in `report/backups_all.csv` with the rule that decided it:


| action          | meaning                                                                     |
| --------------- | --------------------------------------------------------------------------- |
| `DELETE`        | older than the retention window and past the floor                          |
| `KEEP_RECENT`   | inside the retention window                                                 |
| `KEEP_FLOOR`    | old, but one of the newest `MIN_KEEP` on its node                           |
| `SKIP_MISMATCH` | the table's node column disagrees with the node embedded in the backup name |


`SKIP_MISMATCH` is a parser guard. `delete` needs `-node` and `-backup` to refer to the same thing,
and if those two disagree the line has been misread — so the row is reported and left alone rather
than guessed at. If any show up, look at the raw capture before going further.

### Wrapped output

ONTAP wraps a long row over three printed lines, indenting the continuations:

```
CH-ZRH-NC01-D001C03R0113
           CH-ZRH-NC01-D001C03R0113_backup_20260801_000003.7z
                                       08/01 00:00:04     444.5MB
```

A new row always starts in column 1, so anything indented is joined onto the row above before
parsing. That rebuilds the logical row and the same rules then work on both the wrapped and the
one-line form.

## Proving what happened

ONTAP's replies to a chained delete can't be attributed to individual backups, so the script
doesn't try. After `--execute` it re-reads every node it touched and diffs:

```
report/deleted.txt      DELETED / STILL THERE, one line per backup it tried
```

That diff is the answer, not anything ONTAP printed during the run.

## Credentials

**`admin` and `sre-rw` only.** `sre-ro` is read-only and cannot run `system configuration backup
delete`, so it is never tried — not even for the collect. A cluster that only answers to `sre-ro`
therefore fails at collect time, where you can see it and type a working account, instead of
collecting happily and then deleting nothing.

Both candidates are collected up front and tried in turn inside a single jumphost hop, so a stamp
that refuses `admin` falls through to `sre-rw` without stopping to ask. Order:

1. anything mapped for that cluster (built into the script, plus `secrets_map.txt` if present)
2. the secret named exactly like the cluster → `admin`
3. `<cluster>-SRE-RW` → `sre-rw`
4. `<cluster>-admin`, then any other secret in the project naming the cluster

Anything resolving to `sre-ro` is dropped from that list, including an explicit `secrets_map.txt`
line that names one.

Two other kinds of secret are skipped, because at most four are tried per cluster and a wrong guess
burns one of those slots: OKM passphrases and certificates, which are not login credentials at all;
and anything with **`backup`** in the name. In eu-w6 that last one covers
`<cluster>-SVC-ONTAPBACKUP` and `<cluster>_svc-backup` — despite the name these are backup *service
accounts*, not the admin password, and offering them as `admin` fails every time.

You're only prompted once all of them have been refused, and whatever you type at the prompt is
used as typed — it doesn't second-guess an account you've deliberately chosen. Nothing is written
to disk. `ONTAP_PASSWORD` overrides the lookup with one password for everything; `ASK_CREDS=1`
always asks.

One extra guard on the delete path: the account is proven with a harmless `version` read before the
first delete is issued, and whichever one wins is used for every batch on that cluster. Without the probe
a cluster that refuses the first credential would log in as nobody and quietly delete nothing;
switching accounts half way would leave a partly-deleted cluster with no record of which delete ran
as whom.

To see what will be tried, and which clusters have a secret named nothing like the cluster:

```bash
./ontap_backup_cleanup.sh secrets eu-w6      # ??? = nothing usable names it
```

Those mappings are baked into the script as `SECRETS_BUILTIN`. A `secrets_map.txt` next to the
script is optional and is read *on top of* that list, so a one-line file adds a mapping instead of
replacing the ones already worked out.

## Files

```
backups/<region>/<cluster>.txt   raw capture, pre-delete
logs/post/...                    raw capture re-taken after a delete run
logs/_delete_<region>.log        the delete session itself
report/backups_all.csv           region,cluster,node,backup,timestamp,size,age_days,rank,action
report/delete_plan.txt           the exact commands — hand this round for review
report/backups_summary.txt       per-node counts and reclaimable space
report/deleted.txt               what actually went, proven by the post-check
```

`plan` rebuilds all of the reports from saved captures without logging into anything.

## Running it on a fresh VM

Copy the contents of `ontap_backup_cleanup.sh` into a new file, `chmod +x`, run it. Nothing else
from this repo is needed.

What it does expect on the host: your own `login.sh` next to the script (or `LOGIN_SH=/path/to/it`),
plus `sshpass` and `gcloud`. If there's no `login.sh` — you're already on a jumphost — it ssh's to
the clusters directly.

## Full options

```bash
./ontap_backup_cleanup.sh --help
```

