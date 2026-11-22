#!/usr/bin/env bash
# scan.sh - run polinrider check on the checkout, and in fix mode clean it.
#
# This step has no token. The scan reads files, and in fix mode the clean
# changes the checkout on this runner; opening the pull request is a separate
# step (publish.sh) that gets the token and never runs polinrider.
#
# Exit codes of polinrider, the same as on a laptop:
#   0 clean, 1 something to review, 2 compromised, 3 could not run.
# Anything else, or a report with no result, is "could not run".

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

mode=${INPUT_MODE:-check}
fail_on=${INPUT_FAIL_ON:-confirmed}
path=${INPUT_PATH:-.}
case "$mode" in check|fix) ;; *) could_not_run "$(say_mode "$mode")" ;; esac
case "$fail_on" in confirmed|review|never) ;; *) could_not_run "$(say_fail_on "$fail_on")" ;; esac
state_put mode "$mode"

workspace=$(cd "${GITHUB_WORKSPACE:?}" && pwd -P)
case "$path" in /*) target=$path ;; *) target="$workspace/$path" ;; esac
[[ -d "$target" ]] || could_not_run "$(say_no_dir "$path")"
target=$(cd "$target" && pwd -P)

# Findings name files relative to the scanned directory. Annotations and the
# pull request need them relative to the repository.
if [[ "$target" == "$workspace" ]]; then prefix=""
elif [[ "$target" == "$workspace/"* ]]; then prefix="${target#"$workspace"/}/"
else prefix="-"; fi
state_put prefix "$prefix"

# An empty home directory, so the verdict is about this repository and not
# about the runner it happens to be on.
home="$STATE/home"
mkdir -p "$home" "$STATE/scan"
ioc=$(state_get ioc)

# --no-git: the checkout is the commit being checked, so its git history
# would only repeat the files on disk. Other branches and older commits are
# for the scan on a computer, where someone can act on them.
check() { # report-file
  (cd "$target" && run_polinrider check --fs-only --no-git . --ioc "$ioc" --home "$home" --report "$1")
}

rc=0
check "$STATE/scan/report.txt" || rc=$?
state_put scan/exit "$rc"

case "$rc" in
  0) verdict=clean ;;
  1) verdict=review ;;
  2) verdict=infected ;;
  *) could_not_run "$(say_no_result "$rc")" ;;
esac
has_result "$STATE/scan/report.txt" || could_not_run "$(say_no_result "$rc")"

findings_of "$STATE/scan/report.txt" > "$STATE/scan/findings.tsv"
state_put scan/confirmed "$(count_of "$STATE/scan/report.txt" 'confirmed indicator hits')"
state_put scan/review "$(count_of "$STATE/scan/report.txt" 'items needing a human')"
state_put scan/files "$(files_of "$STATE/scan/report.txt")"
state_put verdict "$verdict"

[[ "$mode" == fix && "$verdict" == infected ]] || exit 0

# ---------------------------------------------------------------- fix mode

skip() { state_put fix/why "$1"; exit 0; }

if [[ -n "${PR_HEAD_REPO:-}" && "${PR_HEAD_REPO}" != "${GITHUB_REPOSITORY:-}" ]]; then
  skip "$say_fix_fork"
fi

# The branch the pull request will go into, and the commit it starts from.
if [[ -n "${PR_HEAD_REF:-}" ]]; then
  branch=$PR_HEAD_REF tip=$PR_HEAD_SHA
elif [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then
  branch=${GITHUB_REF#refs/heads/} tip=${GITHUB_SHA:?}
else
  skip "$say_fix_not_branch"
fi
[[ "$branch" == polinrider/* ]] && skip "$say_fix_own"

root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$root" && "$(cd "$root" && pwd -P)" == "$workspace" ]] || skip "$say_fix_not_repo"
[[ "$(git -C "$workspace" rev-parse HEAD)" == "$tip" ]] || skip "$say_fix_not_tip"
[[ -z "$(git -C "$workspace" status --porcelain --untracked-files=no)" ]] || skip "$say_fix_dirty"

# The quarantine holds the payload. It goes in the runner's temporary
# directory, outside the workspace, which the runner empties after the job.
# Nothing in this action uploads it.
mkdir -p "$STATE/fix"
crc=0
(cd "$target" && run_polinrider clean --apply --no-git . --ioc "$ioc" \
   --quarantine "$STATE/quarantine" --report "$STATE/fix/clean-report.txt") || crc=$?
case "$crc" in 0|1|2) ;; *) skip "$say_fix_clean_failed" ;; esac
has_result "$STATE/fix/clean-report.txt" || skip "$say_fix_clean_failed"

# What is left, for the pull request to say.
arc=0
check "$STATE/fix/after-report.txt" || arc=$?
case "$arc" in 0|1|2) ;; *) skip "$say_fix_clean_failed" ;; esac
findings_of "$STATE/fix/after-report.txt" > "$STATE/fix/after.tsv"

: > "$STATE/fix/cut"
: > "$STATE/fix/removed"
while IFS= read -r -d '' entry; do
  file=${entry:3}
  case "${entry:0:2}" in
    " M") printf '%s\n' "$file" >> "$STATE/fix/cut" ;;
    " D") printf '%s\n' "$file" >> "$STATE/fix/removed" ;;
  esac
done < <(git -C "$workspace" status --porcelain=v1 -z --untracked-files=no)

[[ -s "$STATE/fix/cut" || -s "$STATE/fix/removed" ]] || skip "$say_fix_untracked"

state_put fix/base "$branch"
state_put fix/tip "$tip"
output fix-ready true
