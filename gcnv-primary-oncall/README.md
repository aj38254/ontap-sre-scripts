# GCNV primary on-call (PE / first line)

Cheat sheet for **who does what**. Tickets live in **NFSAAS** on ngage Jira, not Buganizer, unless Google already opened a Partner Issue Tracker case.

Source of record for engineering PagerDuty links: [Supportability & Incident Management 1P-PO, VSA and SO](https://netapp.atlassian.net/wiki/spaces/CLOUDVOL/pages/108327204/Supportability+Incident+Management+1P-PO+VSA+and+SO).

PE vs customer split: [PagerDuty - Determining who is on call](https://netapp.atlassian.net/wiki/spaces/COPS/pages/105685535/PagerDuty+-+Determining+who+is+on+call).

---

## Your role vs engineering

| You (PE / SRE primary) | Engineering on-call (page them) |
|---|---|
| Ack SLO / Buganizer page | Change SDS ConfigMap / pins / code |
| Triage logs, GKE server-config, ConfigMap | Quark / Atom / VCP / PO product bugs |
| File **NFSAAS**, Relates-link cousins | Apply the fix; you do not kubectl-edit SDS config for them |
| Page the **right** engineering rotation | |

SLO burns and production health: PE **primary** ([PUUKJU8](https://netappcvs.pagerduty.com/service-directory/PUUKJU8) Buganizer cases, [P95BFPO](https://netappcvs.pagerduty.com/service-directory/P95BFPO) SLO). Customer CRI: PE **secondary**.

---

## Who to page (SDE / engineering)

Page **by product**, not “whoever answers.”

| If it is… | Page / tag | Where |
|---|---|---|
| **GCNV SO / Flex** (SOFTWARE pool, SDS, NVC Quark GKE, `SO_*` SLO) | **Engineering SO Primary** | [P02SXLU](https://netappcvs.pagerduty.com/service-directory/P02SXLU) |
| SO no answer | Engineering SO Secondary | [PVQDHJQ](https://netappcvs.pagerduty.com/service-directory/PVQDHJQ) |
| **GCNV PO** | Engineering PO Primary | [PG9GWG9](https://netappcvs.pagerduty.com/service-directory/PG9GWG9) |
| **VCP** path (not Direct-to-SDE) | VCP Oncall | [PYOXPJT](https://netappcvs.pagerduty.com/service-directory/PYOXPJT) |
| **CCFE / frontend** (`13 INTERNAL` UUID, dashboard **frontend** / CLH only, SDE logs empty) | **Google on-call** | PIT comment or new issue cloned from an existing Google bug; `http://oncall/cloud-netapp-dev` if urgent |
| Still stuck | GCNV Engineering Manager | [P8BTEHP](https://netappcvs.pagerduty.com/schedules/P8BTEHP) |
| Quark already running (host exists, data-plane / metrics in VMDB) | Atom / CPE / Quark — see COPS runbook | not SDS pin |

**Do not** page Engineering **PO** for Flex/SO. **Do not** page **VCP** for Direct-to-SDE (`netapp-us-w8-sde` style). **Do not** page Quark first when GKE `CREATE_CLUSTER` never happened. **Do not** page Engineering SO/PO/VCP for a CCFE-generated `13 INTERNAL` UUID that is absent from SDE.

---

## Tickets: NFSAAS vs Buganizer

- **Home:** [NFSAAS](https://jira.ngage.netapp.com/projects/NFSAAS) on `jira.ngage.netapp.com`.
- **Do not** open a new Buganizer for an SDS pin / SLO you already triaged. Comment on NFSAAS. Relates-link any Google PIT Google already filed.
- Search before create (ngage JQL):

```
project = NFSAAS AND status != Done AND (text ~ "<region>" OR text ~ "<short-region>") AND (text ~ "InvalidK8sVersion" OR text ~ "pool")
```

Same error, **different region** → **create new**, Relates to the other ticket. Do not dump `us-west8` onto a `us-c1`/`us-e4` ticket.

### Escalating **to Google** (CCFE / frontend)

Buganizer **1303631** inbound (`type:customer_issue`) is where *Google* files *into* NetApp and pages [PUUKJU8](https://netappcvs.pagerduty.com/service-directory/PUUKJU8). Filing a *new* issue on that form pages **you**.

**Who:** Google on-call (PIT assignee / “AI On Google”). CC that already live on Google CCFE bugs: `gcp-netappfiles-sre-external+bugs@google.com`, `netapp-sre-ext-team+bugs@google.com`. Urgent page: `http://oncall/cloud-netapp-dev` (Chromebook + TVC) or **cloud-netapp-dev-oncall@google.com** (body lands on the pager — include the `b/` id).

**How to file a bug, not mail first:**

1. Check [status.cloud.google.com](https://status.cloud.google.com/).
2. Search PIT for an **open** Google bug on the **same method + same error**. Prefer comment over create.
3. If you must create: clone an existing Google CCFE bug (`template_issue=<id>`). Confirmed working path: `85150 > 130880 > 1285636 > 1144971 > 1302957 > External`. Clear `[Deleted User]` assignee. Leave CC groups. P2 unless a customer is down.
4. Open **NFSAAS** and Relates-link the `b/` id.

PIT: [Partner Issue Tracker](https://partnerissuetracker.corp.google.com/issues). Clone example: [b/488214785](https://partnerissuetracker.corp.google.com/issues/488214785).

**Wrong homes (do not comment the live incident there):**

| Pattern | Why |
|---|---|
| Empty “pre-deploy test” / `Int_Deploy` | Not an incident |
| CVT CrashLoop / billing / postgres secrets | Different component |
| Customer metrics in UI / VMDB | Data-plane metrics path |
| Zero-touch / C4 region-launch epic | Launch tracker, not SLO |
| COPS Emergency Change (stage GKE version) | Change vehicle for another env |
| Done / Obsolete bugs | Relates only |

**Same error, other regions (Relates, don’t hijack):** `NFSAAS-187248` (us-c1/us-e4 InvalidK8sVersion), `NFSAAS-186834` (Done, same error), `NFSAAS-113887` (obsolete precedent), `NFSAAS-121504` (SDS minor-version pin format).

Technical owner on SO/Flex SDS bugs: **Team Bangalore - GCNV**. Hyperscaler: **Google**. Where Found: **Production/Customer**.

---

## Playbook: `InvalidK8sVersion` on Flex pool create

**Symptom:** SLO `SO_ControlPlaneGlobalLROErrorTooHigh-PerLocation` / Flex SOFTWARE pool create fails with:

`InvalidK8sVersion: Unsupported and not in sync with valid Master and Node versions`

**RCA class:** SDS ConfigMap `cloud-volumes-sds-configmap` key `cvsQuarkNVCClusterK8sVersion` is **not** in GKE `validMasterVersions` for that location (often still `1.33` after GKE dropped 1.33 masters). Cluster is never created. Later SDS `ResourceNotExist` / HTTP 404 is **not** RCA.

**Not this RCA:** `GCE_STOCKOUT` (capacity); CVT crashloop; SDE `us-w8-gke` master upgrade of the **control** cluster.

### Check (SDE jumphost / Direct-to-SDE)

```bash
# pin SDS is asking GKE to use
kubectl -n sde get configmap cloud-volumes-sds-configmap -o yaml | grep -i cvsQuarkNVCClusterK8sVersion

# what GKE still allows as master
gcloud container get-server-config --location=<gcp-region>

# did GKE ever get CREATE_CLUSTER for the failed pool cluster name?
gcloud container operations list --location=<gcp-region> --filter="operationType=CREATE_CLUSTER"
```

Pin must be in **both** `validMasterVersions` and `validNodeVersions` (STABLE/REGULAR, e.g. 1.34 or 1.35). Do **not** kubectl-edit the ConfigMap; SDS owns the pin.

### Page text (SO Primary)

```
P1 <region>-<zone> Flex pool create InvalidK8sVersion.
SDS ConfigMap cvsQuarkNVCClusterK8sVersion=<pin>; GKE validMasterVersions starts at <x>.
SLO SO_ControlPlaneGlobalLROErrorTooHigh-PerLocation.
Need SDS to bump pin (do not kubectl-edit).
NFSAAS: <KEY>  Relates NFSAAS-187248 if same error other regions.
Corr <id>
```

### NFSAAS create (Bug)

- **Summary:** `[GCNV SO] [<region>-<zone>] Flex pool create failing InvalidK8sVersion — SDS pin <x> not a valid GKE master`
- **Priority:** P1 if SLO burning / pool create fully broken
- **Severity:** Major (no customer workaround; SDS must change pin)
- **Regression:** No if GKE catalog dropped the pin
- **Error Message:** Yes
- **Region:** GCP region
- **Need By Date:** same day if SLO is burning
- **Linked:** Relates `NFSAAS-187248` (and 186834 / 113887 if useful)
- **I.1 RP:** NA if Direct-to-SDE
- **I.2 SDE:** SDS image digest + `helm ls -n sde`; Affects Version = current SDE/GCNV train from dropdown (do not invent)
- **I.4 / E / F:** NA (Azure-only)

After create: one sentence on `NFSAAS-187248` with the new key; do not expand that ticket’s region list.

---

## 2026-09-02 us-west8-a (worked example)

- Pin: `1.33` on `netapp-us-w8-sde`. Masters in `us-west8` start at **1.34.9**.
- Six `InvalidK8sVersion` creates, two GCP projects, ~3h cadence. No `CREATE_CLUSTER` that day.
- Example corr: `00A58F98-005B-7DE2-0000-000000000000` (pool `cep-p1-05861c08-686f-44b7-a937-128299a419b7`).
- **NFSAAS-180818** is *not* this (empty 2617 pre-deploy test).
- CVT crashloop us-west8 / `NFSAAS-162752` PayPal metrics are **not** this.

---

## Playbook: CCFE returns `13 INTERNAL` on sync Get/List

**Symptom:** Control Plane Events v2 shows `13 (INTERNAL)` / `generic::internal: An internal error has occurred (<uuid>)` on SDE-reaching **SYNC** reads, several regions and consumer projects at once.

SYNC (this playbook), from [SLO Dashboard](https://netapp.atlassian.net/wiki/spaces/COPS/pages/105977244/SLO+Dashboard): `ListSnapshots`, `GetVolume`, `GetSnapshot`, `ListVolumes`, plus other Get/List that hit SDE the same way (`ListKmsConfigs`, `ListBackups`, `ListQuotaRules`).

**Who:** **Google on-call** (CCFE / forwarding). Do **not** page Engineering SO, PO, or VCP. You cannot see frontend/CLH; they can.

**Why SDE Logs Explorer is empty:** that `<uuid>` is **CCFE-generated**. Searching it in `netapp-us-c1-sde` (or any SDE project) returning 0 hits is expected.

### Check

1. One failure per **SYNC** method: timestamp, consumer project, region, UUID.
2. Dashboard timezone (UI may be IST; table `cloud_netapp.tmp_frontend.last30days` is UTC). State which.
3. SDE search by **time window + resource + method**, never by the CCFE UUID.
4. Search PIT for an open Google bug on that method before creating.

### Ticket (Google first)

- Same error + same signature + **open** Google bug on that method → **comment**, do not create. Rewrite as added scope, not a new bug description.
- Comment example (2026-09-02): [b/554696723](https://partnerissuetracker.corp.google.com/issues/554696723) (`ListSnapshots`). If it matches `13 INTERNAL` / generic UUID, add the other SYNC Get/List IDs there.
- Create only if that bug is closed, a different error, or ListSnapshots-only RCA that does not cover Get/List. Relates-link `b/554696723` and `b/488214785`.
- Then **NFSAAS** tracking + Relates to the `b/` id.

**Do not** dump these onto the ListSnapshots / SYNC INTERNAL bug:

| Method | Example | Why |
|---|---|---|
| `ExecuteOntapPost` | [b/554723459](https://partnerissuetracker.corp.google.com/issues/554723459) | not a monitored SYNC Get/List |
| `CreateBackupVault` | [b/554990189](https://partnerissuetracker.corp.google.com/issues/554990189) | create / likely ASYNC |
| `DeleteReplication` | [b/554705671](https://partnerissuetracker.corp.google.com/issues/554705671) | delete / likely ASYNC |
| `RestoreBackupFiles` | [b/555121464](https://buganizer.corp.google.com/issues/555121464) | restore / likely ASYNC |
| `VerifyKmsConfig` quota | `resource_exhausted: Quota exceeded … netapp-pa.googleapis.com … project_number:149985174257` | **quota**, different error. Do not mention it on the INTERNAL bug — Google will treat the ticket as quota. |

Ask Google: check CCFE / forwarding-proxy for the correlation IDs; did SDE return OK and CCFE still surface INTERNAL?

**Prior art:** [b/488214785](https://partnerissuetracker.corp.google.com/issues/488214785) — CCFE stream timeout while SDE succeeded.

### Comment if Google asks “is this the quota?”

```
No. Quota is VerifyKmsConfig resource_exhausted on netapp-pa.googleapis.com
(project_number 149985174257). This ticket is 13 INTERNAL generic UUID on
SYNC Get/List. Keep quota separate. Continue CCFE log check here.
```

---

## Add the next pattern here

When a new SLO class is triaged to a named rotation, add a row to **Who to page** and a short playbook section (symptom → check → who → ticket home). Keep this file the only copy-paste source so paging stays consistent.
