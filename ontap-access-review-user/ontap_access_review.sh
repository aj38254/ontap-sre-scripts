#!/usr/bin/env bash
#
# ONTAP quarterly access review helper.
#
# Run this from your ADMIN MACHINE (the box where ./login.sh lives).
# For each region it will:
#     1. call   ./login.sh <region>        -> lands on that region's jumphost
#     2. ssh    admin@<cluster-ip>         -> for every cluster in that region
#     3. run    security login show        -> and pull the output back here
#
#   ./ontap_access_review.sh collect all           # every region, end to end
#   ./ontap_access_review.sh collect na-ne2        # one region
#   ./ontap_access_review.sh collect <vserver>     # one cluster
#   ./ontap_access_review.sh report                # build the user lists
#   ./ontap_access_review.sh list                  # show the inventory
#
# If you are ALREADY sitting on a jumphost (no login.sh present), it skips the
# login.sh hop and ssh's to the clusters directly.
#
# Passwords are resolved per cluster: $ONTAP_PASSWORD -> GCP Secret Manager -> prompt.
# They are never written to disk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${OUTDIR:-$SCRIPT_DIR/output}"
REPORTDIR="${REPORTDIR:-$SCRIPT_DIR/report}"
LOGDIR="${LOGDIR:-$SCRIPT_DIR/logs}"
USERLIST="${USERLIST:-$SCRIPT_DIR/users_to_remove.txt}"
SECRETS_MAP="${SECRETS_MAP:-$SCRIPT_DIR/secrets_map.txt}"
PROJECT_MAP="${PROJECT_MAP:-$SCRIPT_DIR/project_map.txt}"
LOGIN_SH="${LOGIN_SH:-$SCRIPT_DIR/login.sh}"
SSH_USER="${SSH_USER:-admin}"
GCP_PROJECT="${GCP_PROJECT:-}"
INCLUDE_SVM="${INCLUDE_SVM:-0}"
MODE="${MODE:-auto}"          # auto | login | direct
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

# Set by parse_delete_args; empty means "everything".
REGION_FILTER=""
VSERVER_FILTER=""
DELETE_FILE=""

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password"
# shellcheck disable=SC2206
SSH_OPTS=( $SSH_OPTS_STR )

# Clusters whose Secret Manager secret is named nothing like the cluster, so it
# can't be found by searching for the cluster name.
#
#   <cluster-as-in-the-inventory>   <secret-name>   [user]
#
# The user is inferred from the secret name, so the third column is only needed
# to override that. Kept inline so this script is one self-contained file; a
# secrets_map.txt next to it (or SECRETS_MAP=path) is read on top of this list,
# not instead of it. Generate more with `./ontap_access_review.sh secrets`.
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

usage() {
  cat <<'USAGE'
Usage:
  ./ontap_access_review.sh collect all          # every region, via login.sh
  ./ontap_access_review.sh collect <region>     # e.g. na-ne2
  ./ontap_access_review.sh collect <vserver>    # a single cluster
  ./ontap_access_review.sh report               # build the user lists
  ./ontap_access_review.sh secrets [region]     # resolve admin secret names -> secrets_map.txt
  ./ontap_access_review.sh list                 # show the inventory

Removing users (after collect, and after the CR is approved):
  ./ontap_access_review.sh plan   [file] [region|cluster...]  # dry run: exact delete commands, changes nothing
  ./ontap_access_review.sh delete [file] [region|cluster...]  # pre-check -> delete -> post-check, logs to logs/
  ./ontap_access_review.sh removed                            # ONTAP_users_removed.txt + summary for the ticket
  # file defaults to users_to_remove.txt (one ONTAP/TVC account name per line)
  # naming regions or clusters limits the run, to retry only what failed:
  #     ./ontap_access_review.sh delete eu-w3 eu-w6
  #     ./ontap_access_review.sh delete CH-ZRH-CL01-D001C03R0113
  # The first good pre-check per cluster is kept as the audit baseline, so a
  # retry never erases what an earlier run already removed.

Secrets:
  The admin secret is the one named EXACTLY like the vserver (siblings such as
  <vserver>-OKM-passphrase or ..._svc-backup are ignored). Its payload is JSON
  with a "password" key, which is extracted automatically.

  Build a map once, for the clusters that don't follow the convention:
      ./ontap_access_review.sh secrets all > secrets_map.txt
      # fix any lines marked ???, then collect normally

Environment:
  LOGIN_SH=path     path to your login.sh        (default: alongside this script)
  MODE=login|direct force the hop mode           (default: auto-detect)
  ONTAP_PASSWORD    one password for all clusters (skips Secret Manager)
  ASK_CREDS=1       always prompt for user/password (skips Secret Manager)
  GCP_PROJECT       force one project for all Secret Manager lookups
  PROJECT_MAP=file  per-region projects, "region project" (default: netapp-<region>-sde)
  SSH_USER          default cluster user         (default: admin, overridable at the prompt)
  MAX_ATTEMPTS=n    logins to try per cluster    (default: 3)
  USERLIST=file     accounts to delete           (default: users_to_remove.txt)
  ASSUME_YES=1      skip the delete confirmation (for an approved, scripted run)
  INCLUDE_SVM=1     also parse svm_* vservers    (default: cluster vserver only)
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

regions_for() { select_clusters "$1" | awk '{print $1}' | sort -u; }

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

# A secrets_map.txt sitting next to the script adds to the built-in list rather
# than replacing it, and is read first so its lines win. Dropping one new line in
# a file must never silently lose the entries already worked out.
secrets_map_data() {
  { [[ -f "$SECRETS_MAP" ]] && cat "$SECRETS_MAP"
    printf '%s\n' "$SECRETS_BUILTIN"
  } | awk '$1 !~ /^#/ && NF >= 2 && !seen[tolower($1) " " tolower($2)]++'
}

lookup_secret_name() {
  local vserver="$1" region="$2" list chosen m_secret m_user

  read -r m_secret m_user <<< "$(secrets_map_data | awk -v v="$vserver" '$1==v {print $2, $3; exit}')"
  if [[ -n "$m_secret" ]]; then
    printf '%s %s' "$m_secret" "${m_user:-$SSH_USER}"; return 0
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

# ------------------------------------------------------- collect via login.sh --

# No early `exit` in awk: quitting mid-stream closes the pipe under select_clusters
# and every remaining printf there dies with "write error: Broken pipe".
# Matched case-insensitively: the delete path looks clusters up by the name ONTAP
# prints in `Vserver:`, whose case doesn't always match the inventory.
ip_for() {
  select_clusters all \
    | awk -v v="$1" 'BEGIN { v=tolower(v) } tolower($2)==v && !seen { print $3; seen=1 }'
}

# Every vserver in <region> that <target> selects.
clusters_in_region() {
  local region="$1" target="$2" r vs ip
  while read -r r vs ip <&3; do
    [[ "$(lc "$r")" == "$(lc "$region")" ]] || continue
    printf '%s\n' "$vs"
  done 3< <(select_clusters "$target")
}

# Narrows a vserver list to the ones that came back with no usable output.
failed_of() {
  local region="$1" list="$2" vs f
  while read -r vs; do
    [[ -z "$vs" ]] && continue
    f="$OUTDIR/$region/$vs.txt"
    if [[ ! -s "$f" ]] || ! grep -q 'Vserver:' "$f" 2>/dev/null; then
      printf '%s\n' "$vs"
    fi
  done <<< "$list"
}

# Builds the command block typed into the jumphost shell, for the given vservers.
build_remote_block() {
  local region="$1" vslist="$2" retry="${3:-0}" vs ip

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'

  # read on fd 3: anything run inside the loop (gcloud, ssh) would otherwise
  # inherit stdin and swallow the rest of the cluster list.
  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    if ! resolve_creds "$vs" "$region" "$retry"; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2
      continue
    fi
    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf 'SSHPASS=%s sshpass -e ssh %s %s@%s %s 2>&1\n' \
      "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq 'security login show')"
  done 3<<< "$vslist"

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

# Splits one region's captured session log into per-cluster files.
split_session_log() {
  local region="$1" raw="$2"

  if grep -q '===NOSSHPASS===' "$raw" 2>/dev/null; then
    printf '    !! sshpass missing on the %s jumphost -> sudo apt-get install -y sshpass\n' "$region"
    return 1
  fi

  tr -d '\r' <"$raw" | awk -v outdir="$OUTDIR/$region" '
    /^===CLUSTER=== / { vs=$2; file=outdir "/" vs ".txt"; next }
    /^===END===/      { file=""; next }
    file != ""        { print > file }
  '
}

# Per-cluster OK/FAILED for the clusters just attempted.
report_attempt() {
  local region="$1" list="$2" vs f n why
  while read -r vs; do
    [[ -z "$vs" ]] && continue
    f="$OUTDIR/$region/$vs.txt"
    if [[ -s "$f" ]] && grep -q 'Vserver:' "$f" 2>/dev/null; then
      n="$(awk '$2 ~ /^(ssh|ontapi|http|console|service-processor|rest|snmp|telnet)$/ {c++}
                END {print c+0}' "$f")"
      printf '    %-38s OK       %s users\n' "$vs" "$n"
    else
      why='no output'
      if [[ -s "$f" ]]; then
        if   grep -qi 'permission denied\|authentication fail\|access denied' "$f"; then why='bad username/password'
        elif grep -qi 'timed out\|no route to host\|refused\|unreachable'      "$f"; then why='unreachable'
        elif grep -qi 'not authorized\|insufficient privileges'               "$f"; then why='user lacks rights to run the command'
        else why="$(tr -d '\r' <"$f" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-60)"
        fi
      fi
      printf '    %-38s FAILED   %s\n' "$vs" "$why"
    fi
  done <<< "$list"
}

collect_via_login() {
  local target="$1"
  [[ -x "$LOGIN_SH" ]] || die "login.sh not found/executable at $LOGIN_SH  (set LOGIN_SH=/path/to/login.sh)"

  local region block raw pending targets vs attempt retry
  for region in $(regions_for "$target"); do
    printf '\n==> %s : %s %s\n' "$region" "$LOGIN_SH" "$region"
    mkdir -p "$OUTDIR/$region"

    targets="$(clusters_in_region "$region" "$target")"
    [[ -z "$targets" ]] && { printf '    nothing to do\n'; continue; }

    # Always a fresh pull: clear prior output so a re-run is real evidence and
    # not a mix of this quarter's and last run's files.
    while read -r vs; do
      [[ -n "$vs" ]] && rm -f "$OUTDIR/$region/$vs.txt"
    done <<< "$targets"

    attempt=1
    pending="$targets"

    # A bad password only fails once we're inside the jumphost session, so retry
    # the clusters that came back empty (re-prompting) up to MAX_ATTEMPTS times.
    while [[ -n "$pending" && $attempt -le $MAX_ATTEMPTS ]]; do
      retry=0
      if [[ $attempt -gt 1 ]]; then
        retry=1
        printf '    attempt %d/%d for: %s\n' "$attempt" "$MAX_ATTEMPTS" \
          "$(printf '%s' "$pending" | tr '\n' ' ')"
      fi

      # built first (so password prompts happen before login.sh takes the terminal)
      block="$(build_remote_block "$region" "$pending" "$retry")"
      # nothing resolved a password -> don't bother opening a session
      grep -q '===CLUSTER===' <<< "$block" || break

      raw="$OUTDIR/$region/_session_$attempt.log"
      printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
      split_session_log "$region" "$raw" || break
      report_attempt "$region" "$pending"

      pending="$(failed_of "$region" "$pending")"
      attempt=$((attempt+1))
    done

    if [[ -n "$pending" ]]; then
      printf '    !! no output after %d attempt(s): %s\n' "$MAX_ATTEMPTS" \
        "$(printf '%s' "$pending" | tr '\n' ' ')"
    fi
  done
}

# ------------------------------------------- collect directly (on a jumphost) --

collect_direct() {
  local target="$1"
  command -v sshpass >/dev/null 2>&1 || die "sshpass not installed. Try: sudo apt-get install -y sshpass"

  local ok=0 fail=0 region vserver ip out attempt retry got
  while read -r region vserver ip <&3; do
    mkdir -p "$OUTDIR/$region"
    out="$OUTDIR/$region/${vserver}.txt"
    printf '==> %-8s %-38s %-14s ' "$region" "$vserver" "$ip"

    # Here the login result is immediate, so bad credentials are re-prompted
    # on the spot instead of after the fact.
    attempt=1; got=0
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
      retry=0; [[ $attempt -gt 1 ]] && retry=1
      resolve_creds "$vserver" "$region" "$retry" || break
      if SSHPASS="$CRED_PW" sshpass -e ssh "${SSH_OPTS[@]}" "$CRED_USER@$ip" \
           "security login show" >"$out" 2>"$out.err" </dev/null \
         && grep -q 'Vserver:' "$out"; then
        got=1; break
      fi
      attempt=$((attempt+1))
    done

    if [[ $got -eq 1 ]]; then
      printf 'OK\n'; rm -f "$out.err"; ok=$((ok+1))
    else
      printf 'FAILED (see %s)\n' "$out.err"; fail=$((fail+1))
    fi
  done 3< <(select_clusters "$target")

  printf '\nCollected: %d OK, %d failed\n' "$ok" "$fail"
}

collect() {
  local target="${1:-}"
  [[ -z "$target" ]] && { usage; exit 1; }
  [[ -z "$(select_clusters "$target")" ]] && die "no clusters match '$target' (try: list)"

  local mode="$MODE"
  if [[ "$mode" == "auto" ]]; then
    if [[ -x "$LOGIN_SH" ]]; then mode="login"; else mode="direct"; fi
  fi

  case "$mode" in
    login)  printf 'Mode: via %s (admin machine)\n' "$LOGIN_SH"; collect_via_login "$target" ;;
    direct) printf 'Mode: direct ssh (already on a jumphost)\n';  collect_direct "$target"   ;;
    *)      die "unknown MODE=$mode" ;;
  esac

  printf '\nRaw output: %s\nNext: ./ontap_access_review.sh report\n' "$OUTDIR"
}

# ------------------------------------------------------------------- delete --

region_selected() {
  [[ -z "$REGION_FILTER" ]] && return 0
  [[ ",$REGION_FILTER," == *",$1,"* ]]
}

# `plan` and `delete` take an optional user-list file and any number of region
# OR cluster names, in any order, so the tail end of a partly-failed run can be
# retried without re-touching the clusters that already succeeded.
parse_delete_args() {
  local a
  DELETE_FILE="$USERLIST"
  REGION_FILTER=""
  VSERVER_FILTER=""
  for a in "$@"; do
    [[ -z "$a" ]] && continue
    if [[ -f "$a" ]]; then
      DELETE_FILE="$a"
    elif grep -q "^$a[[:space:]]" <<< "$INVENTORY"; then
      REGION_FILTER="${REGION_FILTER:+$REGION_FILTER,}$a"
    elif [[ -n "$(ip_for "$a")" ]]; then
      VSERVER_FILTER="${VSERVER_FILTER:+$VSERVER_FILTER,}$(lc "$a")"
    else
      die "not a region, not a cluster in the inventory, not a readable file: $a"
    fi
  done
}

# One account name per line; "#" starts a comment.
load_users() {
  local file="$1"
  [[ -f "$file" ]] || die "user list not found: $file"
  sed 's/#.*//' "$file" | awk 'NF {print $1}' | sort -u
}

# Deletes are derived from what `collect` actually saw, never guessed, so the
# application/auth-method pair on every command is known to exist.
# Emits: region vserver user application auth-method role
#
# Deduplicated because rows are keyed on the vserver ONTAP reports, not the file
# name: if a cluster was ever collected under two different inventory names, both
# files describe the same cluster and every row would otherwise be counted twice.
deletion_targets() {
  local ulist="$1" f region vserver
  while IFS= read -r f <&3; do
    region="$(basename "$(dirname "$f")")"
    region_selected "$region" || continue
    vserver="$(basename "$f" .txt)"
    awk -v region="$region" -v vserver="$vserver" -v ulist="$ulist" -v vfilter="$VSERVER_FILTER" '
      BEGIN { n=split(ulist, a, ","); for (i=1; i<=n; i++) want[a[i]]=1
              nf=split(vfilter, b, ","); for (i=1; i<=nf; i++) keep[b[i]]=1 }
      /^Vserver:/              { vs=$2; indata=0; next }
      /^-{5,}/                 { indata=1; next }
      /^[[:space:]]*$/         { indata=0; next }
      /entries were displayed/ { indata=0; next }
      indata && NF>=4 && ($1 in want) {
        name = (vs == "" ? vserver : vs)
        if (nf > 0 && !(tolower(name) in keep)) next
        print region, name, $1, $2, $3, $4
      }
    ' "$f"
  done 3< <(find "$OUTDIR" -type f -name '*.txt' | sort) | sort -u
}

# ONTAP takes several commands in one ssh invocation separated by ";".
#   set d    diagnostic privilege — plain admin can't delete every login
#   row 0    no pagination, so long output isn't truncated
ONTAP_PREFIX='set d; row 0;'

# Scoping the show to -vserver keeps data SVMs (and their vsadmin rows) out.
show_cmd_for() { printf '%s security login show -vserver %s' "$ONTAP_PREFIX" "$1"; }

# One command per user, with wildcards, rather than one per application row:
# ONTAP removes every application/auth-method for that user in a single call.
delete_commands_for() {
  local ulist="$1" vs="$2"
  deletion_targets "$ulist" | awk -v v="$vs" -v p="$ONTAP_PREFIX" '$2 == v && !seen[$3]++ {
    printf "%s security login delete -user-or-group-name %s -vserver %s -authentication-method * -application *\n", p, $3, v
  }'
}

# How many account rows should disappear on this cluster if the deletes work.
expected_entries_for() {
  local ulist="$1" vs="$2"
  deletion_targets "$ulist" | awk -v v="$vs" '$2 == v' | wc -l | tr -d ' '
}

# Dry run: the exact commands, for the CR ticket. Touches nothing.
delete_plan() {
  local file="${DELETE_FILE:-$USERLIST}"
  [[ -d "$OUTDIR" ]] || die "no collected output — run 'collect all' first"

  local users ulist
  users="$(load_users "$file")"
  ulist="$(printf '%s' "$users" | paste -sd, -)"

  mkdir -p "$REPORTDIR"
  local plan="$REPORTDIR/delete_plan.txt"
  : >"$plan"

  local region vserver last=''
  while read -r region vserver <&3; do
    printf '\n# %s  (%s)  — %s account row(s)\n' \
      "$vserver" "$region" "$(expected_entries_for "$ulist" "$vserver")" >>"$plan"
    delete_commands_for "$ulist" "$vserver" >>"$plan"
    printf '%s\n' "$(show_cmd_for "$vserver")" >>"$plan"
  done 3< <(deletion_targets "$ulist" | awk '{print $1, $2}' | sort -u -k2,2)

  local cmds entries clusters
  cmds="$(grep -c 'security login delete' "$plan" || true)"
  entries="$(deletion_targets "$ulist" | wc -l | tr -d ' ')"
  clusters="$(deletion_targets "$ulist" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"

  printf '%s user(s): %s delete command(s) clearing %s account row(s) across %s cluster(s)\n' \
    "$(printf '%s\n' "$users" | wc -l | tr -d ' ')" "$cmds" "$entries" "$clusters"
  printf 'Plan: %s\n' "$plan"

  printf '\nPer user:\n'
  deletion_targets "$ulist" \
    | awk '{ e[$3]++; if (!(($3 SUBSEP $2) in s)) { s[$3 SUBSEP $2]=1; c[$3]++ } }
            END { for (u in e) printf "  %-14s %2d cluster(s), %2d entries\n", u, c[u], e[u] }' \
    | sort -k2 -nr
}

# A capture is only usable as evidence if it is an actual `security login show`
# table rather than a login error that ssh handed back on stdout.
valid_capture() { [[ -s "$1" ]] && grep -q 'Vserver:' "$1"; }

# The pre-check is the audit baseline, so the FIRST valid one for a cluster is
# kept forever. Re-running a region to fix a few clusters would otherwise
# re-baseline the ones that already succeeded, and their removals would vanish
# from the `removed` report.
store_baseline() {
  local vs="$1" capture="$2"
  valid_capture "$LOGDIR/PRE_CHECK_$vs.txt" && return 0
  cp "$capture" "$LOGDIR/PRE_CHECK_$vs.txt"
}

# Splits a delete session into PRE_CHECK/DELETE/POST_CHECK per cluster.
# Parses into a staging area first: nothing in $LOGDIR is touched for a cluster
# this run failed to reach, so leftovers from an earlier run can never be
# mistaken for a result. Writes the clusters that did come back to $fresh.
split_delete_log() {
  local raw="$1" fresh="$2"

  if grep -q '===NOSSHPASS===' "$raw" 2>/dev/null; then
    printf '    !! sshpass missing on this jumphost -> sudo apt-get install -y sshpass\n'
    return 1
  fi

  mkdir -p "$LOGDIR"
  local stage; stage="$(mktemp -d)"
  : >"$fresh"

  tr -d '\r' <"$raw" | awk -v logdir="$stage" '
    /^===CLUSTER=== /  { vs=$2; file=""; print vs > (logdir "/.seen"); next }
    /^===PRECHECK===/  { file=logdir "/PRE_CHECK_"  vs ".txt"; next }
    /^===DELETE===/    { file=logdir "/DELETE_"     vs ".txt"; next }
    /^===POSTCHECK===/ { file=logdir "/POST_CHECK_" vs ".txt"; next }
    /^===END===/       { file=""; next }
    file != ""         { print > file }
  '

  local vs
  while read -r vs; do
    [[ -z "$vs" ]] && continue
    if valid_capture "$stage/PRE_CHECK_$vs.txt" && valid_capture "$stage/POST_CHECK_$vs.txt"; then
      store_baseline "$vs" "$stage/PRE_CHECK_$vs.txt"
      cp "$stage/POST_CHECK_$vs.txt" "$LOGDIR/POST_CHECK_$vs.txt"
      cat "$stage/DELETE_$vs.txt" >>"$LOGDIR/DELETE_$vs.txt" 2>/dev/null
      printf '%s\n' "$vs" >>"$fresh"
    else
      # Under a name the reporter ignores, so there is still something to read
      # when diagnosing why the cluster didn't come back.
      cat "$stage/PRE_CHECK_$vs.txt" "$stage/DELETE_$vs.txt" "$stage/POST_CHECK_$vs.txt" \
        >"$LOGDIR/FAILED_$vs.txt" 2>/dev/null
    fi
  done < <(sort -u "$stage/.seen" 2>/dev/null)

  rm -rf "$stage"
}

# pre-check -> deletes -> post-check, in one ssh session per cluster.
build_delete_block() {
  local region="$1" vslist="$2" ulist="$3" retry="${4:-0}" vs ip

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'

  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    # Clusters are looked up by the name in the collected output, so an inventory
    # rename that isn't matched by a re-collect would otherwise ssh to nothing.
    if [[ -z "$ip" ]]; then
      printf '    !! %s is not in the inventory — fix the name or re-collect, skipping\n' "$vs" >&2
      continue
    fi
    if ! resolve_creds "$vs" "$region" "$retry"; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2
      continue
    fi

    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf 'echo "===PRECHECK==="\n'
    printf 'SSHPASS=%s sshpass -e ssh -n %s %s@%s %s 2>&1\n' \
      "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq "$(show_cmd_for "$vs")")"

    # -n matters here: without it ssh inherits this generated script as stdin
    # and eats the commands that follow.
    printf 'echo "===DELETE==="\n'
    local cmd
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      printf 'echo %s\n' "$(shq "+ $cmd")"
      printf 'SSHPASS=%s sshpass -e ssh -n %s %s@%s %s 2>&1\n' \
        "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq "$cmd")"
    done < <(delete_commands_for "$ulist" "$vs")

    printf 'echo "===POSTCHECK==="\n'
    printf 'SSHPASS=%s sshpass -e ssh -n %s %s@%s %s 2>&1\n' \
      "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq "$(show_cmd_for "$vs")")"
  done 3<<< "$vslist"

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

# Did the deletes actually land? Compares the two captures rather than trusting
# that a post-check came back at all.
report_cluster_removal() {
  local vs="$1" ulist="$2" session="${3:-}" fresh="${4:-}"
  local pre="$LOGDIR/PRE_CHECK_$vs.txt" post="$LOGDIR/POST_CHECK_$vs.txt"
  local expected gone

  expected="$(expected_entries_for "$ulist" "$vs")"

  # Without this a cluster the run never reached would be "reported" off the
  # previous run's files, which reads as NOTHING REMOVED and hides the real
  # problem — the login failed.
  if [[ -n "$fresh" ]] && ! grep -qxF "$vs" "$fresh" 2>/dev/null; then
    printf '    %-38s NO CAPTURE THIS RUN (expected %s) — see %s\n' \
      "$vs" "$expected" "${session:-$LOGDIR/FAILED_$vs.txt}"
    return
  fi

  if ! valid_capture "$pre"; then
    printf '    %-38s NO PRE-CHECK    %s\n' "$vs" "$session"; return
  fi
  if ! valid_capture "$post"; then
    printf '    %-38s NO POST-CHECK   %s\n' "$vs" "$session"; return
  fi

  gone="$(comm -23 <(login_entries "$pre" "$vs") <(login_entries "$post" "$vs") | grep -c . || true)"

  if [[ "$gone" -eq "$expected" ]]; then
    printf '    %-38s removed %s/%s\n' "$vs" "$gone" "$expected"
  elif [[ "$gone" -eq 0 ]]; then
    printf '    %-38s NOTHING REMOVED (expected %s) — see %s\n' \
      "$vs" "$expected" "$LOGDIR/DELETE_$vs.txt"
  else
    printf '    %-38s removed %s/%s — PARTIAL, see %s\n' \
      "$vs" "$gone" "$expected" "$LOGDIR/DELETE_$vs.txt"
  fi
}

delete_via_login() {
  local ulist="$1"
  [[ -x "$LOGIN_SH" ]] || die "login.sh not found/executable at $LOGIN_SH"

  local region targets pending block raw fresh acc vs attempt n
  for region in $(deletion_targets "$ulist" | awk '{print $1}' | sort -u); do
    targets="$(deletion_targets "$ulist" | awk -v r="$region" '$1==r {print $2}' | sort -u)"
    printf '\n==> %s : %s %s\n' "$region" "$LOGIN_SH" "$region"

    mkdir -p "$LOGDIR"
    acc="$LOGDIR/.fresh_$region"; : >"$acc"
    pending="$targets"
    raw="$LOGDIR/_delete_session_$region.log"

    # A cluster that returns nothing is usually the wrong account rather than an
    # unreachable host — the secret named after the cluster isn't always the one
    # that can log in. Retrying asks for credentials instead of re-reading the
    # secret that just failed.
    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      [[ -z "$pending" ]] && break
      n="$(grep -c . <<< "$pending")"
      if (( attempt > 1 )); then
        raw="$LOGDIR/_delete_session_${region}_try$attempt.log"
        printf '\n    %s cluster(s) returned nothing — attempt %s of %s, enter credentials\n' \
          "$n" "$attempt" "$MAX_ATTEMPTS"
      fi
      fresh="$LOGDIR/.fresh_${region}_try$attempt"

      block="$(build_delete_block "$region" "$pending" "$ulist" "$(( attempt > 1 ? 1 : 0 ))")"
      grep -q '===CLUSTER===' <<< "$block" || { printf '    skipped (no credentials)\n'; break; }

      printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
      split_delete_log "$raw" "$fresh" || break
      cat "$fresh" >>"$acc"

      pending="$(comm -23 <(printf '%s\n' "$pending" | sort -u) <(sort -u "$acc") | grep . || true)"
    done

    # One clear line beats N identical per-cluster failures when the jumphost
    # hop itself is what went wrong.
    if [[ ! -s "$acc" ]]; then
      printf '    !! no cluster returned output — the %s session failed, see %s\n' "$region" "$raw"
      continue
    fi

    while read -r vs; do
      [[ -z "$vs" ]] && continue
      report_cluster_removal "$vs" "$ulist" "$raw" "$acc"
    done <<< "$targets"
  done
}

delete_direct() {
  local ulist="$1"
  command -v sshpass >/dev/null 2>&1 || die "sshpass not installed. Try: sudo apt-get install -y sshpass"
  mkdir -p "$LOGDIR"

  local region vserver ip cmd pre post
  pre="$(mktemp)"; post="$(mktemp)"
  trap 'rm -f "$pre" "$post"' RETURN

  while read -r region vserver <&3; do
    ip="$(ip_for "$vserver")"
    printf '==> %-8s %-38s ' "$region" "$vserver"
    [[ -z "$ip" ]] && { printf 'SKIP (not in inventory)\n'; continue; }
    if ! resolve_creds "$vserver" "$region" 0; then printf 'SKIP (no password)\n'; continue; fi

    SSHPASS="$CRED_PW" sshpass -e ssh -n "${SSH_OPTS[@]}" "$CRED_USER@$ip" \
      "$(show_cmd_for "$vserver")" >"$pre" 2>&1
    if ! valid_capture "$pre"; then
      cp "$pre" "$LOGDIR/FAILED_$vserver.txt"
      printf 'LOGIN FAILED — see %s\n' "$LOGDIR/FAILED_$vserver.txt"; continue
    fi
    store_baseline "$vserver" "$pre"

    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      printf '+ %s\n' "$cmd" >>"$LOGDIR/DELETE_$vserver.txt"
      SSHPASS="$CRED_PW" sshpass -e ssh -n "${SSH_OPTS[@]}" "$CRED_USER@$ip" \
        "$cmd" >>"$LOGDIR/DELETE_$vserver.txt" 2>&1
    done < <(delete_commands_for "$ulist" "$vserver")

    SSHPASS="$CRED_PW" sshpass -e ssh -n "${SSH_OPTS[@]}" "$CRED_USER@$ip" \
      "$(show_cmd_for "$vserver")" >"$post" 2>&1
    if ! valid_capture "$post"; then
      cp "$post" "$LOGDIR/FAILED_$vserver.txt"
      printf 'NO POST-CHECK — see %s\n' "$LOGDIR/FAILED_$vserver.txt"; continue
    fi
    cp "$post" "$LOGDIR/POST_CHECK_$vserver.txt"

    printf '\n'
    report_cluster_removal "$vserver" "$ulist"
  done 3< <(deletion_targets "$ulist" | awk '{print $1, $2}' | sort -u)
}

delete_users() {
  local file="${DELETE_FILE:-$USERLIST}"
  [[ -d "$OUTDIR" ]] || die "no collected output — run 'collect all' first"

  local users ulist entries clusters
  users="$(load_users "$file")"
  ulist="$(printf '%s' "$users" | paste -sd, -)"
  entries="$(deletion_targets "$ulist" | wc -l | tr -d ' ')"
  clusters="$(deletion_targets "$ulist" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"

  local scope=""
  [[ -n "$REGION_FILTER"  ]] && scope=" in region(s) $REGION_FILTER"
  [[ -n "$VSERVER_FILTER" ]] && scope="$scope limited to $VSERVER_FILTER"

  [[ "$entries" -eq 0 ]] && die "nothing to delete — no collected entry matches $file$scope"

  printf 'About to delete %s account entries for %s user(s) across %s cluster(s)%s.\n' \
    "$entries" "$(printf '%s\n' "$users" | wc -l | tr -d ' ')" "$clusters" "$scope"
  printf 'Logs -> %s\n' "$LOGDIR"
  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    printf 'Type DELETE to continue: '
    local answer; read -r answer </dev/tty
    [[ "$answer" == "DELETE" ]] || die "aborted"
  fi

  local mode="$MODE"
  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }

  case "$mode" in
    login)  delete_via_login  "$ulist" ;;
    direct) delete_direct     "$ulist" ;;
    *)      die "unknown MODE=$mode" ;;
  esac

  printf '\nNext: ./ontap_access_review.sh removed      # build the removed-users summary\n'
}

# ------------------------------------------------------- removed-users report --

# "user application auth role" for one cluster's rows in a security login show
# capture. Restricted to <vserver>'s own block, because a capture taken before
# the show was scoped with -vserver also lists the data SVMs. Diffing such a
# baseline against a scoped post-check would report every data-SVM account —
# vsadmin above all — as removed when nothing touched it.
login_entries() {
  local file="$1" want="${2:-}"
  awk -v want="$want" '
    BEGIN                    { want=tolower(want) }
    /^Vserver:/              { vs=tolower($2); indata=0; next }
    /^-{5,}/                 { indata=1; next }
    /^[[:space:]]*$/         { indata=0; next }
    /entries were displayed/ { indata=0; next }
    indata && NF>=4 && (want=="" || vs=="" || vs==want) { print $1, $2, $3, $4 }
  ' "$file" | sort -u
}

build_removed() {
  [[ -d "$LOGDIR" ]] || die "no logs directory — run 'delete' first"
  mkdir -p "$REPORTDIR"

  local out="$REPORTDIR/ONTAP_users_removed.txt"
  local sum="$REPORTDIR/removal_summary.txt"
  local tmp skipped; tmp="$(mktemp)"; skipped="$(mktemp)"
  local pairs=0 zero=0 pre post vs n

  : >"$out"
  for pre in "$LOGDIR"/PRE_CHECK_*.txt; do
    [[ -e "$pre" ]] || continue
    vs="$(basename "$pre" .txt)"; vs="${vs#PRE_CHECK_}"
    post="$LOGDIR/POST_CHECK_$vs.txt"
    # A capture that isn't a real `security login show` would otherwise be
    # compared as "empty", i.e. counted as a clean pair with nothing removed.
    if ! valid_capture "$pre" || ! valid_capture "$post"; then
      printf 'WARNING: %s has no usable pre/post pair — NOT counted\n' "$vs" >&2
      printf '%s\n' "$vs" >>"$skipped"
      continue
    fi
    pairs=$((pairs+1))

    n="$(comm -23 <(login_entries "$pre" "$vs") <(login_entries "$post" "$vs") \
           | awk -v v="$vs" 'NF {print v, $1, $2, $3, $4}' | tee -a "$tmp" | grep -c . )"
    [[ "$n" -eq 0 ]] && zero=$((zero+1))
  done

  sort -k1,1 -k2,2 "$tmp" | awk '{printf "%-38s %-14s %-18s %-10s %s\n", $1, $2, $3, $4, $5}' >"$out"

  local total users
  total="$(wc -l <"$tmp" | tr -d ' ')"
  users="$(awk '{print $2}' "$tmp" | sort -u | wc -l | tr -d ' ')"

  {
    printf 'Summary\n\n'
    printf '%-28s %s\n' 'Metric' 'Count'
    printf '%-28s %s\n' 'File pairs compared' "$pairs"
    printf '%-28s %s\n' 'Total removed-user entries' "$total"
    printf '%-28s %s\n' 'Unique users removed' "$users"
    printf '%-28s %s\n' 'Clusters with zero removals' "$zero"
    printf '%-28s %s\n' 'Clusters with no capture' "$(grep -c . "$skipped" || true)"

    # An access review is only evidence if the gaps are on the page too.
    if [[ -s "$skipped" ]]; then
      printf '\nNot verified — no usable pre/post capture, re-run these:\n\n'
      sed 's/^/  /' "$skipped"
    fi
    printf '\nUsers removed (by frequency across systems):\n\n'
    printf '%-60s %s\n' 'User' 'Systems'
    # group users that appear on the same number of systems, like the ticket format
    awk '{ if (!((($2) SUBSEP $1) in seen)) { seen[$2 SUBSEP $1]=1; n[$2]++ } }
         END { for (u in n) print n[u], u }' "$tmp" \
      | sort -k1,1nr -k2,2 \
      | awk '{ if ($1 != last) { if (last != "") printf "%-60s %s\n", names, (cnt>1 ? last " each" : last);
                                 names=$2; last=$1; cnt=1 }
               else { names = names ", " $2; cnt++ } }
             END { if (last != "") printf "%-60s %s\n", names, (cnt>1 ? last " each" : last) }'
  } >"$sum"

  rm -f "$tmp" "$skipped"
  cat "$sum"
  printf '\n  %s\n  %s\n' "$out" "$sum"
}

# ------------------------------------------------------------------- report --

report() {
  [[ -d "$OUTDIR" ]] || die "no output directory yet — run 'collect' first"
  mkdir -p "$REPORTDIR"

  local csv="$REPORTDIR/users_by_cluster.csv"
  printf 'Vserver,User/Group Name,Application,Authentication Method,Role Name,Acct Locked,Second Authentication Method\n' >"$csv"

  local files
  files="$(find "$OUTDIR" -type f -name '*.txt' | wc -l | tr -d ' ')"

  local f region vserver
  while IFS= read -r f <&3; do
    region="$(basename "$(dirname "$f")")"
    vserver="$(basename "$f" .txt)"
    awk -v vserver="$vserver" -v include_svm="$INCLUDE_SVM" '
      /^Vserver:/              { vs=$2; skip=(include_svm=="1" ? 0 : (vs ~ /^svm_/)); indata=0; next }
      /^-{5,}/                 { indata=1; next }
      /^[[:space:]]*$/         { indata=0; next }
      /entries were displayed/ { indata=0; next }
      indata && !skip && NF>=4 {
        name = (vs == "" ? vserver : vs)
        locked = (NF >= 5 ? $5 : "-")
        second = (NF >= 6 ? $6 : "-")
        print name "," $1 "," $2 "," $3 "," $4 "," locked "," second
      }
    ' "$f"
  done 3< <(find "$OUTDIR" -type f -name '*.txt' | sort) | sort -u >>"$csv"

  # CSV columns: 1=Vserver 2=User 3=Application 4=AuthMethod 5=Role 6=Locked 7=SecondAuth
  tail -n +2 "$csv" | cut -d, -f2 | sort -u >"$REPORTDIR/unique_users.txt"

  tail -n +2 "$csv" \
    | awk -F, '!seen[$2 SUBSEP $1]++ { n[$2]++ } END { for (u in n) printf "%-24s %d\n", u, n[u] }' \
    | sort -k2 -nr >"$REPORTDIR/user_cluster_counts.txt"

  tail -n +2 "$csv" \
    | awk -F, '$5 ~ /^(admin|admin-no-fsa|super-users|sre-admins|vsadmin)$/ { print $2 }' \
    | sort -u >"$REPORTDIR/privileged_users.txt"

  printf 'Parsed %s cluster file(s).\n\n' "$files"
  printf '  %-42s %s\n' \
    "$REPORTDIR/unique_users.txt"        "$(wc -l <"$REPORTDIR/unique_users.txt" | tr -d ' ') unique users  <- email this for confirmation" \
    "$REPORTDIR/privileged_users.txt"    "$(wc -l <"$REPORTDIR/privileged_users.txt" | tr -d ' ') privileged users" \
    "$REPORTDIR/users_by_cluster.csv"    "$(( $(wc -l <"$csv" | tr -d ' ') - 1 )) rows: Vserver,User,Application,AuthMethod,Role,Locked,SecondAuth" \
    "$REPORTDIR/user_cluster_counts.txt" "user -> how many clusters"
}

# Resolve the admin secret for every cluster and emit a secrets_map.txt template.
# Clusters that don't follow the naming convention are flagged with ??? plus the
# candidates found, so you only hand-search the ones that actually need it.
discover_secrets() {
  local target="${1:-all}"
  local region vserver ip list chosen unresolved=0

  printf '# vserver                              secret-name                             user\n'
  printf '# review, fix any ???, then save as %s\n' "$SECRETS_MAP"

  while read -r region vserver ip <&3; do
    list="$(secret_candidates "$vserver" "$region")"
    chosen="$(lookup_secret_name "$vserver" "$region")"

    if [[ -n "$chosen" ]]; then
      # chosen is "<secret> <user>"
      printf '%-38s %-38s %s\n' "$vserver" "${chosen%% *}" "${chosen##* }"
    else
      unresolved=$((unresolved+1))
      printf '%-38s ???    # project=%s candidates: %s\n' \
        "$vserver" "$(project_for "$region")" \
        "$(printf '%s' "$list" | tr '\n' ' ' | sed 's/  */ /g')"
    fi
  done 3< <(select_clusters "$target")

  ((unresolved)) && printf '\n# %d cluster(s) need a manual secret name (marked ???)\n' "$unresolved" >&2
  return 0
}

list_inventory() {
  printf '%-8s %-38s %s\n' "REGION" "VSERVER" "IP"
  select_clusters all | while read -r region vserver ip; do
    printf '%-8s %-38s %s\n' "$region" "$vserver" "$ip"
  done

  printf '\n%-8s %s\n' "REGION" "SECRET MANAGER PROJECT"
  local r
  for r in $(regions_for all); do
    printf '%-8s %s\n' "$r" "$(project_for "$r")"
  done

  printf '\n%s clusters across %s regions\n' \
    "$(select_clusters all | wc -l | tr -d ' ')" "$(regions_for all | wc -l | tr -d ' ')"
}

# Lets a sibling script reuse the inventory, credential and login.sh plumbing:
#   ONTAP_LIB_ONLY=1 source ontap_access_review.sh
[[ "${ONTAP_LIB_ONLY:-0}" == "1" ]] && return 0

case "${1:-}" in
  collect) shift; collect "${1:-}" ;;
  report)  report ;;
  plan)    shift; parse_delete_args "$@"; delete_plan ;;
  delete)  shift; parse_delete_args "$@"; delete_users ;;
  removed) build_removed ;;
  secrets) shift; discover_secrets "${1:-all}" ;;
  list)    list_inventory ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 1 ;;
esac
