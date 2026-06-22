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
./ontap_vol0_check.sh US-OMA-GC-CL01-D001C220R0204   # one stamp
./ontap_vol0_check.sh report                # rebuild the report, no logins
./ontap_vol0_check.sh list                  # show the inventory
```

Put your `login.sh` next to the script (or point at it with `LOGIN_SH=/path/to/login.sh`).
If there's no `login.sh` — i.e. you're already sitting on a jumphost — it ssh's to the
clusters directly. `sshpass` must be present wherever the ssh happens.

## Credentials

Per cluster, in order: `$ONTAP_PASSWORD` → GCP Secret Manager → prompt. Nothing is written
to disk. The Secret Manager lookup prefers the secret named exactly like the cluster, then
`<cluster>-SRE-RW` (user `sre-rw`), then `<cluster>-SRE-RO` (user `sre-ro`), then
`<cluster>-admin`.

If a cluster doesn't answer, it re-prompts for **username and password** and retries, up to
3 times (`MAX_ATTEMPTS`). The prompt shows the GCP project and a Secret Manager link so you
can go find the value without leaving the run. `ASK_CREDS=1` skips the lookup entirely and
always asks.

## Output

While it runs, each node prints as it comes back, so a tight stamp is visible immediately:

```
    US-OMA-GC-CL01-D001C220R0204   usoma01-01   size 348.5GB  avail 19.34GB  used 94%   ** ALERT: under 20GB **
    US-OMA-GC-CL01-D001C220R0204   usoma01-02   size 348.5GB  avail 210.1GB  used 36%   OK
```

Then three files in `report/`:

| File | What it is |
|------|-----------|
| `vol0_by_cluster.txt` | one line per cluster, tightest first — the work list, stamp by stamp |
| `vol0_usage.csv` | every node: `region,cluster,node,volume,size,available,used,available_gb,status` (opens in Excel; `available_gb` is a plain number so it sorts) |
| `vol0_low_space.txt` | just the nodes under the threshold |

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
