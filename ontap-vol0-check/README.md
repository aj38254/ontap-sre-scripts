# ONTAP vol0 free-space check

One self-contained script. It logs into every production cluster, runs

```
set d; row 0; vol show -volume vol0 -fields used,available,size
```

on each node, and flags anything with less than **20GB** available — those are the stamps
needing core dumps and packet traces cleared.

Nothing else is needed: the 49-cluster inventory, the `login.sh` hop, the Secret Manager
lookup and the credential prompt all live inside `ontap_vol0_check.sh`.

## Run

```bash
./ontap_vol0_check.sh                       # every cluster, one go
./ontap_vol0_check.sh priority              # us-c1 us-e4 us-w3 na-ne2 us-w4 first
./ontap_vol0_check.sh us-c1 na-ne2          # named regions
./ontap_vol0_check.sh US-OMA-GC-CL01-D001C220R0204   # one or multiple stamp with space
./ontap_vol0_check.sh report                # rebuild the report, no logins
./ontap_vol0_check.sh list                  # show the inventory
./ontap_vol0_check.sh secrets us-e4         # which secret gets tried per cluster
```

Put your `login.sh` next to the script (or point at it with `LOGIN_SH=/path/to/login.sh`).
If there's no `login.sh` — i.e. you're already sitting on a jumphost — it ssh's to the
clusters directly. `sshpass` must be present wherever the ssh happens.

## Credentials

Every credential Secret Manager holds for a cluster is collected up front and **tried in
turn**, so a stamp that refuses the admin account falls through to `sre-rw` and then
`sre-ro` on its own. All of that happens inside the same jumphost hop — there's no extra
round trip and no prompt. The order is:

1. anything mapped for that cluster (built into the script, plus `secrets_map.txt` if present)
2. the secret named exactly like the cluster → `admin`
3. `<cluster>-SRE-RW` → `sre-rw`
4. `<cluster>-SRE-RO` (or `-SRE-R0`) → `sre-ro`
5. `<cluster>-admin`, then any other secret in the project naming the cluster

OKM passphrases and backup keys are skipped — they sit next to the credentials but you
can't log in with them. `MAX_SECRETS` caps how many are tried (default 4).

You're asked for a username and password only once **every** candidate has been refused,
or when nothing in the project is named after the cluster at all. The report line for each
cluster records which account actually got in, so you can see at a glance which stamps are
admin and which are `sre-rw`.

Nothing is written to disk. `$ONTAP_PASSWORD` overrides the lookup with one password for
everything; `ASK_CREDS=1` skips it and always asks.

### Clusters whose secret is named differently

Several stamps are in Secret Manager under a name that has nothing to do with the name in
the inventory — `DC11-11305-0105-STO` lives under `US-QAS-GC-STO-D011C11305R0105-SRE-RW`,
for instance. Searching for the cluster finds nothing, so there is nothing to try and the
script has to ask. Those mappings are baked into the script itself, as `SECRETS_BUILTIN`:

```
DC11-11305-0105-STO   US-QAS-GC-STO-D011C11305R0105-SRE-RW
```

A `secrets_map.txt` next to the script is optional and is read *on top of* that list, so a
one-line file adds a mapping instead of replacing the ones already worked out. Keeping the
list in the script is what lets you copy the single file to a VM and have it work.

The account is inferred from the secret name, so a third column is only needed to override
it. To find any that are still missing:

```bash
./ontap_vol0_check.sh secrets us-e4     # ??? = nothing in the project names this cluster
```

When a run does end up prompting, it prints that region's credential secrets so you can
spot the right one and add it to the map — that cluster then never asks again.

## Output

While it runs, each node prints as it comes back, so a tight stamp is visible immediately:

```
    US-OMA-GC-CL01-D001C220R0204   logged in as sre-rw
    US-OMA-GC-CL01-D001C220R0204   usoma01-01   size 348.5GB  avail 19.34GB  used 94%   ** ALERT: under 20GB **
    US-OMA-GC-CL01-D001C220R0204   usoma01-02   size 348.5GB  avail 210.1GB  used 36%   OK
```

Then three files in `report/`:


| File                  | What it is                                                                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vol0_by_cluster.txt` | one line per cluster, tightest first — the work list, stamp by stamp                                                                                  |
| `vol0_usage.csv`      | every node: `region,cluster,node,volume,size,available,used,available_gb,status,login` (opens in Excel; `available_gb` is a plain number so it sorts) |
| `vol0_low_space.txt`  | just the nodes under the threshold                                                                                                                    |


Raw per-cluster captures are kept in `vol0/<region>/<cluster>.txt` as the evidence, so
`report` can rebuild everything without logging in again.

`MIN_FREE_GB=30 ./ontap_vol0_check.sh` changes the threshold.

## Incomplete runs

A capture only counts if ONTAP actually said something about `vol0` — an SSH timeout or a
"permission denied" is reported as `FAILED` with the reason, and the script exits non-zero.
A run that half-failed can never be mistaken for "everything is fine". Re-run just the
failures by naming them:

```bash
./ontap_vol0_check.sh DE-FRA-GC-STO-FRA1HE1303R0104 nl-ams-gc-sto-d001c055r059
```



## Notes on parsing

Sizes come back in ONTAP's own units (`980MB`, `19.34GB`, `1.02TB`) and are converted before
being compared to the threshold, so they aren't sorted as text. Column positions are read
from the table header rather than assumed, because ONTAP prints `-fields` in its own
canonical order rather than the order they were requested.