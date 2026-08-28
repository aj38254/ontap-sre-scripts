#!/usr/bin/env bash
#
# Config-backup cleanup across the ONTAP production fleet.
#
# ONTAP keeps writing system configuration backups and never ages them out, so
# they pile up until the node runs out of room. Until the ONTAP team ships a
# real retention setting, this walks the fleet and removes the ones older than
# 30 days.
#
# Self-contained: no other script, file or map is required. Run it from your
# ADMIN MACHINE (the box where login.sh lives) and for each region it will:
#     1. call   ./login.sh <region>                    -> that region's jumphost
#     2. ssh    <user>@<cluster-ip>                    -> every cluster in region
#     3. run    system node show                       -> discover the nodes
#     4. run    system configuration backup show -node -> once per node
#
#   ./ontap_backup_cleanup.sh                # eu-w6, collect + plan  <- start here
#   ./ontap_backup_cleanup.sh eu-w6          # a named region
#   ./ontap_backup_cleanup.sh all            # the whole fleet
#   ./ontap_backup_cleanup.sh plan           # re-plan from saved captures, no logins
#   ./ontap_backup_cleanup.sh delete         # DRY RUN: prints the commands only
#   ./ontap_backup_cleanup.sh delete --execute --limit 2    # actually delete two
#
# NOTHING IS DELETED unless --execute is passed. `delete` on its own is a dry
# run that prints the exact ONTAP commands, which is the artefact to hand round
# for review.
#
# Passwords are resolved per cluster: $ONTAP_PASSWORD -> GCP Secret Manager ->
# prompt. They are never written to disk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPDIR="${BACKUPDIR:-$SCRIPT_DIR/backups}"
REPORTDIR="${REPORTDIR:-$SCRIPT_DIR/report}"
LOGDIR="${LOGDIR:-$SCRIPT_DIR/logs}"
LOGIN_SH="${LOGIN_SH:-$SCRIPT_DIR/login.sh}"
SECRETS_MAP="${SECRETS_MAP:-$SCRIPT_DIR/secrets_map.txt}"
PROJECT_MAP="${PROJECT_MAP:-$SCRIPT_DIR/project_map.txt}"
SSH_USER="${SSH_USER:-admin}"
GCP_PROJECT="${GCP_PROJECT:-}"
MODE="${MODE:-auto}"              # auto | login | direct
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
MAX_SECRETS="${MAX_SECRETS:-4}"   # credentials tried per cluster before asking

# Retention. A backup is deleted only when it is STRICTLY older than this many
# days, so a backup dated exactly 30 days ago is kept — "older than 30 days"
# should never be read as "including the boundary" by a script that deletes.
RETAIN_DAYS="${RETAIN_DAYS:-30}"

# Floor guard, applied per node AFTER the age rule: the newest MIN_KEEP backups
# are never deleted, whatever their age. If a node's backup job has been dead
# for a month, every backup it has is "old" — without this the cleanup would
# take the last good config backup with it.
MIN_KEEP="${MIN_KEEP:-5}"

# Deletes chained into one ssh. Attribution comes from the post-check diff, not
# from ONTAP's own output, so batching costs nothing in traceability.
DELETE_BATCH="${DELETE_BATCH:-20}"

# No argument means this region, not the whole fleet. Rolling out one region at
# a time is the plan, and a bare run should follow the plan.
DEFAULT_REGION="${DEFAULT_REGION:-eu-w6}"

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password"
# shellcheck disable=SC2206
SSH_OPTS=( $SSH_OPTS_STR )

# `set d` raises privilege (system configuration backup is not recognised at the
# default level) and `row 0` stops output being truncated at one screen.
#
# Use the short forms. `set d` prompts "Do you want to continue? {y|n}" when you
# type it at a terminal, which makes `set -confirmations off; set -privilege
# diagnostic` look like the safer spelling — it is not. ONTAP does not prompt
# when it runs a command passed on the ssh line, and this exact prefix is what
# ontap_vol0_check.sh sends through the same jumphosts today. The long spelling
# was unverified against these clusters and bought nothing.
ONTAP_PREFIX='set d; row 0;'

# One command, every node. The node is the table's first column, so there is
# nothing to gain from discovering the node names first and asking once per node
# — that was two ssh logins per cluster and two more things to go wrong.
BACKUP_CMD="$ONTAP_PREFIX system configuration backup show"

# Cheapest thing that proves a login works and the privilege change took.
PROBE_CMD="$ONTAP_PREFIX version"

DELETE_PREFIX="$ONTAP_PREFIX"

# What a bare `delete --execute` is capped at. Small on purpose: the agreed
# rollout is one or two backups first, and a default of "all of them" is one
# forgotten flag away from a very long afternoon.
DELETE_LIMIT_DEFAULT="${DELETE_LIMIT_DEFAULT:-2}"

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
# A line resolving to sre-ro is dropped: that account cannot delete, so pointing
# this script at it would be a wasted login. Map such a cluster to its -SRE-RW
# secret, or give a working account at the prompt.
#
# Kept inline so this script is one self-contained file. A secrets_map.txt next
# to the script (or SECRETS_MAP=path) is read on top of this list, not instead
# of it.
# Find more with:  ./ontap_backup_cleanup.sh secrets <region>   (??? = no match)
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

SECRET_CACHE="$(mktemp -d 2>/dev/null || printf '/tmp/bkcleanup.%s' "$$")"
mkdir -p "$SECRET_CACHE"
trap 'rm -rf "$SECRET_CACHE"' EXIT

# The built-in map and secrets_map.txt, merged once into one file, before any
# cluster is touched.
#
# Merging it per cluster instead put a pipeline and a subshell on the hot path
# inside build_collect_block's loop — the loop that also assembles the command
# block fed to login.sh. That is the one place in this script where an extra
# subshell is not free, so the lookup below stays a single guarded `awk ... FILE`
# reading a file, nothing else.
SECRETS_MAP_FILE="$SECRET_CACHE/secrets_map.merged"
{ [[ -f "$SECRETS_MAP" ]] && cat -- "$SECRETS_MAP"
  printf '%s\n' "$SECRETS_BUILTIN"
} </dev/null 2>/dev/null \
  | awk '$1 !~ /^#/ && NF >= 2 && !seen[tolower($1) " " tolower($2)]++' >"$SECRETS_MAP_FILE"

CSV="$REPORTDIR/backups_all.csv"

usage() {
  cat <<USAGE
Usage:
  ./ontap_backup_cleanup.sh                  $DEFAULT_REGION: collect, then plan (no deletes)
  ./ontap_backup_cleanup.sh <region>...      e.g. eu-w6 eu-w4
  ./ontap_backup_cleanup.sh <cluster>...     a single stamp
  ./ontap_backup_cleanup.sh all              the whole inventory
  ./ontap_backup_cleanup.sh plan             re-plan from saved captures, no logins
  ./ontap_backup_cleanup.sh delete [opts]    DRY RUN unless --execute is given
  ./ontap_backup_cleanup.sh list             show the inventory
  ./ontap_backup_cleanup.sh secrets [target] which secret will be tried per cluster

delete options:
  --execute        really run the deletes. Without it, the commands are only printed.
  --limit N        stop after N deletions this run (default: $DELETE_LIMIT_DEFAULT, 0 = no cap)
  --yes            skip the typed confirmation (for an approved, scripted run)
  <region|cluster|node> restrict to part of what was collected. Region and cluster
                   match in full; a node matches on any part of its name, so "nc06"
                   is enough. Without this, --limit works down the plan in node
                   order and may never reach the node you care about.

Credentials: admin and sre-rw only. sre-ro is read-only and cannot delete, so it
is never tried — if neither of the others works you are asked for a username and
password, and whatever you type is used as typed.

What it collects, per node:
  system configuration backup show -node <node>

What counts as a backup: a name matching backup_YYYYMMDD_HHMMSS.7z. Anything
else in the table is ignored and reported as SKIPPED, never deleted.

What gets deleted: backups STRICTLY older than $RETAIN_DAYS days, except the newest
$MIN_KEEP on each node, which are kept whatever their age.

The delete command, exactly as issued:
  system configuration backup delete -node <node> -backup <name>

Writes:
  backups/<region>/<cluster>.txt      raw capture, pre-delete
  logs/POST_<cluster>.txt             raw capture, re-taken after a delete run
  report/backups_all.csv              region,cluster,node,backup,timestamp,size,age_days,rank,action
  report/delete_plan.txt              the exact commands — the review artefact
  report/backups_summary.txt          per-node counts and reclaimable space
  report/deleted.txt                  what actually disappeared, proven by the post-check

Environment:
  RETAIN_DAYS=n     delete older than this many days   (default: 30)
  MIN_KEEP=n        newest per node never deleted      (default: 5)
  DELETE_BATCH=n    deletes chained per ssh            (default: 20)
  DEFAULT_REGION    where a bare run goes              (default: eu-w6)
  LOGIN_SH=path     path to your login.sh              (default: alongside this script)
  MODE=login|direct force the hop mode                 (default: auto-detect)
  ONTAP_PASSWORD    one password for all clusters      (skips Secret Manager)
  ASK_CREDS=1       always prompt for user/password    (skips Secret Manager)
  GCP_PROJECT       force one project for all Secret Manager lookups
  PROJECT_MAP=file  per-region projects, "region project" (default: netapp-<region>-sde)
  SECRETS_MAP=file  extra per-cluster secrets, "vserver secret [user]", added
                    to the list built into this script
  SSH_USER          default cluster user               (default: admin)
  MAX_SECRETS=n     credentials tried before asking    (default: 4)
  MAX_ATTEMPTS=n    prompt-and-retry rounds            (default: 3)

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

select_targets() {
  local a m out=""
  for a in "$@"; do
    case "$(lc "$a")" in
      all) out+="$(select_clusters all)"$'\n' ;;
      *)   m="$(select_clusters "$a")"
           [[ -z "$m" ]] && { printf 'ERROR: not a region or cluster in the inventory: %s  (try: ./ontap_backup_cleanup.sh list)\n' "$a" >&2; return 1; }
           out+="$m"$'\n' ;;
    esac
  done
  printf '%s' "$out" | awk 'NF' | sort -u -k1,1 -k2,2
}

# ---------------------------------------------------------------- passwords --

# Secrets live in the region's own project. Default naming: netapp-<region>-sde.
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

# The ONTAP account that goes with a secret, read off its name. Getting this
# wrong is expensive: the password is right but offered under the wrong username,
# so the login is refused and a MAX_SECRETS slot is spent proving nothing.
user_for_secret() {
  case "$(lc "$1")" in
    *sre?rw)          printf 'sre-rw' ;;
    *sre?ro|*sre?r0)  printf 'sre-ro' ;;
    *_sde|*-sde)      printf 'sde' ;;
    *_svc?sde)        printf 'svc-sde' ;;
    *)                printf '%s' "$SSH_USER" ;;
  esac
}

# sre-ro is read-only: it cannot run `system configuration backup delete`. This
# script exists to delete, so sre-ro is never tried at all — not for the collect
# either, so that a cluster which only answers to it fails at collect time, where
# you can see it and type a working account, rather than collecting happily and
# then deleting nothing.
is_readonly_user() {
  case "$(lc "${1:-}")" in
    sre-ro|sre_ro|sre-r0|sre_r0|*readonly*|*read-only*) return 0 ;;
  esac
  return 1
}

# OKM passphrases, backup keys and the like sit next to the credentials and are
# never something you can log in with as admin.
#
# "backup" in a secret name means a backup SERVICE ACCOUNT here — eu-w6 has
# ...-SVC-ONTAPBACKUP and ..._svc-backup — not the admin password. Tempting to
# keep them in a script about backups, but they filled MAX_SECRETS with three
# credentials that were never going to work and pushed the real one out.
is_credential_secret() {
  case "$(lc "$1")" in
    *okm*|*passphrase*|*backup*|*cert*|*keyfile*) return 1 ;;
  esac
  return 0
}

# A secrets_map.txt sitting next to the script adds to the built-in list rather
# than replacing it, and is read first so its lines are tried first. Dropping one
# new line in a file must never silently lose the entries already worked out.
# Ordered "secret<TAB>user" candidates for a cluster, best first. The secret
# named after the cluster holds admin, but plenty of stamps refuse that account
# and only accept sre-rw, so both are tried in turn before a human is asked for
# anything. Anything resolving to sre-ro is dropped — see is_readonly_user.
credential_candidates() {
  local vserver="$1" region="$2" list

  {
    if [[ -s "$SECRETS_MAP_FILE" ]]; then
      awk -v v="$(lc "$vserver")" '
        $1 ~ /^#/ { next }
        tolower($1) == v && $2 != "" { print $2 "\t" $3 }
      ' "$SECRETS_MAP_FILE"
    fi

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
        u="${u:-$(user_for_secret "$s")}"
        is_readonly_user "$u" && continue
        printf '%s\t%s\n' "$s" "$u"
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

# What each account tried last time actually got back, one line per account.
#
# Keeping only the usernames ("admin, sre-rw") gives the operator nothing to act
# on. The reason is already sitting in the capture — "admin : Permission denied"
# says the secret is stale, "admin : Connection timed out" says the cluster is
# unreachable and no password will help — so show it.
tried_detail() {
  [[ -f "${1:-}" ]] || return 0
  sed -n 's/^===TRIED=== //p' "$1"
}

prompt_creds() {
  local vserver="$1" region="$2" prev="${3:-}" proj u="" pw="" near="" line n=0
  proj="$(project_for "$region")"
  CRED_USERS=(); CRED_PWS=(); CRED_DESC="typed in"

  printf '\n    %s  [%s]\n' "$vserver" "$region" >&2

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '      refused : %s\n' "${line:0:110}" >&2
    n=$(( n + 1 ))
  done < <(tried_detail "$prev")

  # No ===TRIED=== line means no login was even attempted — the block never ran
  # on the jumphost, or ssh never returned. Typing another password cannot fix
  # that, so say so instead of silently asking again.
  if (( n == 0 )) && [[ -n "$prev" ]]; then
    printf '      refused : nothing came back — no login was attempted.\n' >&2
    printf '                check %s\n' "$BACKUPDIR/_session_$region.log" >&2
  fi

  printf '      note    : needs an account that can delete — sre-ro cannot\n' >&2
  printf '      project : %s\n' "$proj" >&2
  printf '      secrets : https://console.cloud.google.com/security/secret-manager?project=%s\n' "$proj" >&2
  printf '      search  : %s\n' "$vserver" >&2

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
  # Whatever is typed here is used as typed, including sre-ro. This prompt is the
  # escape hatch for a cluster the naming conventions don't cover, so it should
  # not second-guess an account the operator has deliberately chosen.
  CRED_USERS=( "${u:-$SSH_USER}" ); CRED_PWS=( "$pw" )
  return 0
}

prepare_creds() {
  local vserver="$1" region="$2" retry="${3:-0}" prev="${4:-}"

  if [[ "$retry" == "1" || "${ASK_CREDS:-0}" == "1" ]]; then
    prompt_creds "$vserver" "$region" "$prev"
    return $?
  fi

  if gather_creds "$vserver" "$region"; then
    printf '    %-38s <- %s\n' "$vserver" "$CRED_DESC" >&2
    return 0
  fi

  prompt_creds "$vserver" "$region" ""
}

# ------------------------------------------------------------------ capture --

# A capture counts only if ONTAP actually answered. ===USER=== is written only
# after a login succeeded, so a refused attempt's error text can never be
# mistaken for "this node has no backups".
valid_capture() {
  [[ -s "$1" ]] || return 1
  grep -q '^===USER===' "$1"
}

capture_user() { sed -n 's/^===USER=== //p' "${1:-}" 2>/dev/null | head -n1; }

failure_reason() {
  local f="$1" t
  # Nothing at all came back, so the remote block died before it printed even a
  # marker. That is a jumphost-side problem, not a cluster one, and the session
  # log is the only place the reason exists — say so rather than leaving the
  # operator with two words and nowhere to look.
  [[ -s "$f" ]] || { printf 'no output at all — see %s/_session_*.log' "$BACKUPDIR"; return; }

  t="$(sed -n 's/^===TRIED=== //p' "$f" | awk '{ printf "%s%s", sep, $0; sep=" | " }')"
  [[ -n "$t" ]] && { printf '%s' "$t" | cut -c1-100; return; }

  if   grep -qi 'permission denied\|authentication fail\|access denied' "$f"; then printf 'bad username/password'
  elif grep -qi 'timed out\|no route to host\|refused\|unreachable'      "$f"; then printf 'unreachable'
  elif grep -qi 'not authorized\|insufficient privileges'                "$f"; then printf 'user lacks rights (needs advanced privilege)'
  else tr -d '\r' <"$f" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-60
  fi
}

FAILED=0
FAILED_LIST=""

note_failure() {
  local vs="$1" f="$2" why; why="$(failure_reason "$f")"
  FAILED=$(( FAILED + 1 ))
  FAILED_LIST+="$(printf '  %-38s %s' "$vs" "$why")"$'\n'
  printf '    %-38s FAILED   %s\n' "$vs" "$why"
}

# The shell function that runs on the jumphost. One ssh call per credential,
# walked here rather than back on the admin machine, so a cluster that refuses
# the admin secret falls through to the next candidate inside the same hop.
#
# Deliberately kept to the same shape as ontap_vol0_check.sh's helper, which is
# known to work against these jumphosts. An earlier version made two nested ssh
# calls and built a command from the first one's output; it produced no output at
# all and left nothing to debug with.
remote_helper() {
  printf '%s\n' '__bk_collect() {
  __ip=$1; __cmd=$2; shift 2
  while [ $# -ge 2 ]; do
    __u=$1; __p=$2; shift 2
    __out=$(SSHPASS="$__p" sshpass -e ssh -n '"$SSH_OPTS_STR"' "$__u@$__ip" "$__cmd" 2>&1)
    case "$__out" in
      *_backup_*|*"Backup Name"*|*"entries were displayed"*|*"no entries"*)
        printf "===USER=== %s\n%s\n" "$__u" "$__out"
        return 0 ;;
    esac
    printf "===TRIED=== %s : %s\n" "$__u" "$(printf "%s" "$__out" | tr -d "\r" | grep -v "^[ 	]*$" | tail -n1)"
  done
  return 1
}'
}

build_collect_block() {
  local region="$1" vslist="$2" retry="${3:-0}" vs ip i args

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'
  remote_helper

  # fd 3 so ssh/gcloud inside the loop can't swallow the cluster list
  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    if [[ -z "$ip" ]]; then
      printf '    !! %s is not in the inventory, skipping\n' "$vs" >&2; continue
    fi
    if ! prepare_creds "$vs" "$region" "$retry" "$BACKUPDIR/$region/$vs.txt"; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2; continue
    fi

    args=""
    for (( i=0; i<${#CRED_USERS[@]}; i++ )); do
      args+=" $(shq "${CRED_USERS[i]}") $(shq "${CRED_PWS[i]}")"
    done

    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf '__bk_collect %s %s%s\n' "$(shq "$ip")" "$(shq "$BACKUP_CMD")" "$args"
  done 3<<< "$vslist"

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

split_log() {
  local region="$1" raw="$2" dest="$3"

  if grep -q '===NOSSHPASS===' "$raw" 2>/dev/null; then
    printf '    !! sshpass missing on the %s jumphost -> sudo apt-get install -y sshpass\n' "$region"
    return 1
  fi

  mkdir -p "$dest"
  tr -d '\r' <"$raw" | awk -v d="$dest" '
    /^===CLUSTER=== / { file=d "/" $2 ".txt"; next }
    /^===END===/      { file=""; next }
    file != ""        { print > file }
  '
}

# ------------------------------------------------------------------- parsing --

# Today, as three numbers, for the age arithmetic in awk.
today_parts() { date +'%Y %m %d'; }

# Raw rows out of one capture: region,cluster,node,backup,timestamp,size
#
# A row counts only if it carries a name matching backup_YYYYMMDD_HHMMSS.7z.
# Everything else in the table — headers, totals, any other backup flavour — is
# ignored, so nothing outside the agreed pattern can ever reach a delete.
#
# The node is taken from the table's own first column. If the name's own node
# prefix disagrees with it, the row is emitted as MISMATCH instead: `delete`
# needs -node and -backup to refer to the same thing, and a disagreement means
# this parser has misread the line.
parse_backups() {
  local f="$1" region="$2" cluster="$3"
  awk -v region="$region" -v cluster="$cluster" '
    function isbackup(s) {
      return s ~ /_backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]\.7z$/
    }
    function issize(s) { return s ~ /^[0-9]+(\.[0-9]+)?(B|KB|MB|GB|TB)$/ }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

    # One logical row, however many printed lines it arrived on.
    function flush(rec,   n, g, i, name, ni, prefix, node, size, stamp) {
      if (rec == "") return
      n = split(rec, g, /[ \t]+/)

      name = ""; ni = 0
      for (i = 1; i <= n; i++) if (isbackup(g[i])) { name = g[i]; ni = i; break }
      if (name == "") return

      prefix = name; sub(/_backup_.*$/, "", prefix)
      node = (ni > 1) ? g[1] : prefix

      size = "-"
      if (n >= 1 && issize(g[n])) size = g[n]

      stamp = name
      sub(/^.*_backup_/, "", stamp); sub(/\.7z$/, "", stamp)

      if (node != prefix) {
        printf "%s,%s,%s,%s,%s,%s,MISMATCH\n", region, cluster, node, name, stamp, size
        return
      }
      printf "%s,%s,%s,%s,%s,%s,OK\n", region, cluster, node, name, stamp, size
    }

    # ONTAP wraps a long row over three printed lines — node, then the backup
    # name, then the time and size — each continuation indented:
    #
    #   CH-ZRH-NC01-D001C03R0113
    #              CH-ZRH-NC01-D001C03R0113_backup_20260801_000003.7z
    #                                       08/01 00:00:04     444.5MB
    #
    # A new row always starts in column 1, so anything indented belongs to the
    # row above. Joining on that rebuilds the logical row and the same parser
    # then handles both the wrapped and the one-line form.
    /^===/          { flush(rec); rec = ""; next }
    /^[ \t]/        { rec = rec " " trim($0); next }
                    { flush(rec); rec = trim($0) }
    END             { flush(rec) }
  ' "$f"
}

# region,cluster,node,backup,timestamp,size,age_days,rank,action
#
# rank is the backup's position on its node, newest first, and is what MIN_KEEP
# acts on. Ordering is done by sort before this sees anything, so rank is a
# plain counter rather than something awk has to work out.
classify() {
  local ty tm td
  read -r ty tm td <<< "$(today_parts)"

  sort -t, -k3,3 -k5,5r \
    | awk -F, -v retain="$RETAIN_DAYS" -v minkeep="$MIN_KEEP" \
              -v ty="$ty" -v tm="$tm" -v td="$td" '
    # Days since epoch, civil calendar. Portable: no mktime, which mawk lacks.
    function days(y, m, d,   era, yoe, doy, doe) {
      y -= (m <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    BEGIN { todayd = days(ty + 0, tm + 0, td + 0) }
    {
      stamp = $5
      y = substr(stamp, 1, 4) + 0; m = substr(stamp, 5, 2) + 0; d = substr(stamp, 7, 2) + 0
      age = todayd - days(y, m, d)

      if ($3 != prevnode) { rank = 0; prevnode = $3 }
      rank++

      if ($7 == "MISMATCH")   action = "SKIP_MISMATCH"
      else if (age <= retain) action = "KEEP_RECENT"
      else if (rank <= minkeep) action = "KEEP_FLOOR"
      else                    action = "DELETE"

      printf "%s,%s,%s,%s,%s,%s,%d,%d,%s\n", $1, $2, $3, $4, $5, $6, age, rank, action
    }
  '
}

# ------------------------------------------------------------------- collect --

collect_via_login() {
  local targets="$1"
  [[ -x "$LOGIN_SH" ]] || die "login.sh not found/executable at $LOGIN_SH  (set LOGIN_SH=/path/to/login.sh, or MODE=direct if you are on a jumphost)"

  local region in_region pending block raw vs attempt done_list f
  for region in $(printf '%s\n' "$targets" | awk '{print $1}' | sort -u); do
    in_region="$(printf '%s\n' "$targets" | awk -v r="$region" '$1==r {print $2}' | sort -u)"
    printf '\n==> %s : %s %s\n' "$region" "$LOGIN_SH" "$region"

    mkdir -p "$BACKUPDIR/$region"
    while read -r vs; do [[ -n "$vs" ]] && rm -f "$BACKUPDIR/$region/$vs.txt"; done <<< "$in_region"

    pending="$in_region"
    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      [[ -z "$pending" ]] && break
      raw="$BACKUPDIR/_session_$region.log"
      if (( attempt > 1 )); then
        raw="$BACKUPDIR/_session_${region}_try$attempt.log"
        printf '\n    %s cluster(s) did not answer — attempt %s of %s, enter credentials\n' \
          "$(grep -c . <<< "$pending")" "$attempt" "$MAX_ATTEMPTS"
      fi

      block="$(build_collect_block "$region" "$pending" "$(( attempt > 1 ? 1 : 0 ))")"
      grep -q '===CLUSTER===' <<< "$block" || { printf '    skipped (no credentials)\n'; break; }

      printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
      split_log "$region" "$raw" "$BACKUPDIR/$region" || break

      done_list=""
      while read -r vs; do
        [[ -z "$vs" ]] && continue
        valid_capture "$BACKUPDIR/$region/$vs.txt" && done_list+="$vs"$'\n'
      done <<< "$pending"
      pending="$(comm -23 <(printf '%s\n' "$pending" | sort -u) \
                          <(printf '%s' "$done_list" | sort -u) | grep . || true)"
    done

    while read -r vs; do
      [[ -z "$vs" ]] && continue
      f="$BACKUPDIR/$region/$vs.txt"
      if valid_capture "$f"; then show_cluster "$region" "$vs" "$f"
      else note_failure "$vs" "$f"
      fi
    done <<< "$in_region"
  done
}

collect_direct() {
  local targets="$1"
  command -v sshpass >/dev/null 2>&1 || die "sshpass not installed. Try: sudo apt-get install -y sshpass"

  local region vs ip f attempt i out
  while read -r region vs ip <&3; do
    [[ -z "$vs" ]] && continue
    mkdir -p "$BACKUPDIR/$region"
    f="$BACKUPDIR/$region/$vs.txt"
    rm -f "$f"

    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
      if ! prepare_creds "$vs" "$region" "$(( attempt > 1 ? 1 : 0 ))" "$f"; then
        printf '    %-38s SKIP (no password)\n' "$vs"; break
      fi

      : >"$f"
      for (( i=0; i<${#CRED_USERS[@]}; i++ )); do
        out="$(SSHPASS="${CRED_PWS[i]}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
                 "${CRED_USERS[i]}@$ip" "$BACKUP_CMD" 2>&1 | tr -d '\r')"
        if grep -q '_backup_\|Backup Name\|entries were displayed\|no entries' <<< "$out"; then
          printf '===USER=== %s\n%s\n' "${CRED_USERS[i]}" "$out" >>"$f"
          break
        fi
        printf '===TRIED=== %s : %s\n' "${CRED_USERS[i]}" \
          "$(grep -v '^[[:space:]]*$' <<< "$out" | tail -n1)" >>"$f"
      done

      valid_capture "$f" && break
    done

    if valid_capture "$f"; then show_cluster "$region" "$vs" "$f"
    else note_failure "$vs" "$f"
    fi
  done 3< <(printf '%s\n' "$targets")
}

show_cluster() {
  local region="$1" vs="$2" f="$3" login nodes rows
  login="$(capture_user "$f")"
  nodes="$(parse_backups "$f" "$region" "$vs" | awk -F, '{print $3}' | sort -u | grep -c . || true)"
  rows="$(parse_backups "$f" "$region" "$vs" | grep -c . || true)"
  printf '    %-38s %s node(s), %s backup(s)   [%s]\n' "$vs" "$nodes" "$rows" "${login:-?}"

  # A paged capture holds the first screen only. Planning from it would look
  # perfectly healthy while quietly missing most of the node's backups.
  if grep -q 'Press <space>' "$f" 2>/dev/null; then
    printf '    %-38s !! OUTPUT WAS PAGINATED — capture is incomplete, "row 0" did not take\n' "$vs"
  fi
}

# -------------------------------------------------------------------- report --

build_report() {
  [[ -d "$BACKUPDIR" ]] || die "no captures yet — run ./ontap_backup_cleanup.sh $DEFAULT_REGION first"
  mkdir -p "$REPORTDIR"

  local plan="$REPORTDIR/delete_plan.txt"
  local summary="$REPORTDIR/backups_summary.txt"

  printf 'region,cluster,node,backup,timestamp,size,age_days,rank,action\n' >"$CSV"
  local f vs region
  while IFS= read -r f <&3; do
    vs="$(basename "$f" .txt)"
    region="$(basename "$(dirname "$f")")"
    valid_capture "$f" || continue
    parse_backups "$f" "$region" "$vs"
  done 3< <(find "$BACKUPDIR" -type f -name '*.txt' ! -name '_session_*' | sort) \
    | classify | sort -t, -k1,1 -k2,2 -k3,3 -k5,5 >>"$CSV"

  # The review artefact: the exact commands, in the order they would be issued.
  {
    printf '# Generated %s by ontap_backup_cleanup.sh\n' "$(date +'%Y-%m-%d %H:%M:%S %Z')"
    printf '# Delete backups strictly older than %s days, keeping the newest %s per node.\n' \
      "$RETAIN_DAYS" "$MIN_KEEP"
    printf '# Only names matching backup_YYYYMMDD_HHMMSS.7z are ever considered.\n#\n'
    awk -F, 'NR>1 && $9=="DELETE" {
      if ($2 != cluster) { cluster = $2; printf "\n# ---- %s  [%s] ----\n", $2, $1 }
      printf "system configuration backup delete -node %s -backup %s\n", $3, $4
    }' "$CSV"
  } >"$plan"

  awk -F, '
    NR > 1 {
      k = $1 "\t" $2 "\t" $3
      if (!(k in seen)) { order[++o] = k; seen[k] = 1 }
      total[k]++
      if ($9 == "DELETE")        { del[k]++;  delmb[k] += tomb($6) }
      if ($9 == "KEEP_RECENT")   keep[k]++
      if ($9 == "KEEP_FLOOR")    floor[k]++
      if ($9 == "SKIP_MISMATCH") bad[k]++
      if (oldest[k] == "" || $5 < oldest[k]) oldest[k] = $5
      if (newest[k] == "" || $5 > newest[k]) newest[k] = $5
    }
    function tomb(s,   n, u) {
      if (s !~ /^[0-9]+(\.[0-9]+)?(B|KB|MB|GB|TB)$/) return 0
      n = s + 0; u = s; sub(/^[0-9]+(\.[0-9]+)?/, "", u)
      if (u == "B")  return n / 1048576
      if (u == "KB") return n / 1024
      if (u == "MB") return n
      if (u == "GB") return n * 1024
      if (u == "TB") return n * 1048576
      return 0
    }
    END {
      printf "%-8s %-38s %-26s %6s %7s %7s %6s %5s %10s  %s\n",
             "REGION", "CLUSTER", "NODE", "TOTAL", "DELETE", "RECENT", "FLOOR", "ODD", "RECLAIM", "OLDEST..NEWEST"
      for (i = 1; i <= o; i++) {
        k = order[i]; split(k, p, "\t")
        printf "%-8s %-38s %-26s %6d %7d %7d %6d %5d %9.1fG  %s..%s\n",
               p[1], p[2], p[3], total[k], del[k], keep[k], floor[k], bad[k],
               delmb[k] / 1024, oldest[k], newest[k]
      }
    }
  ' "$CSV" >"$summary"

  local rows dels bad clusters nodes
  rows="$(( $(wc -l <"$CSV" | tr -d ' ') - 1 ))"
  dels="$(awk -F, 'NR>1 && $9=="DELETE"' "$CSV" | grep -c . || true)"
  bad="$(awk -F, 'NR>1 && $9=="SKIP_MISMATCH"' "$CSV" | grep -c . || true)"
  clusters="$(awk -F, 'NR>1 {print $2}' "$CSV" | sort -u | grep -c . || true)"
  nodes="$(awk -F, 'NR>1 {print $2"/"$3}' "$CSV" | sort -u | grep -c . || true)"

  local paged
  paged="$(grep -rl 'Press <space>' "$BACKUPDIR" 2>/dev/null | grep -c . || true)"
  if [[ "$paged" != "0" ]]; then
    printf '\n!! %s capture(s) were paginated and hold only the first screen.\n' "$paged"
    printf '   Plan built from them is incomplete. Fix the pager, re-collect, re-plan.\n'
  fi

  printf '\n%-34s %s\n' 'Clusters'                    "$clusters"
  printf '%-34s %s\n'   'Nodes'                       "$nodes"
  printf '%-34s %s\n'   'Backups matching the pattern' "$rows"
  printf '%-34s %s\n'   "Older than ${RETAIN_DAYS}d, past the ${MIN_KEEP} kept" "$dels"
  [[ "$bad" != "0" ]] && printf '%-34s %s  <- node column disagrees with the name, not touched\n' 'Odd rows' "$bad"

  printf '\n'
  cat "$summary"

  printf '\n  %s\n  %s\n  %s\n' "$summary" "$CSV" "$REPORTDIR/delete_plan.txt"
  printf '\nNothing has been deleted. Review %s, then:\n' "$REPORTDIR/delete_plan.txt"
  printf '  ./ontap_backup_cleanup.sh delete                       # dry run again\n'
  printf '  ./ontap_backup_cleanup.sh delete --execute --limit 2   # the first real two\n'
}

# -------------------------------------------------------------------- delete --

# A filter token selects a row by exact region, exact cluster, or as a substring
# of the node name. The node case is a substring because node names are long and
# only the NCxx part distinguishes them: "nc06" is what you actually want to type.
FILTER_AWK='
  function row_wanted(r, c, nd,   i) {
    if (nf == 0) return 1
    for (i = 1; i <= nf; i++)
      if (want[i] == r || want[i] == c || index(nd, want[i]) > 0) return 1
    return 0
  }
  BEGIN { nf = split(f, a, " "); for (i = 1; i <= nf; i++) want[i] = tolower(a[i]) }
'

# "region cluster node backup" for everything the plan marks DELETE, optionally
# narrowed to some regions/clusters/nodes and capped at a limit.
deletion_rows() {
  local filter="$1" limit="$2"
  awk -F, -v f="$filter" -v lim="$limit" "$FILTER_AWK"'
    NR > 1 && $9 == "DELETE" {
      if (!row_wanted(tolower($1), tolower($2), tolower($3))) next
      if (lim > 0 && ++c > lim) exit
      print $1, $2, $3, $4
    }
  ' "$CSV"
}

# Runs on the jumphost. One ssh per batch of deletes; what actually went is
# decided afterwards by re-reading the node, not by parsing ONTAP's replies.
remote_delete_helper() {
  # __bk_pick settles on ONE credential for the whole cluster before anything is
  # deleted, by proving it can log in with a harmless read. Every batch then runs
  # as that account: falling through accounts mid-way would leave a half-applied
  # cluster with no record of which delete ran as whom.
  printf '%s\n' '__bk_pick() {
  __ip=$1; shift
  __U=""; __P=""
  while [ $# -ge 2 ]; do
    __u=$1; __p=$2; shift 2
    __out=$(SSHPASS="$__p" sshpass -e ssh -n '"$SSH_OPTS_STR"' "$__u@$__ip" '"$(shq "$PROBE_CMD")"' 2>&1)
    if printf "%s" "$__out" | grep -qi "NetApp Release"; then
      __U=$__u; __P=$__p
      printf "===USER=== %s\n" "$__u"
      return 0
    fi
    printf "===TRIED=== %s : %s\n" "$__u" "$(printf "%s" "$__out" | tr -d "\r" | grep -v "^[ 	]*$" | tail -n1)"
  done
  return 1
}

__bk_delete() {
  __ip=$1; __u=$2; __p=$3; shift 3
  __cmd='"$(shq "$DELETE_PREFIX")"'
  for __spec in "$@"; do
    __n=${__spec%%|*}; __b=${__spec#*|}
    __cmd="$__cmd system configuration backup delete -node $__n -backup $__b;"
  done
  SSHPASS="$__p" sshpass -e ssh -n '"$SSH_OPTS_STR"' "$__u@$__ip" "$__cmd" 2>&1 | tr -d "\r"
}'
}

cmd_delete() {
  local execute=0 limit="$DELETE_LIMIT_DEFAULT" assume_yes=0 filter=""
  while (( $# )); do
    case "$1" in
      --execute) execute=1 ;;
      --yes)     assume_yes=1 ;;
      --limit)   shift; [[ $# -gt 0 ]] || die "--limit needs a number: --limit 2"; limit="$1" ;;
      --limit=*) limit="${1#--limit=}" ;;
      --*)       die "unknown option: $1" ;;
      *)         filter+="${filter:+ }$1" ;;
    esac
    shift
  done
  [[ "$limit" =~ ^[0-9]+$ ]] || die "--limit must be a number, got: $limit"

  [[ -f "$CSV" ]] || die "no plan yet — run ./ontap_backup_cleanup.sh $DEFAULT_REGION first"

  local rows total
  rows="$(deletion_rows "$filter" "$limit")"
  total="$(awk -F, -v f="$filter" "$FILTER_AWK"'
    NR > 1 && $9 == "DELETE" {
      if (!row_wanted(tolower($1), tolower($2), tolower($3))) next
      c++
    }
    END { print c + 0 }' "$CSV")"

  if [[ -z "$rows" ]]; then
    printf 'Nothing marked DELETE%s.\n' "${filter:+ in $filter}"
    return 0
  fi

  local n; n="$(grep -c . <<< "$rows")"

  if (( ! execute )); then
    printf 'DRY RUN — nothing will be deleted.\n\n'
    printf 'These %s of %s eligible backup(s) would go:\n\n' "$n" "$total"
    awk '{ printf "  system configuration backup delete -node %s -backup %s\n", $3, $4 }' <<< "$rows"
    printf '\nFull plan: %s\n' "$REPORTDIR/delete_plan.txt"
    printf 'To run these for real:  ./ontap_backup_cleanup.sh delete --execute --limit %s%s\n' \
      "$limit" "${filter:+ $filter}"
    return 0
  fi

  printf 'About to DELETE %s of %s eligible backup(s) on %s cluster(s).\n' \
    "$n" "$total" "$(awk '{print $2}' <<< "$rows" | sort -u | grep -c .)"
  awk '{ printf "  %-38s %s\n", $2, $4 }' <<< "$rows"

  if (( ! assume_yes )); then
    local reply
    printf '\nThis is production. Type DELETE to proceed: '
    read -r reply </dev/tty
    [[ "$reply" == "DELETE" ]] || { printf 'Aborted.\n'; return 1; }
  fi

  local mode="$MODE"
  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }
  case "$mode" in
    login)  delete_via_login "$rows" ;;
    direct) delete_direct    "$rows" ;;
    *)      die "unknown MODE=$mode" ;;
  esac

  verify_deletes "$rows"
}

build_delete_block() {
  local region="$1" rows="$2" vs ip i specs batch one args

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'
  remote_delete_helper

  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    [[ -z "$ip" ]] && { printf '    !! %s is not in the inventory, skipping\n' "$vs" >&2; continue; }
    if ! prepare_creds "$vs" "$region" 0 ""; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2; continue
    fi

    args=""
    for (( i=0; i<${#CRED_USERS[@]}; i++ )); do
      args+=" $(shq "${CRED_USERS[i]}") $(shq "${CRED_PWS[i]}")"
    done

    printf 'echo "===CLUSTER=== %s"\n' "$vs"

    # Settle on one account first, then run every batch as it. Without the probe
    # a cluster that refuses the first credential would silently delete nothing.
    printf 'if __bk_pick %s%s; then\n' "$(shq "$ip")" "$args"

    specs="$(awk -v v="$vs" '$2==v { printf "%s|%s\n", $3, $4 }' <<< "$rows")"
    batch=""; i=0
    while read -r one; do
      [[ -z "$one" ]] && continue
      batch+=" $(shq "$one")"
      i=$(( i + 1 ))
      if (( i % DELETE_BATCH == 0 )); then
        printf '  __bk_delete %s "$__U" "$__P"%s\n' "$(shq "$ip")" "$batch"
        batch=""
      fi
    done <<< "$specs"
    [[ -n "$batch" ]] && printf '  __bk_delete %s "$__U" "$__P"%s\n' "$(shq "$ip")" "$batch"

    printf 'else\n  echo "===NOLOGIN==="\nfi\n'
  done 3< <(awk -v r="$region" '$1==r {print $2}' <<< "$rows" | sort -u)

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

delete_via_login() {
  local rows="$1" region block raw
  [[ -x "$LOGIN_SH" ]] || die "login.sh not found/executable at $LOGIN_SH"

  mkdir -p "$LOGDIR"
  for region in $(awk '{print $1}' <<< "$rows" | sort -u); do
    printf '\n==> %s : issuing deletes\n' "$region"
    raw="$LOGDIR/_delete_$region.log"
    block="$(build_delete_block "$region" "$rows")"
    grep -q '===CLUSTER===' <<< "$block" || { printf '    skipped (no credentials)\n'; continue; }
    printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
    printf '    session log: %s\n' "$raw"
  done
}

delete_direct() {
  local rows="$1" region vs ip cmd n b i j out picked
  command -v sshpass >/dev/null 2>&1 || die "sshpass not installed"

  mkdir -p "$LOGDIR"
  while read -r region vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    prepare_creds "$vs" "$region" 0 "" \
      || { printf '    !! no password for %s\n' "$vs"; continue; }

    # Prove a credential works before deleting with it, and stay on that one.
    picked=-1
    for (( j=0; j<${#CRED_USERS[@]}; j++ )); do
      out="$(SSHPASS="${CRED_PWS[j]}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
               "${CRED_USERS[j]}@$ip" "$PROBE_CMD" 2>&1 | tr -d '\r')"
      if grep -qi 'NetApp Release' <<< "$out"; then picked=$j; break; fi
    done
    if (( picked < 0 )); then
      printf '    %-38s SKIP (no credential could log in)\n' "$vs"; continue
    fi

    cmd="$DELETE_PREFIX"
    i=0
    while read -r n b; do
      [[ -z "$b" ]] && continue
      cmd+=" system configuration backup delete -node $n -backup $b;"
      i=$(( i + 1 ))
    done < <(awk -v v="$vs" '$2==v {print $3, $4}' <<< "$rows")

    printf '    %-38s %s delete(s) as %s\n' "$vs" "$i" "${CRED_USERS[picked]}"
    SSHPASS="${CRED_PWS[picked]}" sshpass -e ssh -n "${SSH_OPTS[@]}" \
      "${CRED_USERS[picked]}@$ip" "$cmd" 2>&1 | tr -d '\r' >>"$LOGDIR/_delete_$vs.log"
  done 3< <(awk '{print $1, $2}' <<< "$rows" | sort -u)
}

# Ground truth: re-read every touched node and see what is actually gone. ONTAP's
# own replies to a chained delete are not attributable to a specific backup, so
# the diff is the only honest answer.
verify_deletes() {
  local rows="$1" region vs f targets
  mkdir -p "$LOGDIR"

  printf '\nRe-reading the clusters to confirm what actually went...\n'
  targets="$(awk '{print $1, $2}' <<< "$rows" | sort -u \
             | while read -r region vs; do printf '%s %s %s\n' "$region" "$vs" "$(ip_for "$vs")"; done)"

  local save="$BACKUPDIR"
  BACKUPDIR="$LOGDIR/post"
  local mode="$MODE"
  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }
  case "$mode" in
    login)  collect_via_login "$targets" ;;
    direct) collect_direct    "$targets" ;;
  esac
  BACKUPDIR="$save"

  local out="$REPORTDIR/deleted.txt"
  mkdir -p "$REPORTDIR"
  : >"$out"

  local gone=0 left=0 keys
  keys="$(mktemp)"
  while read -r region vs node backup; do
    [[ -z "$backup" ]] && continue
    f="$LOGDIR/post/$region/$vs.txt"
    if [[ ! -f "$f" ]]; then
      printf 'UNKNOWN  %-38s %s  (no post-check capture)\n' "$vs" "$backup" >>"$out"
      continue
    fi
    if grep -qF -- "$backup" "$f"; then
      printf 'STILL THERE  %-38s %s\n' "$vs" "$backup" >>"$out"
      left=$(( left + 1 ))
    else
      printf 'DELETED      %-38s %s\n' "$vs" "$backup" >>"$out"
      printf '%s,%s\n' "$node" "$backup" >>"$keys"
      gone=$(( gone + 1 ))
    fi
  done <<< "$rows"

  # Take the deleted rows out of the CSV. `delete` reads the CSV, so leaving them
  # in means the next run picks the same backups again — and the check above only
  # asks "is it there now", so it would call them deleted a second time and the
  # totals would count them twice.
  if (( gone > 0 )) && [[ -s "$keys" && -f "$CSV" ]]; then
    local pruned; pruned="$(mktemp)"
    awk -F, 'NR == FNR { done[$1 SUBSEP $2] = 1; next }
             FNR == 1 || !(($3 SUBSEP $4) in done)' "$keys" "$CSV" >"$pruned" \
      && mv "$pruned" "$CSV" || rm -f "$pruned"
  fi
  rm -f "$keys"

  printf '\n%-24s %s\n' 'Confirmed deleted' "$gone"
  printf '%-24s %s\n'   'Still present'     "$left"
  printf '\n'
  cat "$out"
  printf '\n  %s\n' "$out"

  (( left == 0 ))
}

# ------------------------------------------------------------------- secrets --

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
    (( n == 0 )) && printf '%-38s %-52s %s\n' "$vs" '???' "nothing usable in $(project_for "$region") names this cluster"
  done 3< <(printf '%s\n' "$targets")
}

# ---------------------------------------------------------------------- main --

run_collect() {
  local targets mode="$MODE"
  targets="$(select_targets "$@")" || exit 1
  [[ -z "$targets" ]] && die "nothing selected"

  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }
  printf 'Reading config backups on %s cluster(s) across %s region(s).\n' \
    "$(grep -c . <<< "$targets")" \
    "$(printf '%s\n' "$targets" | awk '{print $1}' | sort -u | grep -c .)"
  printf 'Delete rule: strictly older than %s days, keeping the newest %s per node.\n' \
    "$RETAIN_DAYS" "$MIN_KEEP"

  case "$mode" in
    login)  collect_via_login "$targets" ;;
    direct) collect_direct    "$targets" ;;
    *)      die "unknown MODE=$mode" ;;
  esac

  build_report

  if (( FAILED )); then
    printf '\n%s cluster(s) never answered, so this plan is incomplete:\n%s' \
      "$FAILED" "$FAILED_LIST"
    printf 'Re-run just those: ./ontap_backup_cleanup.sh %s\n' \
      "$(printf '%s' "$FAILED_LIST" | awk '{printf "%s ", $1}')"
    return 1
  fi
}

case "${1:-}" in
  plan|report)     build_report ;;
  delete)          shift; cmd_delete "$@" ;;
  list)            select_clusters all ;;
  secrets)         shift; show_secrets "${@:-all}" ;;
  -h|--help|help)  usage ;;
  collect)         shift; run_collect "${@:-$DEFAULT_REGION}" ;;
  "")              run_collect "$DEFAULT_REGION" ;;
  *)               run_collect "$@" ;;
esac
