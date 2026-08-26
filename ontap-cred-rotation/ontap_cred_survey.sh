#!/usr/bin/env bash
#
# Pre-work survey for the quarterly ONTAP credential rotation.
#
# Answers the one question that decides whether a cluster can be rotated on its
# own: WHICH ACCOUNT IS THE CONTROL PLANE USING? That lives in the `username`
# column of the `host` table in the regional `cvs` Postgres database.
#
#   username = sde / svc-sde   -> rotating `admin` is self-contained, go ahead
#   username = admin           -> ABORT. Rotating admin cuts the control plane
#                                 off unless the new credentials are also pushed
#                                 in through the CVI API (PUT /v1/host).
#
# It joins that against the cluster inventory, the Secret Manager secrets that
# hold each cluster's passwords, and (optionally) the local accounts already
# captured by the access review, into one table per cluster.
#
#   ./ontap_cred_survey.sh hosts            # query every region's cvs DB
#   ./ontap_cred_survey.sh hosts us-c1      # one region
#   ./ontap_cred_survey.sh survey           # build the table from what's saved
#   ./ontap_cred_survey.sh list             # show the inventory
#
# Read-only. It changes no password and touches no cluster — it only reads the
# regional database, so it is safe to run before the change ticket exists.
#
# Run it from your ADMIN MACHINE (the box where login.sh lives). No ONTAP
# credentials are needed: the query runs on the jumphost, not on the clusters.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTDIR="${HOSTDIR:-$SCRIPT_DIR/hosts}"
REPORTDIR="${REPORTDIR:-$SCRIPT_DIR/report}"
LOGIN_SH="${LOGIN_SH:-$SCRIPT_DIR/login.sh}"
PROJECT_MAP="${PROJECT_MAP:-$SCRIPT_DIR/project_map.txt}"
SECRETS_MAP="${SECRETS_MAP:-$SCRIPT_DIR/secrets_map.txt}"
GCP_PROJECT="${GCP_PROJECT:-}"
MODE="${MODE:-auto}"              # auto | login | direct
NO_SECRETS="${NO_SECRETS:-0}"     # 1 = skip the Secret Manager column

# Where `security login show` captures live, for the "local accounts" column.
# Drop captures into accounts/<region>/<cluster>.txt. Blank column if there are
# none — it is a nice-to-have, not a prerequisite. ACCESS_OUT_ALT is a second
# directory to look in; it is deliberately empty by default so that this script
# never reaches into a sibling folder that may not have been copied across.
ACCESS_OUT="${ACCESS_OUT:-$SCRIPT_DIR/accounts}"
ACCESS_OUT_ALT="${ACCESS_OUT_ALT:-}"

# Clusters whose Secret Manager secret is named nothing like the cluster, so it
# cannot be found by searching for the cluster name.
#
#   <cluster-as-in-the-inventory>   <secret-name>
#
# Kept inline so this script is one self-contained file. A secrets_map.txt next
# to the script (or SECRETS_MAP=path) is read on top of this list, not instead
# of it.
read -r -d '' SECRETS_BUILTIN <<'EOF'
nl-ams-gc-sto-d001c055r059          NL-AMS-GC-STO-NL-AMS-GC-STO-D001C055R059-SRE-RW
ca-lon-gc-sto-dmtl10cg115br105      CA-LON-GC-STO-DMTL10CG115BR105-SRE-RW
CA-TOR-GC-STO-TR202021315R101       CA-TOR-GC-CL01-D002C21315R0101
DC11-11305-0105-STO                 US-QAS-GC-STO-D011C11305R0105-SRE-RW
US-AQS-GC-STO-DC1111305R0202        US-QAS-GC-STO-D011C11305R0202-SRE-RW
us-qas-gc-sto-d11c11305r104         US-QAS-GC-STO-D011C11305R0104-SRE-RW
us-qas-gc-sto-d11c11305r201         US-QAS-GC-STO-D011C11305R0201-SRE-RW
los1-360-m02-01-01-sto              LOS1-360-M02-01-01-STO-SRE-RW
us-las-gc-sto1-nap07sec06tsf09a010  US-LAS-GC-STO-D007C06TSF09AR0107-SRE-RW
EOF

# region  vserver  mgmt-ip
read -r -d '' INVENTORY <<'EOF'
as-se1  sg-jur-gc-sto-sg4c20440r105          192.168.9.4
au-se1  au-syd-gc-sto-dsy4c60300r237         192.168.6.4
eu-sw1  ES-MAD-GC-CL01-DESMAD3CBR0B01        192.168.27.4
eu-w2   ld5-01mc32-206-sto                   192.168.5.4
eu-w3   DE-FRA-GC-CL-B00HC304R001            192.168.3.4
eu-w3   DE-FRA-GC-STO-B00H304R02R105         192.168.20.4
eu-w3   DE-FRA-GC-STO-FRA1HE1303R0102        192.168.28.4
eu-w3   DE-FRA-GC-STO-FRA1HE1303R0104        192.168.29.4
eu-w3   DE-FRA-GC-STO-FRA1HE1303R0103        192.168.34.4
eu-w4   nl-ams-gc-sto-d001c055r059           192.168.8.4
eu-w4   NL-AMS-GC-STO-D001C055R058           192.168.25.4
eu-w4   NL-AMS-GC-CL01-D001CCZ55RAM14        192.168.35.4
eu-w4   NL-AMS-GC-CL01-D001CCZ55RAM15        192.168.36.4
eu-w4   NL-AMS-GC-CL01-D001CCZ55RCW56        192.168.46.4
eu-w4   NL-AMS-GC-CL01-D001CCZ55RCT57        192.168.50.4
eu-w6   CH-ZRH-CL01-D001C03R0113             192.168.40.4
na-ne1  ca-lon-gc-sto-dmtl10cg115ar101       192.168.7.4
na-ne1  ca-lon-gc-sto-dmtl10cg115br105       192.168.37.4
na-ne1  CA-LON-GC-CL01-D002CG115R0104        192.168.47.4
na-ne2  CA-TOR-GC-STO-TR202021315R101        192.168.22.4
na-ne2  CA-TOR-GC-CL01-D002C21315R0102       192.168.42.4
na-ne2  CA-TOR-GC-CL01-D002C21315R0105       192.168.49.4
us-c1   NDC-220-R1-R2-STO                    192.168.1.4
us-c1   us-oma-gc-sto-ndc220r1r4             192.168.2.4
us-c1   US-OMA-GC-STO-NDC01220R02R02         192.168.12.4
us-c1   US-OMA-GC-CL01-D001C220R0204         192.168.31.4
us-c1   US-OMA-GC-CL01-D001C220R0106         192.168.32.4
us-c1   US-OMA-GC-CL01-D001C220R0206         192.168.33.4
us-c1   US-OMA-GC-CL01-D001C220R0107         192.168.44.4
us-c1   US-OMA-GC-CL01-D001C220R0207         192.168.48.4
us-c1   US-OMA-GC-CL01-D001C220R0108         192.168.51.4
us-c1   US-OMA-GC-CL01-D001C220R0208         192.168.52.4
us-c1   US-OMA-GC-CL01-D001C220R0209         192.168.53.4
us-c1   US-OMA-GC-CL01-D001C220R0109         192.168.81.4
us-e4   DC11-11305-0105-STO                  192.168.0.4
us-e4   us-qas-gc-sto-d11c11305r104          192.168.13.4
us-e4   us-qas-gc-sto-d11c11305r201          192.168.17.4
us-e4   US-AQS-GC-STO-DC1111305R0202         192.168.18.4
us-e4   US-QAS-GC-CL01-D011C11305R0203       192.168.19.4
us-e4   US-QAS-GC-CL01-D011C11305R0103       192.168.41.4
us-e4   US-QAS-GC-CL01-D011C11305R0207       192.168.43.4
us-w2   los1-360-m02-01-01-sto               192.168.4.4
us-w2   US-LAX-GC-STO-360M02RR0205           192.168.21.4
us-w2   US-LAX-GC-STO-360M02RR0204           192.168.23.4
us-w3   US-WEJ-GC-STO-SLC01A1531R0101        192.168.11.4
us-w4   us-las-gc-sto1-nap07sec06tsf09a010   192.168.24.4
us-w4   us-las-gc-sto1-nap07sec06tsf08a0205  192.168.26.4
us-w4   US-LAS-GC-CL01-D007C06TSF09AR0204    192.168.79.4
us-w4   US-LAS-GC-CL01-D007C06TSF09AR0104    192.168.80.4
EOF

lc()  { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SECRET_CACHE="$(mktemp -d 2>/dev/null || printf '/tmp/credsurvey.%s' "$$")"
mkdir -p "$SECRET_CACHE"
trap 'rm -rf "$SECRET_CACHE"' EXIT

usage() {
  cat <<'USAGE'
Usage:
  ./ontap_cred_survey.sh hosts [region...]   read the cvs host table in each region
  ./ontap_cred_survey.sh survey [region...]  build the survey table from what's saved
  ./ontap_cred_survey.sh list                show the inventory

What it does:
  `hosts` hops to each region's jumphost via login.sh and runs, against the cvs
  database, the same query the change ticket asks for:

      select ip_address, username, external_name
        from host where type='ontap' and deleted_at is null;

  It starts the cloud-sql-proxy port-forward itself if one isn't already up, and
  reads the postgres password from the sde/postgres-credentials k8s secret.

  `survey` joins that against the inventory, the Secret Manager secrets holding
  each cluster's passwords, and the access review's captured local accounts, and
  gives each cluster a verdict:

      SAFE   control plane logs in as sde/svc-sde, so rotating admin is
             self-contained
      ABORT  control plane logs in as admin — rotating it breaks provisioning
             unless the new credentials are pushed in via the CVI API
      NO-ROW no entry in the cvs host table; find out why before touching it

Writes:
  hosts/<region>.txt              ip|username|external_name, as returned
  report/rotation_survey.csv      region,cluster,ip,cvs_username,cvs_name,secrets,local_accounts,verdict
  report/rotation_abort.txt       just the clusters needing the CVI-API path
  report/rotation_safe.txt        just the clusters that can be rotated directly

Environment:
  LOGIN_SH=path     path to your login.sh    (default: alongside this script)
  MODE=login|direct force the hop mode       (default: auto-detect)
  ACCESS_OUT=dir    `security login show` captures (default: ./accounts)
  NO_SECRETS=1      skip the Secret Manager column (faster, no gcloud)
  GCP_PROJECT       force one project for all Secret Manager lookups
  PROJECT_MAP=file  per-region projects, "region project" (default: netapp-<region>-sde)
  SECRETS_MAP=file  odd-named secrets, "cluster secret" (default: the built-in list)

Read-only: it changes no password and never logs into a cluster.

Self-contained: one file, no other script or folder needed. It needs your own
login.sh to hop to a jumphost (or MODE=direct if you are already on one), and
the usual gcloud/kubectl/psql on that host.
USAGE
}

# ---------------------------------------------------------------- inventory --

select_clusters() {
  local target="$1" t; t="$(lc "$target")"
  while read -r region vserver ip; do
    [[ -z "${region:-}" || "${region:0:1}" == "#" ]] && continue
    if [[ "$t" == "all" || "$t" == "$(lc "$region")" || "$t" == "$(lc "$vserver")" ]]; then
      printf '%s %s %s\n' "$region" "$vserver" "$ip"
    fi
  done <<< "$INVENTORY"
}

select_targets() {
  local a m out=""
  for a in "$@"; do
    case "$(lc "$a")" in
      all) out+="$(select_clusters all)"$'\n' ;;
      *)   m="$(select_clusters "$a")"
           [[ -z "$m" ]] && { printf 'ERROR: not a region or cluster in the inventory: %s\n' "$a" >&2; return 1; }
           out+="$m"$'\n' ;;
    esac
  done
  printf '%s' "$out" | awk 'NF' | sort -u -k1,1 -k2,2
}

# ------------------------------------------------------------- cvs host table --

# Runs on the jumphost. Brings up the cloud-sql-proxy port-forward only if psql
# can't already reach 5432, and takes it down again afterwards.
CVS_QUERY="select ip_address, username, external_name from host where type='ontap' and deleted_at is null order by ip_address"

build_hosts_block() {
  printf 'stty -echo 2>/dev/null\n'
  printf '%s\n' '
__PSQL=$(command -v psql 2>/dev/null || echo /usr/bin/psql)
__KUBECTL=$(command -v kubectl 2>/dev/null || echo /usr/bin/kubectl)
[ -x "$__PSQL" ] || echo "===ERR=== psql not found on this jumphost"

# kubectl stderr is kept: "no kubeconfig", "forbidden" and "secret not found"
# need completely different fixes, and swallowing it hides which one it is.
__pgpw_from() { printf "%s\n" "$1" | grep -i "password:" | head -n1 | awk "{print \$NF}" | base64 -d 2>/dev/null; }
__KOUT=$($__KUBECTL get secret -n sde postgres-credentials -o yaml 2>&1)
__PGPW=$(__pgpw_from "$__KOUT")
if [ -z "$__PGPW" ] && command -v sudo >/dev/null 2>&1; then
  __KOUT2=$(sudo -n $__KUBECTL get secret -n sde postgres-credentials -o yaml 2>&1)
  __PGPW=$(__pgpw_from "$__KOUT2")
  [ -n "$__PGPW" ] && echo "===ERR=== note: needed sudo kubectl"
fi
# Whatever the shell already has wins over nothing at all.
[ -z "$__PGPW" ] && [ -n "${CVS_PGPASS:-}" ] && __PGPW=$CVS_PGPASS
[ -z "$__PGPW" ] && [ -n "${PASS:-}" ] && __PGPW=$PASS
if [ -z "$__PGPW" ]; then
  echo "===ERR=== could not read the postgres password from k8s (sde/postgres-credentials)"
  printf "%s\n" "$__KOUT" | head -n 3 | sed "s/^/===ERR=== kubectl: /"
  echo "===ERR=== fix on this jumphost: gcloud auth login; gcloud container clusters list;"
  echo "===ERR===                       gcloud container clusters get-credentials <name> --region <region>"
fi

__CONN="host=localhost port=5432 user=postgres dbname=cvs password=$__PGPW"
__PF=""
# -w everywhere: with no password psql would sit on an interactive prompt and
# the whole run would hang on a piped session.
if ! "$__PSQL" -w "$__CONN" -Atc "select 1" >/dev/null 2>&1; then
  $__KUBECTL port-forward svc/cloud-sql-proxy -n sde 5432:5432 >/dev/null 2>&1 &
  __PF=$!
  sleep 6
fi'
  # Double quotes around the SQL: it contains 'ontap' in single quotes, which
  # would otherwise close the shell string and leave psql a bare identifier.
  printf '"$__PSQL" -w "$__CONN" -Atc "%s" 2>&1 | sed "s/^/===HOST=== /"\n' "$CVS_QUERY"
  printf '%s\n' '[ -n "$__PF" ] && kill "$__PF" >/dev/null 2>&1
echo "===END==="
exit'
}

# A region's answer is only usable if at least one row came back looking like
# "ip|user|name". An auth failure or a missing port-forward must not be filed as
# "this region has no ONTAP hosts".
valid_hosts() {
  [[ -s "${1:-}" ]] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\|' "$1"
}

collect_hosts() {
  local targets="$1" region raw out ok="" bad=""
  [[ "$MODE" != "direct" && ! -x "$LOGIN_SH" ]] && \
    die "login.sh not found/executable at $LOGIN_SH  (set LOGIN_SH=/path/to/login.sh, or MODE=direct if you are on a jumphost)"

  mkdir -p "$HOSTDIR"
  for region in $(printf '%s\n' "$targets" | awk '{print $1}' | sort -u); do
    raw="$HOSTDIR/_session_$region.log"
    out="$HOSTDIR/$region.txt"
    printf '\n==> %s : reading the cvs host table\n' "$region"

    if [[ "$MODE" == "direct" ]]; then
      build_hosts_block | sh >"$raw" 2>&1
    else
      build_hosts_block | "$LOGIN_SH" "$region" >"$raw" 2>&1
    fi

    tr -d '\r' <"$raw" | sed -n 's/^===HOST=== //p' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\|' >"$out"

    if valid_hosts "$out"; then
      printf '    %s ONTAP host(s)\n' "$(grep -c . "$out")"
      awk -F'|' '{ printf "    %-16s %-10s %s\n", $1, $2, $3 }' "$out"
      ok+="$region "
    else
      printf '    FAILED — no rows came back. Reason from the jumphost:\n'
      tr -d '\r' <"$raw" | sed -n 's/^===ERR=== /      /p'
      tr -d '\r' <"$raw" | sed -n 's/^===HOST=== /      /p' | head -n 3
      printf '      full log: %s\n' "$raw"
      rm -f "$out"
      bad+="$region "
    fi
  done

  printf '\n%-12s %s\n' 'read OK:' "${ok:-none}"
  if [[ -n "$bad" ]]; then
    printf '%-12s %s\n' 'FAILED:' "$bad"
    printf '\nThe survey will be incomplete until these are read. The usual cause is\n'
    printf 'kubectl having no credentials on that jumphost — on each one, run:\n'
    printf '    gcloud auth login\n'
    printf '    gcloud container clusters list\n'
    printf '    gcloud container clusters get-credentials <name> --region <region>\n'
    printf 'then: ./ontap_cred_survey.sh hosts %s\n' "$bad"
  fi
}

# ---------------------------------------------------------------- secrets --

project_for() {
  local region="$1" p
  [[ -n "$GCP_PROJECT" ]] && { printf '%s' "$GCP_PROJECT"; return 0; }
  if [[ -f "$PROJECT_MAP" ]]; then
    p="$(awk -v r="$region" '$1==r {print $2; exit}' "$PROJECT_MAP")"
    [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  fi
  printf 'netapp-%s-sde' "$region"
}

project_secrets() {
  local region="$1" proj cache
  proj="$(project_for "$region")"
  cache="$SECRET_CACHE/$proj"
  if [[ ! -f "$cache" ]]; then
    if [[ "$NO_SECRETS" != "1" ]] && command -v gcloud >/dev/null 2>&1; then
      gcloud secrets list --project "$proj" --format='value(name)' \
        </dev/null 2>/dev/null >"$cache"
    else
      : >"$cache"
    fi
  fi
  cat "$cache"
}

# A secrets_map.txt sitting next to the script adds to the built-in list rather
# than replacing it, and is read first so its lines are tried first. Dropping one
# new line in a file must never silently lose the entries already worked out.
secrets_map_data() {
  { [[ -f "$SECRETS_MAP" ]] && cat "$SECRETS_MAP"
    printf '%s\n' "$SECRETS_BUILTIN"
  } | awk '$1 !~ /^#/ && NF >= 2 && !seen[tolower($1) " " tolower($2)]++'
}

# Every secret holding a password for this cluster — these are the ones that
# need a new version adding once the rotation is done.
secrets_for() {
  local vserver="$1" region="$2"
  {
    secrets_map_data \
      | awk -v v="$(lc "$vserver")" '$1 !~ /^#/ && tolower($1)==v && $2!="" { print $2 }'
    project_secrets "$region" | grep -i -- "$vserver"
  } | grep -viE 'okm|passphrase|backup|cert' | awk '!seen[tolower($0)]++' \
    | awk '{ printf "%s%s", sep, $0; sep=";" }'
}

# ---------------------------------------------------------- local accounts --

# Account names captured for this cluster. Scoped to the cluster's OWN vserver
# by name, not just "not an svm_*" — a capture that scrolls past into another
# vserver's block would otherwise credit this cluster with accounts (vsadmin,
# most of all) that do not live on it.
local_accounts_for() {
  local region="$1" vserver="$2" f
  f="$ACCESS_OUT/$region/$vserver.txt"
  [[ ! -f "$f" && -n "$ACCESS_OUT_ALT" ]] && f="$ACCESS_OUT_ALT/$region/$vserver.txt"
  [[ -f "$f" ]] || return 0
  awk -v want="$(lc "$vserver")" '
    /^Vserver:/              { vs=tolower($2); indata=0; next }
    /^-{5,}/                 { indata=1; next }
    /^[[:space:]]*$/         { indata=0; next }
    /entries were displayed/ { indata=0; next }
    indata && NF>=4 && vs==want { print $1 }
  ' "$f" | sort -u | awk '{ printf "%s%s", sep, $0; sep=";" }'
}

# ----------------------------------------------------------------- survey --

# The control-plane account for an IP, from whichever region answered.
cvs_row_for() {
  local ip="$1"
  [[ -d "$HOSTDIR" ]] || return 0
  awk -F'|' -v ip="$ip" '$1==ip { print $2 "|" $3; exit }' "$HOSTDIR"/*.txt 2>/dev/null
}

build_survey() {
  local targets="$1" csv abort safe
  [[ -d "$HOSTDIR" ]] || die "no host data yet — run './ontap_cred_survey.sh hosts' first"

  mkdir -p "$REPORTDIR"
  csv="$REPORTDIR/rotation_survey.csv"
  abort="$REPORTDIR/rotation_abort.txt"
  safe="$REPORTDIR/rotation_safe.txt"

  printf 'region,cluster,ip,cvs_username,cvs_name,secrets,local_accounts,verdict\n' >"$csv"

  local region vs ip row cvs_user cvs_name secrets accounts verdict
  local n_safe=0 n_abort=0 n_norow=0 n_nodata=0 missing_regions=""
  : >"$abort"; : >"$safe"

  printf '\n%-8s %-38s %-15s %-10s %s\n' 'REGION' 'CLUSTER' 'IP' 'CVS USER' 'VERDICT'
  while read -r region vs ip <&3; do
    [[ -z "$vs" ]] && continue
    row="$(cvs_row_for "$ip")"
    cvs_user="${row%%|*}"
    cvs_name="${row#*|}"; [[ "$cvs_name" == "$row" ]] && cvs_name=""

    # "this region never answered" and "this cluster has no row" look identical
    # once the data is missing, and they mean opposite things — one is a finding,
    # the other is a gap. Never let a failed region read as a finding.
    if ! valid_hosts "$HOSTDIR/$region.txt"; then
      verdict='NO-DATA region was not read — rerun hosts for it'
      n_nodata=$(( n_nodata + 1 ))
      grep -q " $region " <<< " $missing_regions " || missing_regions+="$region "
    elif [[ -z "$cvs_user" ]]; then
      verdict='NO-ROW  not in the cvs host table'
      n_norow=$(( n_norow + 1 ))
    elif [[ "$(lc "$cvs_user")" == "admin" ]]; then
      verdict='ABORT   control plane logs in as admin'
      n_abort=$(( n_abort + 1 ))
      printf '%-8s %-38s %-15s uses %s\n' "$region" "$vs" "$ip" "$cvs_user" >>"$abort"
    else
      verdict="SAFE    control plane logs in as $cvs_user"
      n_safe=$(( n_safe + 1 ))
      printf '%-8s %-38s %-15s uses %s\n' "$region" "$vs" "$ip" "$cvs_user" >>"$safe"
    fi

    secrets="$(secrets_for "$vs" "$region")"
    accounts="$(local_accounts_for "$region" "$vs")"

    printf '%-8s %-38s %-15s %-10s %s\n' "$region" "$vs" "$ip" "${cvs_user:--}" "$verdict"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$region" "$vs" "$ip" "${cvs_user:-}" "${cvs_name:-}" "$secrets" "$accounts" "${verdict%% *}" >>"$csv"
  done 3< <(printf '%s\n' "$targets")

  # The database is the source of truth for what exists. Anything it knows about
  # that the inventory doesn't is a cluster nobody is rotating.
  local extra
  extra="$(cat "$HOSTDIR"/*.txt 2>/dev/null \
           | awk -F'|' -v inv="$(printf '%s\n' "$targets" | awk '{print $3}' | tr '\n' ' ')" '
               BEGIN { n=split(inv, a, " "); for (i=1;i<=n;i++) known[a[i]]=1 }
               !($1 in known) { printf "  %-16s %-10s %s\n", $1, $2, $3 }' | sort -u)"

  printf '\n%-34s %s\n' 'Safe to rotate admin directly' "$n_safe"
  printf '%-34s %s\n'   'Need the CVI-API path (ABORT)' "$n_abort"
  printf '%-34s %s\n'   'No row in the cvs host table'  "$n_norow"
  printf '%-34s %s\n'   'Not surveyed yet (no data)'    "$n_nodata"

  if [[ -n "$missing_regions" ]]; then
    printf '\nINCOMPLETE — %s cluster(s) have no answer because these regions could not\n' "$n_nodata"
    printf 'be read. They are NOT findings, they are gaps:\n\n  %s\n\n' "$missing_regions"
    printf 'Rerun: ./ontap_cred_survey.sh hosts %s\n' "$missing_regions"
  fi

  if [[ -n "$extra" ]]; then
    printf '\nIn the cvs host table but not in this inventory — check before the wave:\n%s\n' "$extra"
  fi

  if [[ "$n_abort" -gt 0 ]]; then
    printf '\nThese log the control plane in as admin. Rotating admin here without\n'
    printf 'also updating the host entry (PUT /v1/host) will break provisioning:\n\n'
    cat "$abort"
  fi

  printf '\n  %s\n  %s\n  %s\n' "$csv" "$safe" "$abort"
}

# ------------------------------------------------------------------- main --

case "${1:-}" in
  hosts)  shift; t="$(select_targets "${@:-all}")" || exit 1
          [[ "$MODE" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && MODE=login || MODE=direct; }
          collect_hosts "$t" ;;
  survey) shift; t="$(select_targets "${@:-all}")" || exit 1; build_survey "$t" ;;
  list)   select_clusters all ;;
  -h|--help|help|"") usage ;;
  *)      usage; exit 1 ;;
esac
