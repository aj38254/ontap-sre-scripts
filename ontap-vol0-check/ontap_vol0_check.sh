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
MIN_FREE_GB="${MIN_FREE_GB:-20}"
PRIORITY_REGIONS="${PRIORITY_REGIONS:-us-c1 us-e4 us-w3 na-ne2 us-w4}"

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password"
# shellcheck disable=SC2206
SSH_OPTS=( $SSH_OPTS_STR )

# row 0 stops pagination truncating a multi-node cluster.
VOL0_CMD='set d; row 0; vol show -volume vol0 -fields used,available,size'

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

usage() {
  cat <<USAGE
Usage:
  ./ontap_vol0_check.sh                  every cluster in the inventory, one go
  ./ontap_vol0_check.sh priority         $PRIORITY_REGIONS
  ./ontap_vol0_check.sh <region>...      e.g. us-c1 na-ne2
  ./ontap_vol0_check.sh <cluster>...     a single stamp
  ./ontap_vol0_check.sh report           rebuild from saved captures, no logins
  ./ontap_vol0_check.sh list             show the inventory

Runs on every node of every selected cluster:
  $VOL0_CMD

Anything with less than ${MIN_FREE_GB}GB available is flagged ALERT — those stamps need core
dumps and packet traces cleared.

Writes:
  vol0/<region>/<cluster>.txt   raw capture, per cluster
  report/vol0_by_cluster.txt    one line per cluster, tightest first — the work list
  report/vol0_usage.csv         region,cluster,node,volume,size,available,used,available_gb,status
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
  SECRETS_MAP=file  per-cluster secrets, "vserver secret [user]"
  SSH_USER          default cluster user            (default: admin, overridable at the prompt)
  MAX_ATTEMPTS=n    logins to try per cluster       (default: 3)
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

# All secrets in the region's project whose name mentions this cluster.
secret_candidates() {
  local vserver="$1" region="$2"
  command -v gcloud >/dev/null 2>&1 || return 1
  gcloud secrets list --project "$(project_for "$region")" --format='value(name)' \
    </dev/null 2>/dev/null | grep -i -- "$vserver"
}

# Picks the secret holding usable credentials and the username that goes with it.
# Emits "<secret-name> <username>". Naming convention, in order of preference:
#   <vserver>            cluster admin password        -> SSH_USER
#   <vserver>-SRE-RW     read-write service account    -> sre-rw
#   <vserver>-SRE-RO     read-only service account     -> sre-ro
#   <vserver>-admin      older naming                  -> SSH_USER
# Suffixes like -OKM-passphrase and ..._svc-backup are never credentials.
# secrets_map.txt wins over all of it ("vserver secret [user]" per line).
lookup_secret_name() {
  local vserver="$1" region="$2" list chosen m_secret m_user

  if [[ -f "$SECRETS_MAP" ]]; then
    read -r m_secret m_user <<< "$(awk -v v="$vserver" '$1==v {print $2, $3; exit}' "$SECRETS_MAP")"
    if [[ -n "$m_secret" ]]; then
      printf '%s %s' "$m_secret" "${m_user:-$SSH_USER}"; return 0
    fi
  fi

  list="$(secret_candidates "$vserver" "$region")" || return 1

  chosen="$(printf '%s\n' "$list" | grep -ix -- "$vserver" | head -n1)"
  [[ -n "$chosen" ]] && { printf '%s %s' "$chosen" "$SSH_USER"; return 0; }

  chosen="$(printf '%s\n' "$list" | grep -iE -- "^${vserver}[-_]SRE[-_]RW$" | head -n1)"
  [[ -n "$chosen" ]] && { printf '%s %s' "$chosen" 'sre-rw'; return 0; }

  # -R0 (zero) shows up in a few names; same account as -RO
  chosen="$(printf '%s\n' "$list" | grep -iE -- "^${vserver}[-_]SRE[-_]R[O0]$" | head -n1)"
  [[ -n "$chosen" ]] && { printf '%s %s' "$chosen" 'sre-ro'; return 0; }

  chosen="$(printf '%s\n' "$list" | grep -iE -- '[-_]admin$' | head -n1)"
  [[ -n "$chosen" ]] && { printf '%s %s' "$chosen" "$SSH_USER"; return 0; }

  return 1
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

# resolve_creds <vserver> <region> [retry]
# Sets CRED_USER / CRED_PW rather than echoing, so the username can come back too.
# Must be called directly (not in a command substitution) or the globals are lost.
# retry=1 skips Secret Manager (its value evidently didn't work) and prompts.
resolve_creds() {
  local vserver="$1" region="${2:-}" retry="${3:-0}"
  local proj; proj="$(project_for "$region")"
  CRED_USER="$SSH_USER"; CRED_PW=""

  # The secret named exactly like the cluster isn't always the account that can
  # log in — some clusters only accept sre-rw. ASK_CREDS=1 skips the lookup so
  # you can type the one you know works.
  [[ "${ASK_CREDS:-0}" == "1" ]] && retry=1

  if [[ -n "${ONTAP_PASSWORD:-}" && "$retry" != "1" ]]; then
    CRED_PW="$ONTAP_PASSWORD"; return 0
  fi

  local pair secret user raw="" pw=""
  if [[ "$retry" != "1" ]] && pair="$(lookup_secret_name "$vserver" "$region")"; then
    read -r secret user <<< "$pair"
    raw="$(gcloud secrets versions access latest --secret="$secret" \
             --project "$proj" </dev/null 2>/dev/null)"
    [[ -n "$raw" ]] && pw="$(extract_password "$raw")"
    if [[ -n "$pw" ]]; then
      CRED_USER="${user:-$SSH_USER}"; CRED_PW="$pw"
      printf '    %-38s <- secret %s (user %s)\n' "$vserver" "$secret" "$CRED_USER" >&2
      return 0
    fi
  fi

  # Prompt, showing where to go find it.
  local u=""
  printf '\n    %s  [%s]\n' "$vserver" "$region" >&2
  if [[ "$retry" == "1" ]]; then
    printf '      previous login failed — re-enter\n' >&2
  fi
  printf '      project : %s\n' "$proj" >&2
  printf '      secrets : https://console.cloud.google.com/security/secret-manager?project=%s\n' "$proj" >&2
  printf '      search  : %s\n' "$vserver" >&2
  printf '      username [%s]: ' "$SSH_USER" >&2
  read -r u </dev/tty
  [[ -n "$u" ]] && CRED_USER="$u"
  printf '      password: ' >&2
  read -rs CRED_PW </dev/tty; printf '\n' >&2

  [[ -z "$CRED_PW" ]] && return 1
  return 0
}

# ------------------------------------------------------------------ capture --

# A capture counts only if ONTAP actually answered about vol0. An ssh error or a
# login banner must not be mistaken for "no alert".
valid_vol0() {
  [[ -s "$1" ]] || return 1
  grep -qw 'vol0' "$1" || grep -qi 'no entries matching\|there are no entries' "$1"
}

# Why a cluster came back unusable, in a few words, from its own output.
vol0_failure_reason() {
  local f="$1"
  [[ -s "$f" ]] || { printf 'no output'; return; }
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
  local region="$1" vslist="$2" retry="${3:-0}" vs ip

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'

  # fd 3 so ssh/gcloud inside the loop can't swallow the cluster list
  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    if [[ -z "$ip" ]]; then
      printf '    !! %s is not in the inventory, skipping\n' "$vs" >&2; continue
    fi
    if ! resolve_creds "$vs" "$region" "$retry"; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2; continue
    fi
    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf 'SSHPASS=%s sshpass -e ssh -n %s %s@%s %s 2>&1\n' \
      "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq "$VOL0_CMD")"
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
  local f="$1" region="$2" cluster="$3"
  awk -v region="$region" -v cluster="$cluster" -v min="$MIN_FREE_GB" '
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
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", region, cluster, node, vol, sz, av, us,
             (gb < 0 ? "" : sprintf("%.2f", gb)), status
    }
    { prev = line }
  ' "$f"
}

# What the run just found on one cluster, so a tight stamp is obvious on the
# console instead of only at the end.
show_cluster() {
  local region="$1" vs="$2" f="$3" node sz av us gb status any=0

  while IFS=, read -r _ _ node _ sz av us gb status; do
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

  local region vs ip f attempt
  while read -r region vs ip <&3; do
    [[ -z "$vs" ]] && continue
    mkdir -p "$VOL0DIR/$region"
    f="$VOL0DIR/$region/$vs.txt"
    rm -f "$f"

    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      if ! resolve_creds "$vs" "$region" "$(( attempt > 1 ? 1 : 0 ))"; then
        printf '    %-38s SKIP (no password)\n' "$vs"; break
      fi
      SSHPASS="$CRED_PW" sshpass -e ssh -n "${SSH_OPTS[@]}" "$CRED_USER@$ip" "$VOL0_CMD" >"$f" 2>&1
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

  printf 'region,cluster,node,volume,size,available,used,available_gb,status\n' >"$csv"
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
      gb = ($8 == "" ? -1 : $8 + 0)
      if (gb >= 0 && (!(k in minv) || gb < minv[k])) { minv[k] = gb; minav[k] = $6 }
    }
    END {
      for (i = 1; i <= o; i++) {
        k = order[i]; split(k, p, "\t")
        state = (alert[k] ? sprintf("ALERT  %d node(s) under %sGB", alert[k], min) \
               : unk[k]   ? "CHECK  available not parsed" : "OK")
        printf "%.2f\t%-8s %-38s %2d node(s)  lowest free %-10s %s\n",
               (k in minv ? minv[k] : 999999), p[1], p[2], nodes[k],
               (k in minav ? minav[k] : "-"), state
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
  -h|--help|help)  usage ;;
  check)           shift; run_check "${@:-all}" ;;   # accepted, but not needed
  "")              run_check all ;;
  *)               run_check "$@" ;;
esac
