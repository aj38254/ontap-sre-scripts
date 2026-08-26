#!/usr/bin/env bash
#
# vol0 free-space check across the ONTAP production fleet.
#
# Self-contained: no other script, file or map is required. Run it from your
# ADMIN MACHINE (the box where login.sh lives) and for each region it will:
#     1. call   ./login.sh <region>     -> lands on that region's jumphost
#     2. ssh    <user>@<cluster-ip>     -> for every cluster in that region
#     3. run    vol show -volume vol0   -> and pull the numbers back here
#
#   ./ontap_vol0_check.sh                  # every cluster, one go   <- the usual run
#   ./ontap_vol0_check.sh priority         # us-c1 us-e4 us-w3 na-ne2 us-w4
#   ./ontap_vol0_check.sh us-c1 na-ne2     # named regions
#   ./ontap_vol0_check.sh US-OMA-GC-CL01-D001C220R0204     # one cluster
#   ./ontap_vol0_check.sh report           # rebuild the report, no logins
#   ./ontap_vol0_check.sh list             # show the inventory
#
# Any node with less than MIN_FREE_GB (20GB) available is flagged ALERT — those
# are the stamps needing core dumps and packet traces cleared.
#
# If you are ALREADY sitting on a jumphost (no login.sh present), it skips the
# login.sh hop and ssh's to the clusters directly.
#
# Passwords are resolved per cluster: $ONTAP_PASSWORD -> GCP Secret Manager ->
# prompt. They are never written to disk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOL0DIR="${VOL0DIR:-$SCRIPT_DIR/vol0}"
REPORTDIR="${REPORTDIR:-$SCRIPT_DIR/report}"
LOGIN_SH="${LOGIN_SH:-$SCRIPT_DIR/login.sh}"
SECRETS_MAP="${SECRETS_MAP:-$SCRIPT_DIR/secrets_map.txt}"
PROJECT_MAP="${PROJECT_MAP:-$SCRIPT_DIR/project_map.txt}"
SSH_USER="${SSH_USER:-admin}"
GCP_PROJECT="${GCP_PROJECT:-}"
MODE="${MODE:-auto}"          # auto | login | direct
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
MAX_SECRETS="${MAX_SECRETS:-4}"   # credentials tried per cluster before asking
MIN_FREE_GB="${MIN_FREE_GB:-20}"
PRIORITY_REGIONS="${PRIORITY_REGIONS:-us-c1 us-e4 us-w3 na-ne2 us-w4}"

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password"
# shellcheck disable=SC2206
SSH_OPTS=( $SSH_OPTS_STR )

# row 0 stops pagination truncating a multi-node cluster.
VOL0_CMD='set d; row 0; vol show -volume vol0 -fields used,available,size'

# Clusters whose Secret Manager secret is named nothing like the cluster, so it
# can't be found by searching for the cluster name. Without a line here the
# script has nothing to try and has to ask.
#
#   <cluster-as-in-the-inventory>   <secret-name>   [user]
#
# The user is inferred from the secret name (-SRE-RW -> sre-rw, -SRE-RO ->
# sre-ro, anything else -> admin), so the third column is only needed to
# override that. Several lines for one cluster are fine — they're tried in the
# order written, before the name-based guesses.
#
# Kept inline so this script is one self-contained file. A secrets_map.txt next
# to the script (or SECRETS_MAP=path) is read on top of this list, not instead
# of it.
# Find more with:  ./ontap_vol0_check.sh secrets <region>     (??? = no match)
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
shq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }

SECRET_CACHE="$(mktemp -d 2>/dev/null || printf '/tmp/vol0.%s' "$$")"
mkdir -p "$SECRET_CACHE"
trap 'rm -rf "$SECRET_CACHE"' EXIT

usage() {
  cat <<USAGE
Usage:
  ./ontap_vol0_check.sh                  every cluster in the inventory, one go
  ./ontap_vol0_check.sh priority         $PRIORITY_REGIONS
  ./ontap_vol0_check.sh <region>...      e.g. us-c1 na-ne2
  ./ontap_vol0_check.sh <cluster>...     a single stamp
  ./ontap_vol0_check.sh report           rebuild from saved captures, no logins
  ./ontap_vol0_check.sh list             show the inventory
  ./ontap_vol0_check.sh secrets [target] which secret will be tried per cluster

Credentials are tried in order without asking: the secret named after the
cluster (admin), then -SRE-RW, then -SRE-RO. You are only prompted once every
one of them has been refused. Clusters whose secret is named nothing like the
cluster go in secrets_map.txt — "./ontap_vol0_check.sh secrets" lists them as ???.

Runs on every node of every selected cluster:
  $VOL0_CMD

Anything with less than ${MIN_FREE_GB}GB available is flagged ALERT — those stamps need core
dumps and packet traces cleared.

Writes:
  vol0/<region>/<cluster>.txt   raw capture, per cluster
  report/vol0_by_cluster.txt    one line per cluster, tightest first — the work list
  report/vol0_usage.csv         region,cluster,node,volume,size,available,used,available_gb,status,login
  report/vol0_low_space.txt     just the ALERT nodes

Environment:
  MIN_FREE_GB=n     alert threshold in GB           (default: 20)
  PRIORITY_REGIONS  what "priority" means           (default: $PRIORITY_REGIONS)
  LOGIN_SH=path     path to your login.sh           (default: alongside this script)
  MODE=login|direct force the hop mode              (default: auto-detect)
  ONTAP_PASSWORD    one password for all clusters   (skips Secret Manager)
  ASK_CREDS=1       always prompt for user/password (skips Secret Manager)
  GCP_PROJECT       force one project for all Secret Manager lookups
  PROJECT_MAP=file  per-region projects, "region project" (default: netapp-<region>-sde)
  SECRETS_MAP=file  extra per-cluster secrets, "vserver secret [user]", added
                    to the list built into this script
  SSH_USER          default cluster user            (default: admin, overridable at the prompt)
  MAX_SECRETS=n     credentials tried before asking (default: 4)
  MAX_ATTEMPTS=n    prompt-and-retry rounds         (default: 3)

Self-contained: one file, no other script or folder needed. It needs your own
login.sh to hop to a jumphost (or MODE=direct if you are already on one), plus
sshpass and gcloud on that host.
USAGE
}

# ---------------------------------------------------------------- inventory --

# emits "region vserver ip" lines matching <target> (a region, a vserver, or "all")
select_clusters() {
  local target="$1" t; t="$(lc "$target")"
  while read -r region vserver ip; do
    [[ -z "${region:-}" || "${region:0:1}" == "#" ]] && continue
    if [[ "$t" == "all" || "$t" == "$(lc "$region")" || "$t" == "$(lc "$vserver")" ]]; then
      printf '%s %s %s\n' "$region" "$vserver" "$ip"
    fi
  done <<< "$INVENTORY"
}

# No early `exit` in awk: quitting mid-stream closes the pipe under select_clusters
# and every remaining printf there dies with "write error: Broken pipe".
ip_for() {
  select_clusters all \
    | awk -v v="$1" 'BEGIN { v=tolower(v) } tolower($2)==v && !seen { print $3; seen=1 }'
}

# "region vserver ip" for everything named, plus the "all" and "priority" shorthands.
select_targets() {
  local a m r out=""
  for a in "$@"; do
    case "$(lc "$a")" in
      all)      out+="$(select_clusters all)"$'\n' ;;
      priority) for r in $PRIORITY_REGIONS; do
                  m="$(select_clusters "$r")"
                  [[ -z "$m" ]] && { printf 'ERROR: priority region not in the inventory: %s\n' "$r" >&2; return 1; }
                  out+="$m"$'\n'
                done ;;
      *)        m="$(select_clusters "$a")"
                [[ -z "$m" ]] && { printf 'ERROR: not a region or cluster in the inventory: %s  (try: ./ontap_vol0_check.sh list)\n' "$a" >&2; return 1; }
                out+="$m"$'\n' ;;
    esac
  done
  printf '%s' "$out" | awk 'NF' | sort -u -k1,1 -k2,2
}

# ---------------------------------------------------------------- passwords --

# Secrets live in the region's own project. Default naming: netapp-<region>-sde.
# Override globally with GCP_PROJECT, or per region via project_map.txt ("region project").
project_for() {
  local region="$1" p
  [[ -n "$GCP_PROJECT" ]] && { printf '%s' "$GCP_PROJECT"; return 0; }
  if [[ -f "$PROJECT_MAP" ]]; then
    p="$(awk -v r="$region" '$1==r {print $2; exit}' "$PROJECT_MAP")"
    [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  fi
  printf 'netapp-%s-sde' "$region"
}

# Every secret in the region's project. Cached: one gcloud call per project
# answers for all of that region's clusters instead of one call per cluster.
project_secrets() {
  local region="$1" proj cache
  proj="$(project_for "$region")"
  cache="$SECRET_CACHE/$proj"
  if [[ ! -f "$cache" ]]; then
    if command -v gcloud >/dev/null 2>&1; then
      gcloud secrets list --project "$proj" --format='value(name)' \
        </dev/null 2>/dev/null >"$cache"
    else
      : >"$cache"
    fi
  fi
  cat "$cache"
}

# The ONTAP account that goes with a secret, read off its name.
user_for_secret() {
  case "$(lc "$1")" in
    *sre?rw)         printf 'sre-rw' ;;
    *sre?ro|*sre?r0) printf 'sre-ro' ;;
    *)               printf '%s' "$SSH_USER" ;;
  esac
}

# OKM passphrases, backup keys and the like sit next to the credentials and are
# never something you can log in with.
is_credential_secret() {
  case "$(lc "$1")" in
    *okm*|*passphrase*|*backup*|*cert*|*keyfile*) return 1 ;;
  esac
  return 0
}

# Ordered "secret<TAB>user" candidates for a cluster, best first.
#
# The whole point of the list: the secret named after the cluster holds the
# admin password, but plenty of stamps refuse that account and only accept
# sre-rw. Rather than asking a human the moment admin is refused, every
# plausible credential is handed over and tried in turn.
#
# Order: secrets_map.txt, then <cluster>, <cluster>-SRE-RW, <cluster>-SRE-RO,
# <cluster>-admin, then anything else in the project naming this cluster.
# A secrets_map.txt sitting next to the script adds to the built-in list rather
# than replacing it, and is read first so its lines are tried first. Dropping one
# new line in a file must never silently lose the entries already worked out.
secrets_map_data() {
  { [[ -f "$SECRETS_MAP" ]] && cat "$SECRETS_MAP"
    printf '%s\n' "$SECRETS_BUILTIN"
  } | awk '$1 !~ /^#/ && NF >= 2 && !seen[tolower($1) " " tolower($2)]++'
}

credential_candidates() {
  local vserver="$1" region="$2" list

  {
    # The map is where clusters whose secret is named nothing like the cluster
    # are recorded. Several lines per cluster is fine; they're tried in order.
    secrets_map_data | awk -v v="$(lc "$vserver")" '
      $1 ~ /^#/ { next }
      tolower($1) == v && $2 != "" { print $2 "\t" $3 }
    '

    list="$(project_secrets "$region" | grep -i -- "$vserver")"
    if [[ -n "$list" ]]; then
      printf '%s\n' "$list" | grep -ix  -- "$vserver"
      printf '%s\n' "$list" | grep -iE -- "^${vserver}[-_]SRE[-_]RW$"
      printf '%s\n' "$list" | grep -iE -- "^${vserver}[-_]SRE[-_]R[O0]$"
      printf '%s\n' "$list" | grep -iE -- "^${vserver}[-_]admin$"
      printf '%s\n' "$list"
    fi
  } | while IFS=$'\t' read -r s u; do
        [[ -z "$s" ]] && continue
        is_credential_secret "$s" || continue
        printf '%s\t%s\n' "$s" "${u:-$(user_for_secret "$s")}"
      done | awk -F'\t' '!seen[tolower($1)]++'
}

secret_password() {
  local secret="$1" region="$2" raw
  raw="$(gcloud secrets versions access latest --secret="$secret" \
           --project "$(project_for "$region")" </dev/null 2>/dev/null)" || return 1
  [[ -z "$raw" ]] && return 1
  extract_password "$raw"
}

# Secret payloads are usually JSON like {"password":"..."}; fall back to raw text.
extract_password() {
  local raw="$1" pw=""
  if printf '%s' "$raw" | grep -q '"password"'; then
    if command -v python3 >/dev/null 2>&1; then
      pw="$(printf '%s' "$raw" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("password",""), end="")
except Exception: pass' 2>/dev/null)"
    fi
    [[ -z "$pw" ]] && pw="$(printf '%s' "$raw" \
      | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  [[ -z "$pw" ]] && pw="$raw"
  printf '%s' "$pw"
}

# CRED_USERS / CRED_PWS are parallel: credential N is CRED_USERS[N] + CRED_PWS[N],
# best first. Filled by gather_creds or prompt_creds, which must be called
# directly (never in a command substitution) or the globals are lost.
CRED_USERS=()
CRED_PWS=()
CRED_DESC=""

# Every credential Secret Manager can offer for this cluster, up to MAX_SECRETS.
gather_creds() {
  local vserver="$1" region="$2" secret user pw
  CRED_USERS=(); CRED_PWS=(); CRED_DESC=""

  if [[ -n "${ONTAP_PASSWORD:-}" ]]; then
    CRED_USERS=( "$SSH_USER" ); CRED_PWS=( "$ONTAP_PASSWORD" )
    CRED_DESC="\$ONTAP_PASSWORD ($SSH_USER)"
    return 0
  fi

  while IFS=$'\t' read -r secret user; do
    [[ -z "$secret" ]] && continue
    (( ${#CRED_USERS[@]} >= MAX_SECRETS )) && break
    pw="$(secret_password "$secret" "$region")" || continue
    [[ -z "$pw" ]] && continue
    CRED_USERS+=( "$user" ); CRED_PWS+=( "$pw" )
    CRED_DESC+="${CRED_DESC:+, }$secret($user)"
  done < <(credential_candidates "$vserver" "$region")

  (( ${#CRED_USERS[@]} > 0 ))
}

# Which accounts a previous attempt already burned through, from its capture.
tried_users() {
  [[ -f "${1:-}" ]] || return 0
  sed -n 's/^===TRIED=== //p' "$1" | awk '{ printf "%s%s", sep, $1; sep=", " }'
}

# Last resort, once every candidate has been refused.
prompt_creds() {
  local vserver="$1" region="$2" tried="${3:-}" proj u="" pw="" near=""
  proj="$(project_for "$region")"
  CRED_USERS=(); CRED_PWS=(); CRED_DESC="typed in"

  printf '\n    %s  [%s]\n' "$vserver" "$region" >&2
  [[ -n "$tried" ]] && printf '      refused : %s\n' "$tried" >&2
  printf '      project : %s\n' "$proj" >&2
  printf '      secrets : https://console.cloud.google.com/security/secret-manager?project=%s\n' "$proj" >&2
  printf '      search  : %s\n' "$vserver" >&2

  # Nothing in the project is named after this cluster, so searching for it will
  # find nothing. Show the region's credential secrets instead — the right one is
  # in that list under some other name, and belongs in secrets_map.txt so this
  # cluster is never asked about again.
  if ! project_secrets "$region" | grep -qi -- "$vserver"; then
    near="$(project_secrets "$region" | grep -iE -- '[-_](SRE[-_]R[WO0]|admin)$' | sort | head -n 25)"
    if [[ -n "$near" ]]; then
      printf '      no secret names this cluster. This region has:\n' >&2
      # shellcheck disable=SC2086
      printf '        %s\n' $near >&2
      printf '      add the right one to %s as: %s <secret>\n' "$SECRETS_MAP" "$vserver" >&2
    fi
  fi

  printf '      username [%s]: ' "$SSH_USER" >&2
  read -r u </dev/tty
  printf '      password: ' >&2
  read -rs pw </dev/tty; printf '\n' >&2

  [[ -z "$pw" ]] && return 1
  CRED_USERS=( "${u:-$SSH_USER}" ); CRED_PWS=( "$pw" )
  return 0
}

# Fills CRED_* for one cluster: secrets first, prompt only if that comes up empty
# (or on a retry, where the secrets have already been proven wrong).
prepare_creds() {
  local vserver="$1" region="$2" retry="${3:-0}" prev="${4:-}"

  if [[ "$retry" == "1" || "${ASK_CREDS:-0}" == "1" ]]; then
    prompt_creds "$vserver" "$region" "$(tried_users "$prev")"
    return $?
  fi

  if gather_creds "$vserver" "$region"; then
    printf '    %-38s <- %s\n' "$vserver" "$CRED_DESC" >&2
    return 0
  fi

  prompt_creds "$vserver" "$region" ""
}

# ------------------------------------------------------------------ capture --

# A capture counts only if ONTAP actually answered about vol0. An ssh error or a
# login banner must not be mistaken for "no alert".
#
# ===USER=== is written only after a login succeeded, so when the markers are
# present they are the answer — a refused attempt's error text can't be mistaken
# for real output.
valid_vol0() {
  [[ -s "$1" ]] || return 1
  grep -q '^===USER===' "$1"  && return 0
  grep -q '^===TRIED===' "$1" && return 1
  grep -qw 'vol0' "$1" || grep -qi 'no entries matching\|there are no entries' "$1"
}

# The account that finally got in.
capture_user() { sed -n 's/^===USER=== //p' "${1:-}" 2>/dev/null | head -n1; }

# Why a cluster came back unusable, in a few words, from its own output.
vol0_failure_reason() {
  local f="$1" t
  [[ -s "$f" ]] || { printf 'no output'; return; }

  t="$(sed -n 's/^===TRIED=== //p' "$f" | awk '{ printf "%s%s", sep, $0; sep=" | " }')"
  [[ -n "$t" ]] && { printf '%s' "$t" | cut -c1-100; return; }

  if   grep -qi 'permission denied\|authentication fail\|access denied' "$f"; then printf 'bad username/password'
  elif grep -qi 'timed out\|no route to host\|refused\|unreachable'      "$f"; then printf 'unreachable'
  elif grep -qi 'not authorized\|insufficient privileges'                "$f"; then printf 'user lacks rights'
  else tr -d '\r' <"$f" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-60
  fi
}

# Clusters that never answered. Counted so the summary can say the report is
# incomplete rather than quietly reading as "all clear".
FAILED=0
FAILED_LIST=""

note_failure() {
  local vs="$1" f="$2" why; why="$(vol0_failure_reason "$f")"
  FAILED=$(( FAILED + 1 ))
  FAILED_LIST+="$(printf '  %-38s %s' "$vs" "$why")"$'\n'
  printf '    %-38s FAILED   %s\n' "$vs" "$why"
}

build_vol0_block() {
  local region="$1" vslist="$2" retry="${3:-0}" vs ip i args

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'

  # Walks the credentials on the jumphost, so a cluster that refuses the admin
  # secret falls through to sre-rw and sre-ro inside the same hop instead of
  # coming back here to ask a human.
  printf '%s\n' '__vol0_try() {
  __ip=$1; __cmd=$2; shift 2
  while [ $# -ge 2 ]; do
    __u=$1; __p=$2; shift 2
    __out=$(SSHPASS="$__p" sshpass -e ssh -n '"$SSH_OPTS_STR"' "$__u@$__ip" "$__cmd" 2>&1)
    case "$__out" in
      *vol0*|*"no entries"*)
        printf "===USER=== %s\n%s\n" "$__u" "$__out"
        return 0 ;;
    esac
    printf "===TRIED=== %s : %s\n" "$__u" "$(printf "%s" "$__out" | tr -d "\r" | grep -v "^[ 	]*$" | tail -n1)"
  done
  return 1
}'

  # fd 3 so ssh/gcloud inside the loop can't swallow the cluster list
  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    if [[ -z "$ip" ]]; then
      printf '    !! %s is not in the inventory, skipping\n' "$vs" >&2; continue
    fi
    if ! prepare_creds "$vs" "$region" "$retry" "$VOL0DIR/$region/$vs.txt"; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2; continue
    fi

    args=""
    for (( i=0; i<${#CRED_USERS[@]}; i++ )); do
      args+=" $(shq "${CRED_USERS[i]}") $(shq "${CRED_PWS[i]}")"
    done

    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf '__vol0_try %s %s%s\n' "$(shq "$ip")" "$(shq "$VOL0_CMD")" "$args"
  done 3<<< "$vslist"

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

split_vol0_log() {
  local region="$1" raw="$2"

  if grep -q '===NOSSHPASS===' "$raw" 2>/dev/null; then
    printf '    !! sshpass missing on the %s jumphost -> sudo apt-get install -y sshpass\n' "$region"
    return 1
  fi

  mkdir -p "$VOL0DIR/$region"
  tr -d '\r' <"$raw" | awk -v d="$VOL0DIR/$region" '
    /^===CLUSTER=== / { file=d "/" $2 ".txt"; next }
    /^===END===/      { file=""; next }
    file != ""        { print > file }
  '
}

# ------------------------------------------------------------------- parsing --

# region,cluster,node,volume,size,available,used,available_gb,status
#
# Column positions are read from the table header rather than assumed: ONTAP
# prints -fields in its own order, not the order they were asked for.
parse_vol0() {
  local f="$1" region="$2" cluster="$3" login
  login="$(capture_user "$f")"
  awk -v region="$region" -v cluster="$cluster" -v min="$MIN_FREE_GB" -v login="${login:-}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function to_gb(s,   n, u) {
      if (s !~ /^[0-9]+(\.[0-9]+)?(B|KB|MB|GB|TB|PB)$/) return -1
      n = s + 0; u = s; sub(/^[0-9]+(\.[0-9]+)?/, "", u)
      if (u == "B")  return n / 1073741824
      if (u == "KB") return n / 1048576
      if (u == "MB") return n / 1024
      if (u == "GB") return n
      if (u == "TB") return n * 1024
      if (u == "PB") return n * 1048576
      return -1
    }
    { line = trim($0) }
    line == ""                      { indata=0; prev=""; next }
    line ~ /entries were displayed/ { indata=0; next }
    line ~ /^-+([ \t]+-+)*$/ {
      nh = split(prev, h, /[ \t]+/); delete idx
      for (i = 1; i <= nh; i++) if (h[i] != "") idx[h[i]] = i
      indata = 1; prev = line; next
    }
    indata {
      n = split(line, f, /[ \t]+/)
      vol = ("volume" in idx && idx["volume"] <= n) ? f[idx["volume"]] : ""
      if (vol != "vol0") { prev = line; next }
      node = ("vserver"   in idx && idx["vserver"]   <= n) ? f[idx["vserver"]]   : "-"
      sz   = ("size"      in idx && idx["size"]      <= n) ? f[idx["size"]]      : "-"
      av   = ("available" in idx && idx["available"] <= n) ? f[idx["available"]] : "-"
      us   = ("used"      in idx && idx["used"]      <= n) ? f[idx["used"]]      : "-"
      gb   = to_gb(av)
      status = (gb < 0) ? "UNKNOWN" : (gb < min ? "ALERT" : "OK")
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", region, cluster, node, vol, sz, av, us,
             (gb < 0 ? "" : sprintf("%.2f", gb)), status, login
    }
    { prev = line }
  ' "$f"
}

# What the run just found on one cluster, so a tight stamp is obvious on the
# console instead of only at the end.
show_cluster() {
  local region="$1" vs="$2" f="$3" node sz av us gb status login any=0

  login="$(capture_user "$f")"
  [[ -n "$login" ]] && printf '    %-38s logged in as %s\n' "$vs" "$login"

  while IFS=, read -r _ _ node _ sz av us gb status _; do
    [[ -z "$node" ]] && continue
    any=1
    if [[ "$status" == "ALERT" ]]; then
      printf '    %-38s %-22s size %-10s avail %-10s used %-6s  ** ALERT: under %sGB **\n' \
        "$vs" "$node" "$sz" "$av" "$us" "$MIN_FREE_GB"
    else
      printf '    %-38s %-22s size %-10s avail %-10s used %-6s  %s\n' \
        "$vs" "$node" "$sz" "$av" "$us" "$status"
    fi
  done < <(parse_vol0 "$f" "$region" "$vs")

  (( any )) || printf '    %-38s no vol0 row in the output\n' "$vs"
}

# ------------------------------------------------------------------- collect --

check_via_login() {
  local targets="$1"
  [[ -x "$LOGIN_SH" ]] || die "login.sh not found/executable at $LOGIN_SH  (set LOGIN_SH=/path/to/login.sh)"

  local region in_region pending block raw vs attempt done_list f
  for region in $(printf '%s\n' "$targets" | awk '{print $1}' | sort -u); do
    in_region="$(printf '%s\n' "$targets" | awk -v r="$region" '$1==r {print $2}' | sort -u)"
    printf '\n==> %s : %s %s\n' "$region" "$LOGIN_SH" "$region"

    mkdir -p "$VOL0DIR/$region"
    while read -r vs; do [[ -n "$vs" ]] && rm -f "$VOL0DIR/$region/$vs.txt"; done <<< "$in_region"

    pending="$in_region"
    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      [[ -z "$pending" ]] && break
      raw="$VOL0DIR/_session_$region.log"
      if (( attempt > 1 )); then
        raw="$VOL0DIR/_session_${region}_try$attempt.log"
        printf '\n    %s cluster(s) did not answer — attempt %s of %s, enter credentials\n' \
          "$(grep -c . <<< "$pending")" "$attempt" "$MAX_ATTEMPTS"
      fi

      block="$(build_vol0_block "$region" "$pending" "$(( attempt > 1 ? 1 : 0 ))")"
      grep -q '===CLUSTER===' <<< "$block" || { printf '    skipped (no credentials)\n'; break; }

      printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
      split_vol0_log "$region" "$raw" || break

      done_list=""
      while read -r vs; do
        [[ -z "$vs" ]] && continue
        valid_vol0 "$VOL0DIR/$region/$vs.txt" && done_list+="$vs"$'\n'
      done <<< "$pending"
      pending="$(comm -23 <(printf '%s\n' "$pending" | sort -u) \
                          <(printf '%s' "$done_list" | sort -u) | grep . || true)"
    done

    while read -r vs; do
      [[ -z "$vs" ]] && continue
      f="$VOL0DIR/$region/$vs.txt"
      if valid_vol0 "$f"; then show_cluster "$region" "$vs" "$f"
      else note_failure "$vs" "$f"
      fi
    done <<< "$in_region"
  done
}

check_direct() {
  local targets="$1"
  command -v sshpass >/dev/null 2>&1 || die "sshpass not installed. Try: sudo apt-get install -y sshpass"

  local region vs ip f attempt i out
  while read -r region vs ip <&3; do
    [[ -z "$vs" ]] && continue
    mkdir -p "$VOL0DIR/$region"
    f="$VOL0DIR/$region/$vs.txt"
    rm -f "$f"

    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      if ! prepare_creds "$vs" "$region" "$(( attempt > 1 ? 1 : 0 ))" "$f"; then
        printf '    %-38s SKIP (no password)\n' "$vs"; break
      fi

      # Same fall-through as the jumphost path: try each credential in turn and
      # keep the output of the one that got in.
      : >"$f"
      for (( i=0; i<${#CRED_USERS[@]}; i++ )); do
        out="$(SSHPASS="${CRED_PWS[i]}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
                 "${CRED_USERS[i]}@$ip" "$VOL0_CMD" 2>&1)"
        if grep -qw 'vol0' <<< "$out" || grep -qi 'no entries' <<< "$out"; then
          printf '===USER=== %s\n%s\n' "${CRED_USERS[i]}" "$out" >>"$f"
          break
        fi
        printf '===TRIED=== %s : %s\n' "${CRED_USERS[i]}" \
          "$(tr -d '\r' <<< "$out" | grep -v '^[[:space:]]*$' | tail -n1)" >>"$f"
      done

      valid_vol0 "$f" && break
    done

    if valid_vol0 "$f"; then show_cluster "$region" "$vs" "$f"
    else note_failure "$vs" "$f"
    fi
  done 3< <(printf '%s\n' "$targets")
}

# -------------------------------------------------------------------- report --

build_report() {
  [[ -d "$VOL0DIR" ]] || die "no captures yet — run ./ontap_vol0_check.sh first"
  mkdir -p "$REPORTDIR"

  local csv="$REPORTDIR/vol0_usage.csv"
  local low="$REPORTDIR/vol0_low_space.txt"
  local per="$REPORTDIR/vol0_by_cluster.txt"

  printf 'region,cluster,node,volume,size,available,used,available_gb,status,login\n' >"$csv"
  local f vs region
  while IFS= read -r f <&3; do
    vs="$(basename "$f" .txt)"
    region="$(basename "$(dirname "$f")")"
    valid_vol0 "$f" || continue
    parse_vol0 "$f" "$region" "$vs"
  done 3< <(find "$VOL0DIR" -type f -name '*.txt' ! -name '_session_*' | sort) \
    | sort -t, -k8,8n >>"$csv"

  # Lowest free space first: that's the cleanup queue, in the order to work it.
  awk -F, 'NR>1 && $9=="ALERT" { printf "%-8s %-38s %-22s size %-10s avail %-10s used %s\n", $1,$2,$3,$5,$6,$7 }' \
    "$csv" >"$low"

  # One line per cluster — this is what you act on stamp by stamp.
  awk -F, -v min="$MIN_FREE_GB" '
    NR > 1 {
      k = $1 "\t" $2
      if (!(k in nodes)) { order[++o] = k }
      nodes[k]++
      if ($9 == "ALERT")   alert[k]++
      if ($9 == "UNKNOWN") unk[k]++
      if ($10 != "")       login[k] = $10
      gb = ($8 == "" ? -1 : $8 + 0)
      if (gb >= 0 && (!(k in minv) || gb < minv[k])) { minv[k] = gb; minav[k] = $6 }
    }
    END {
      for (i = 1; i <= o; i++) {
        k = order[i]; split(k, p, "\t")
        state = (alert[k] ? sprintf("ALERT  %d node(s) under %sGB", alert[k], min) \
               : unk[k]   ? "CHECK  available not parsed" : "OK")
        printf "%.2f\t%-8s %-38s %2d node(s)  lowest free %-10s %-8s %s\n",
               (k in minv ? minv[k] : 999999), p[1], p[2], nodes[k],
               (k in minav ? minav[k] : "-"), (k in login ? login[k] : "-"), state
      }
    }
  ' "$csv" | sort -n | cut -f2- >"$per"

  local nodes alerts unknown clusters bad
  nodes="$(( $(wc -l <"$csv" | tr -d ' ') - 1 ))"
  alerts="$(grep -c . "$low" || true)"
  unknown="$(awk -F, 'NR>1 && $9=="UNKNOWN"' "$csv" | grep -c . || true)"
  clusters="$(grep -c . "$per" || true)"
  bad="$(grep -c 'ALERT' "$per" || true)"

  printf '\n%-32s %s\n' 'Clusters reported'   "$clusters"
  printf '%-32s %s\n'   'vol0 rows (nodes)'   "$nodes"
  printf '%-32s %s\n'   "Clusters under ${MIN_FREE_GB}GB"  "$bad"
  printf '%-32s %s\n'   "Nodes under ${MIN_FREE_GB}GB"     "$alerts"
  printf '%-32s %s\n'   'Available not parsed' "$unknown"

  printf '\nCluster by cluster, tightest first:\n\n'
  cat "$per"

  if [[ "$alerts" -gt 0 ]]; then
    printf '\n** %s node(s) on %s cluster(s) under %sGB free — clear core dumps / packet traces **\n\n' \
      "$alerts" "$bad" "$MIN_FREE_GB"
    cat "$low"
  else
    printf '\nEvery node reported at least %sGB free.\n' "$MIN_FREE_GB"
  fi

  printf '\n  %s\n  %s\n  %s\n' "$per" "$csv" "$low"
}

# ------------------------------------------------------------------- secrets --

# What Secret Manager can offer for each cluster, in the order it will be tried.
# Run this to find the clusters whose secret is named nothing like the cluster
# (they come out as ???) and paste the fix into secrets_map.txt.
show_secrets() {
  local targets region vs ip secret user n
  targets="$(select_targets "$@")" || exit 1

  printf '%-38s %-52s %s\n' 'CLUSTER' 'SECRET' 'USER'
  while read -r region vs ip <&3; do
    [[ -z "$vs" ]] && continue
    n=0
    while IFS=$'\t' read -r secret user; do
      [[ -z "$secret" ]] && continue
      printf '%-38s %-52s %s\n' "$vs" "$secret" "$user"
      n=$(( n + 1 ))
    done < <(credential_candidates "$vs" "$region")
    (( n == 0 )) && printf '%-38s %-52s %s\n' "$vs" '???' "nothing in $(project_for "$region") names this cluster"
  done 3< <(printf '%s\n' "$targets")
}

# ---------------------------------------------------------------------- main --

run_check() {
  local targets mode="$MODE"
  targets="$(select_targets "$@")" || exit 1
  [[ -z "$targets" ]] && die "nothing selected"

  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }
  printf 'Checking vol0 on %s cluster(s) across %s region(s), alerting under %sGB free.\n' \
    "$(grep -c . <<< "$targets")" \
    "$(printf '%s\n' "$targets" | awk '{print $1}' | sort -u | grep -c .)" \
    "$MIN_FREE_GB"

  case "$mode" in
    login)  check_via_login "$targets" ;;
    direct) check_direct    "$targets" ;;
    *)      die "unknown MODE=$mode" ;;
  esac

  build_report

  if (( FAILED )); then
    printf '\n%s cluster(s) never answered, so this report is incomplete:\n%s' \
      "$FAILED" "$FAILED_LIST"
    printf 'Re-run just those: ./ontap_vol0_check.sh %s\n' \
      "$(printf '%s' "$FAILED_LIST" | awk '{printf "%s ", $1}')"
    return 1
  fi
}

case "${1:-}" in
  report)          build_report ;;
  list)            select_clusters all ;;
  secrets)         shift; show_secrets "${@:-all}" ;;
  -h|--help|help)  usage ;;
  check)           shift; run_check "${@:-all}" ;;   # accepted, but not needed
  "")              run_check all ;;
  *)               run_check "$@" ;;
esac
