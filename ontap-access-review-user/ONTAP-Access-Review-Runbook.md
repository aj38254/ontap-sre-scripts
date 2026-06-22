# ONTAP Devices — Quarterly User Access Review Runbook

Step-by-step for the **GCNV Quarterly access review for all users (incl. privileged): ONTAP
Devices** compliance ticket (e.g. NFSAAS-163305). Reviewed by SRE personnel, **signed off by the
SRE Manager**.

> **What this task is:** every quarter, produce a complete list of ONTAP users across the whole GCNV
> fleet, review it, **remove anyone who left the company / no longer needs access**, and attach the
> evidence (current-users list + removed-users list + pre/post logs) to the Jira ticket. Then the SRE
> Manager verifies and closes it.

Refs:
- GCNV Access Control Procedure — https://confluence.ngage.netapp.com/display/CLOUDSC/GCNV+Access+Control+Procedure (§4.6 User Access Reviews: privileged access reviewed **at least quarterly**)
- Cleanup script (config-as-code, preferred): `gcnv-sre-utils/ontap-login-delete-sh/delete_ontap_usr.sh`
  — https://github.com/greenqloud/gcnv-sre-utils/tree/main/ontap-login-delete-sh
- Login/access: `ONTAP-Login-Access-Reference.md`

---

## PART 0 — Prep
- [ ] Assign the review ticket to yourself (responsible SRE personnel).
- [ ] Get the **authoritative list of valid/active users** and identify who must be removed
      (people who left the company or changed roles). Confirm with the ManagedAD/access owner by
      email (last cycle this was confirmed with the AD owner before deleting).
- [ ] Note the NetApp SSO ID → GCP TVC SSO mapping for each user to remove.

---

## PART 1 — Generate the current user list (pre-check)  → evidence
Don't log into 44 stamps by hand — use `access-review/ontap_access_review.sh` (see its README).
It calls `login.sh <region>` for you, hops to each cluster, and runs `security login show`:

```bash
./ontap_access_review.sh collect all       # every region, end to end
./ontap_access_review.sh report            # build the user lists
```
Raw per-cluster output lands in `output/<region>/<vserver>.txt` — that **is** the pre-check evidence.
- `report/unique_users.txt` — deduplicated user list (this is what you email for confirmation)
- `report/users_by_cluster.csv` — region,vserver,user,application,role
- `report/privileged_users.txt` — admin / super-users / admin-no-fsa / sre-admins accounts
- `report/user_cluster_counts.txt` — how many clusters each user exists on

- [ ] Save the combined output as the **"current users" list** to attach (last cycle: `ONTAP_current_users.xls`).

---

## PART 2 — Raise the change request (CR)
Per the Access Control Procedure, removing users needs an approved change:
- [ ] Open a **COPS change ticket** ("Review all users in all ontap stamps") listing the users to
      remove, pre-check/delete/post-check commands, and backout plan. (Last cycle: COPS-89490.)
- [ ] Get it approved before deleting.

---

## PART 3 — Remove the users (config-as-code, preferred)
Use the repo script rather than hand-running deletes (reviewer requirement). It removes the listed
users from each ONTAP vserver and writes **pre-check, delete, and post-check** logs to `logs/`.

```bash
# in the ontap-login-delete-sh dir
./delete_ontap_usr.sh --help

export SSHPASS='YOUR_PASSWORD'          # ONTAP admin password (don't paste it into the ticket)
./delete_ontap_usr.sh <REGION>          # e.g. as-se1        (whole region)
#   or
./delete_ontap_usr.sh <VSERVER>         # e.g. sg-jur-gc-sto-sg4c20440r105   (single cluster)
# logs land in ./logs/
```

Manual equivalent (only if not using the script), per cluster:
```
security login show                                            # pre-check
security login delete -user-or-group-name <user> -application <ssh|ontapi|http> \
    -authentication-method <password|publickey> -vserver <cluster_name>
security login show                                            # post-check
```

- [ ] Work through **all** in-scope clusters (see the fleet list below).

---

## PART 4 — Build the removed-users summary
Compare the PRE_CHECK vs POST_CHECK logs to produce the list of who was actually removed
(last cycle: `ONTAP_users_removed.txt`). You can do this in Cursor — open the `logs/` folder and prompt:

> Compare all files starting with PRE_CHECK and POST_CHECK and create a single file
> `ONTAP_users_removed.txt` listing users removed (present in PRE but absent in POST), tagging each
> line with the vserver/system name.

- [ ] Produce a summary: file-pairs compared, total removed entries, unique users, and per-user
      system count.

---

## PART 5 — Evidence & closeout on the review ticket
Attach to the review ticket (NFSAAS-...):
- [ ] **Current users** list (pre-check).
- [ ] **Removed users** list + the PRE/POST logs.
- [ ] The linked **COPS CR** number.
- [ ] If all remaining access is appropriate, add the required compliance comment:
      *"The list of users with access to <application/instance> seems appropriate based on user
      responsibilities and employment status."*
- [ ] If issues were found: describe the issue, the corrective action taken, and the CR raised.
- [ ] Set **Resolution: Fixed / Status: Done**, then **hand to the SRE Manager** to verify and close.

---

## GCNV ONTAP fleet (from the last review — verify current list each quarter)
| # | Region | Vserver | Mgmt IP |
|---|--------|---------|---------|
| 1 | as-se1 | sg-jur-gc-sto-sg4c20440r105 | 192.168.9.4 |
| 2 | au-se1 | au-syd-gc-sto-dsy4c60300r237 | 192.168.6.4 |
| 4 | eu-sw1 | ES-MAD-GC-CL01-DESMAD3CBR0B01 | 192.168.27.4 |
| 5 | eu-w2 | ld5-01mc32-206-sto | 192.168.5.4 |
| 6 | eu-w3 | DE-FRA-GC-CL-B00HC304R001 | 192.168.3.4 |
| 7 | eu-w3 | DE-FRA-GC-STO-B00H304R02R105 | 192.168.20.4 |
| 8 | eu-w3 | DE-FRA-GC-STO-FRA1HE1303R0102 | 192.168.28.4 |
| 9 | eu-w3 | DE-FRA-GC-STO-FRA1HE1303R0104 | 192.168.29.4 |
| 10 | eu-w3 | DE-FRA-GC-STO-FRA1HE1303R0103 | 192.168.34.4 |
| 11 | eu-w4 | nl-ams-gc-sto-d001c055r059 | 192.168.8.4 |
| 12 | eu-w4 | NL-AMS-GC-STO-D001C055R058 | 192.168.25.4 |
| 13 | eu-w4 | NL-AMS-GC-CL01-D001CCZ55RAM14 | 192.168.35.4 |
| 14 | eu-w4 | NL-AMS-GC-CL01-D001CCZ55RAM15 | 192.168.36.4 |
| 15 | eu-w4 | NL-AMS-GC-CL01-D001CCZ55RCW56 | 192.168.46.4 |
| 16 | eu-w4 | NL-AMS-GC-CL01-D001CCZ55RCT57 | 192.168.50.4 |
| 17 | eu-w6 | CH-ZRH-CL01-D001C03R0113 | 192.168.40.4 |
| 18 | na-ne1 | ca-lon-gc-sto-dmtl10cg115ar101 | 192.168.7.4 |
| 19 | na-ne1 | ca-lon-gc-sto-dmtl10cg115br105 | 192.168.37.4 |
| 20 | na-ne1 | CA-LON-GC-CL01-D002CG115R0104 | 192.168.47.4 |
| 21 | na-ne2 | CA-TOR-GC-STO-TR202021315R101 | 192.168.22.4 |
| 22 | na-ne2 | CA-TOR-GC-CL01-D002C21315R0102 | 192.168.42.4 |
| 23 | na-ne2 | CA-TOR-GC-CL01-D002C21315R0105 | 192.168.49.4 |
| 24 | us-c1 | NDC-220-R1-R2-STO | 192.168.1.4 |
| 25 | us-c1 | us-oma-gc-sto-ndc220r1r4 | 192.168.2.4 |
| 26 | us-c1 | US-OMA-GC-STO-NDC01220R02R02 | 192.168.12.4 |
| 27 | us-c1 | US-OMA-GC-CL01-D001C220R0204 | 192.168.31.4 |
| 28 | us-c1 | US-OMA-GC-CL01-D001C220R0106 | 192.168.32.4 |
| 29 | us-c1 | US-OMA-GC-CL01-D001C220R0206 | 192.168.33.4 |
| 30 | us-c1 | US-OMA-GC-CL01-D001C220R0107 | 192.168.44.4 |
| 31 | us-c1 | US-OMA-GC-CL01-D001C220R0207 | 192.168.48.4 |
| 32 | us-e4 | DC11-11305-0105-STO | 192.168.0.4 |
| 33 | us-e4 | us-qas-gc-sto-d11c11305r104 | 192.168.13.4 |
| 34 | us-e4 | us-qas-gc-sto-d11c11305r201 | 192.168.17.4 |
| 35 | us-e4 | US-AQS-GC-STO-DC1111305R0202 | 192.168.18.4 |
| 36 | us-e4 | US-QAS-GC-CL01-D011C11305R0203 | 192.168.19.4 |
| 37 | us-e4 | US-QAS-GC-CL01-D011C11305R0103 | 192.168.41.4 |
| 38 | us-e4 | US-QAS-GC-CL01-D011C11305R0207 | 192.168.43.4 |
| 39 | us-w2 | los1-360-m02-01-01-sto | 192.168.4.4 |
| 40 | us-w2 | US-LAX-GC-STO-360M02RR0205 | 192.168.21.4 |
| 41 | us-w2 | US-LAX-GC-STO-360M02RR0204 | 192.168.23.4 |
| 42 | us-w3 | US-WEJ-GC-STO-SLC01A1531R0101 | 192.168.11.4 |
| 43 | us-w4 | us-las-gc-sto1-nap07sec06tsf09a010 | 192.168.24.4 |
| 44 | us-w4 | us-las-gc-sto1-nap07sec06tsf08a0205 | 192.168.26.4 |

---

## Review DONE when
- Complete current-users list generated and attached.
- Departed/inappropriate users removed via approved CR (script pre/post logs saved).
- Removed-users summary + updated user list attached.
- Compliance comment added; ticket signed off and closed by the SRE Manager.
