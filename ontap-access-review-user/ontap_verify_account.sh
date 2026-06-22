#!/usr/bin/env bash
#
# Prove, against the live clusters, whether an account the removed-report claims
# was deleted is actually gone — and emit the exact commands to rebuild only the
# ones that really are missing.
#
#   ./ontap_verify_account.sh check            # read-only, defaults to vsadmin
#   ./ontap_verify_account.sh check srisaran   # any account name
#   ./ontap_verify_account.sh plan             # + restore commands for what's missing
#
# `check` runs `security login show` and nothing else. It cannot change a cluster.
#
# Why this doesn't just read ONTAP_users_removed.txt: that report attributes
# every row to the cluster it was captured from, because the diff that built it
# dropped the vserver column. A data-SVM account like vsadmin never lived on the
# cluster vserver, so the report cannot tell you which vserver to restore it to.
# The PRE_CHECK captures in logs/ still carry the real per-row vserver, so the
# before-state is reconstructed from those instead.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONTAP_LIB_ONLY=1 source "$HERE/ontap_access_review.sh"

ACCOUNT="${ACCOUNT:-vsadmin}"
NOWDIR="$LOGDIR/verify"

usage_verify() {
  cat <<'USAGE'
Usage:
  ./ontap_verify_account.sh check [account]   # read-only: is it still on the clusters?
  ./ontap_verify_account.sh plan  [account]   # same, plus restore commands for anything missing

  account defaults to vsadmin.

Reads the PRE_CHECK_*.txt captures in logs/ for the before-state, re-runs
`security login show` on each of those clusters, and prints PRESENT or MISSING
for every account row. Writes report/restore_plan.txt only if something really
is missing.

Environment: same as ontap_access_review.sh (LOGIN_SH, MODE, SSH_USER, ...).
USAGE
}

# "vserver user application auth-method role" for one capture, keeping the
# vserver each row belongs to — that is the whole point here.
account_rows() {
  local file="$1" who="$2"
  awk -v who="$who" '
    /^Vserver:/              { vs=$2; indata=0; next }
    /^-{5,}/                 { indata=1; next }
    /^[[:space:]]*$/         { indata=0; next }
    /entries were displayed/ { indata=0; next }
    indata && NF>=4 && $1==who { print vs, $1, $2, $3, $4 }
  ' "$file" | sort -u
}

all_vservers() { awk '/^Vserver:/ { print $2 }' "$1" | sort -u; }

region_for() {
  select_clusters all \
    | awk -v v="$1" 'BEGIN { v=tolower(v) } tolower($2)==v && !seen { print $1; seen=1 }'
}

# Clusters whose baseline shows the account, i.e. the ones worth re-checking.
clusters_to_check() {
  local who="$1" pre vs
  for pre in "$LOGDIR"/PRE_CHECK_*.txt; do
    [[ -e "$pre" ]] || continue
    vs="$(basename "$pre" .txt)"; vs="${vs#PRE_CHECK_}"
    [[ -n "$(account_rows "$pre" "$who")" ]] && printf '%s\n' "$vs"
  done
}

# Unscoped on purpose: a data SVM's rows don't come back from a show that is
# narrowed to the cluster vserver, which is exactly how this scare started.
SHOW_ALL='set d; row 0; security login show'

build_check_block() {
  local region="$1" vslist="$2" vs ip

  printf 'stty -echo 2>/dev/null\n'
  printf 'command -v sshpass >/dev/null 2>&1 || echo "===NOSSHPASS==="\n'

  while read -r vs <&3; do
    [[ -z "$vs" ]] && continue
    ip="$(ip_for "$vs")"
    if [[ -z "$ip" ]]; then
      printf '    !! %s is not in the inventory, skipping\n' "$vs" >&2; continue
    fi
    if ! resolve_creds "$vs" "$region" 0; then
      printf '    !! no password for %s, skipping\n' "$vs" >&2; continue
    fi
    printf 'echo "===CLUSTER=== %s"\n' "$vs"
    printf 'SSHPASS=%s sshpass -e ssh -n %s %s@%s %s 2>&1\n' \
      "$(shq "$CRED_PW")" "$SSH_OPTS_STR" "$CRED_USER" "$ip" "$(shq "$SHOW_ALL")"
  done 3<<< "$vslist"

  printf 'echo "===END==="\n'
  printf 'exit\n'
}

split_check_log() {
  local raw="$1"
  mkdir -p "$NOWDIR"
  tr -d '\r' <"$raw" | awk -v d="$NOWDIR" '
    /^===CLUSTER=== / { file=d "/NOW_" $2 ".txt"; next }
    /^===END===/      { file=""; next }
    file != ""        { print > file }
  '
}

PRESENT=0
MISSING=0
SVM_GONE=0
MISSING_ROWS=""

compare_cluster() {
  local vs="$1" who="$2"
  local now="$NOWDIR/NOW_$vs.txt"
  local svm user app auth role

  if ! valid_capture "$now"; then
    printf '    %-38s NO CAPTURE — could not verify, see %s\n' "$vs" "$now"
    return
  fi

  # Materialised once. Re-running the pipeline per row is both O(n^2) on a
  # cluster with hundreds of SVMs and noisy, since `grep -q` exits on the first
  # match and leaves the upstream sort writing to a closed pipe.
  local now_rows now_svms
  now_rows="$(mktemp)"; now_svms="$(mktemp)"
  account_rows "$now" "$who" >"$now_rows"
  all_vservers "$now" >"$now_svms"

  local n_present=0 n_missing=0 n_gone=0
  while read -r svm user app auth role; do
    [[ -z "$svm" ]] && continue
    if grep -qxF "$svm $user $app $auth $role" "$now_rows"; then
      n_present=$((n_present+1)); PRESENT=$((PRESENT+1))
    elif ! grep -qxF "$svm" "$now_svms"; then
      # The whole SVM is gone. On a GCNV cluster the svm_<uuid> vservers come and
      # go with customer volumes, so a baseline taken days ago always lists some
      # that no longer exist. That is not a deleted login.
      n_gone=$((n_gone+1)); SVM_GONE=$((SVM_GONE+1))
    else
      n_missing=$((n_missing+1)); MISSING=$((MISSING+1))
      MISSING_ROWS+="$vs $svm $user $app $auth $role"$'\n'
      printf '    %-38s %-46s %s %s/%s  MISSING\n' "$vs" "$svm" "$user" "$app" "$auth"
    fi
  done < <(account_rows "$LOGDIR/PRE_CHECK_$vs.txt" "$who")

  rm -f "$now_rows" "$now_svms"
  printf '    %-38s %s present, %s missing, %s on SVMs that no longer exist\n' \
    "$vs" "$n_present" "$n_missing" "$n_gone"
}

verify() {
  local who="${1:-$ACCOUNT}" mode="$MODE"
  local targets region rlist raw vs

  targets="$(clusters_to_check "$who")"
  [[ -z "$targets" ]] && die "no PRE_CHECK capture in $LOGDIR mentions '$who' — nothing to verify"

  printf 'Verifying %s on %s cluster(s). This only runs `security login show`.\n\n' \
    "$who" "$(printf '%s\n' "$targets" | grep -c .)"

  [[ "$mode" == "auto" ]] && { [[ -x "$LOGIN_SH" ]] && mode="login" || mode="direct"; }
  mkdir -p "$NOWDIR"

  rlist="$(while read -r vs; do [[ -n "$vs" ]] && region_for "$vs"; done <<< "$targets" | sort -u)"

  if [[ "$mode" == "login" ]]; then
    for region in $rlist; do
      local in_region block
      in_region="$(while read -r vs; do
                     [[ -n "$vs" ]] && [[ "$(region_for "$vs")" == "$region" ]] && printf '%s\n' "$vs"
                   done <<< "$targets")"
      printf '==> %s : %s %s\n' "$region" "$LOGIN_SH" "$region"

      block="$(build_check_block "$region" "$in_region")"
      grep -q '===CLUSTER===' <<< "$block" || { printf '    skipped (no credentials)\n\n'; continue; }

      raw="$NOWDIR/_verify_session_$region.log"
      printf '%s\n' "$block" | "$LOGIN_SH" "$region" >"$raw" 2>&1
      if grep -q '===NOSSHPASS===' "$raw"; then
        printf '    !! sshpass missing on this jumphost\n\n'; continue
      fi
      split_check_log "$raw"

      while read -r vs; do
        [[ -n "$vs" ]] && compare_cluster "$vs" "$who"
      done <<< "$in_region"
      printf '\n'
    done
  else
    command -v sshpass >/dev/null 2>&1 || die "sshpass not installed"
    while read -r vs; do
      [[ -z "$vs" ]] && continue
      local ip; ip="$(ip_for "$vs")"
      [[ -z "$ip" ]] && { printf '    %-38s SKIP (not in inventory)\n' "$vs"; continue; }
      resolve_creds "$vs" "$(region_for "$vs")" 0 \
        || { printf '    %-38s SKIP (no password)\n' "$vs"; continue; }
      SSHPASS="$CRED_PW" sshpass -e ssh -n "${SSH_OPTS[@]}" "$CRED_USER@$ip" \
        "$SHOW_ALL" >"$NOWDIR/NOW_$vs.txt" 2>&1
      compare_cluster "$vs" "$who"
    done <<< "$targets"
  fi

  printf 'Result: %s account row(s) still present, %s missing, %s on SVMs that no longer exist.\n' \
    "$PRESENT" "$MISSING" "$SVM_GONE"
  if [[ "$MISSING" -eq 0 ]]; then
    printf '\n%s is intact on every SVM that still exists. Nothing was deleted and\n' "$who"
    printf 'no restore is needed — the removed-report entries were a reporting artifact.\n'
  fi
}

# Only ever for rows the live check proved are gone. Not run automatically:
# `security login create` with -authentication-method password prompts for a new
# password, so restoring a service account this way replaces its password and
# breaks whatever was using the old one.
write_restore_plan() {
  local who="$1"
  [[ "$MISSING" -eq 0 ]] && return 0

  mkdir -p "$REPORTDIR"
  local plan="$REPORTDIR/restore_plan.txt"
  {
    printf '# Restore commands for %s — %s row(s) confirmed missing on the clusters.\n' \
      "$who" "$MISSING"
    printf '# Each create will PROMPT for a password. Use the account owner'"'"'s\n'
    printf '# current password; typing a new one silently rotates the credential.\n'
    local vs svm user app auth role
    while read -r vs svm user app auth role; do
      [[ -z "$vs" ]] && continue
      printf '\n# cluster %s\n' "$vs"
      printf 'security login create -vserver %s -user-or-group-name %s -application %s -authentication-method %s -role %s\n' \
        "$svm" "$user" "$app" "$auth" "$role"
    done <<< "$MISSING_ROWS"
  } >"$plan"

  printf '\nRestore plan: %s\n' "$plan"
  printf 'Review it, then run the commands by hand — each one prompts for a password.\n'
}

case "${1:-}" in
  check) shift; verify "${1:-$ACCOUNT}" ;;
  plan)  shift; verify "${1:-$ACCOUNT}"; write_restore_plan "${1:-$ACCOUNT}" ;;
  -h|--help|help|"") usage_verify ;;
  *) usage_verify; exit 1 ;;
esac
