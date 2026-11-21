#!/usr/bin/env bash
# test/run.sh - run the action's steps against fixture repositories.
#
# Runs INSIDE a disposable container (test/container.sh starts one), never on
# a workstation: fix mode moves files, and the binary is only ever run in a
# container or on a CI runner.
#
# It plays the runner: it sets the variables GitHub sets, runs each step of
# action.yml in order with the env and the conditions action.yml gives it, and
# stands a fake gh on the PATH that records what would have been sent to
# GitHub. The archive comes from /dist, a release downloaded beforehand with
# gh release download, served to the action as a file:// URL.
#
# Fixtures carry no payload. The strong and weak indicators are read from the
# downloaded release's own ioc/ at run time.

# The checks are single-quoted on purpose: check() evaluates them later.
# shellcheck disable=SC2016
set -uo pipefail

ACTION=${ACTION:-/action}
DIST=${DIST:-/dist}
T=$(mktemp -d)
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  pass  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

case "$(uname -m)" in
  x86_64|amd64) ARCH=X64 PLAT=linux-x86_64 ;;
  aarch64|arm64) ARCH=ARM64 PLAT=linux-arm64 ;;
esac

# The pins, read from action.yml as the runner would pass them.
pin() { awk -v k="$1:" '$1 == k { v = $2; gsub(/"/, "", v); print v; exit }' "$ACTION/action.yml"; }
VERSION=$(pin POLINRIDER_VERSION)
archive="$DIST/v$VERSION/polinrider-v$VERSION-$PLAT.tar.gz"
[[ -f "$archive" ]] || { echo "no $archive. Download the release first, see test/container.sh." >&2; exit 3; }

# Indicators for the fixtures, from the release itself.
mkdir -p "$T/ioc" && tar -xzf "$archive" -C "$T/ioc" --strip-components=2 --wildcards '*/ioc/*'
STRONG=$(grep -v '^#' "$T/ioc/strong.txt" | grep -v '^$' | head -n 1)
WEAK=$(grep -v '^#' "$T/ioc/weak.txt" | grep -v '^$' | head -n 1)
PAD=$(printf '%280s' '')

# ---------------------------------------------------------------- a fake gh

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Records every call. Answers like GitHub for a repository with no pull
# request or branch from this action yet.
log=${GH_LOG:?}
n=$(( $(ls "$log" | wc -l) + 1 ))
printf '%s\n' "$*" > "$log/$n.args"
input=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --input ]]; then j=$((i + 1)); input=${!j}; fi
done
if [[ "$input" == - ]]; then cat > "$log/$n.body"; elif [[ -n "$input" ]]; then cp "$input" "$log/$n.body"; fi
case "$*" in
  *"pulls?state=all"*) [[ -n "${GH_EXISTING:-}" ]] && printf '%s\n' "$GH_EXISTING"; exit 0 ;;
  *"git/ref/heads/"*) exit 1 ;;
  *"-X POST repos/"*"/git/refs"*) exit 0 ;;
  *graphql*) echo 0123456789abcdef0123456789abcdef01234567; exit 0 ;;
  *"-X POST repos/"*"/pulls"*) echo "https://github.com/owner/repo/pull/7"; exit 0 ;;
  *"issues/"*"/comments"*) exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2; exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# ---------------------------------------------------------------- fixtures

repo() { # name
  local d="$T/ws/$1"
  mkdir -p "$d" && git -C "$d" init -q -b main && git -C "$d" config user.email t@example.invalid \
    && git -C "$d" config user.name test && git -C "$d" config commit.gpgsign false
  printf '%s' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm fixture; }

infected_tree() { # dir
  printf 'export default { plugins: [] };%s%s\n' "$PAD" "$STRONG" > "$1/vite.config.js"
  mkdir -p "$1/.vscode" "$1/src"
  # Written in two halves so this script does not itself carry the weak
  # signal: the action scans this repository in CI and must find it clean.
  local run_on="folder""Open"
  printf '{"version":"2.0.0","tasks":[{"label":"x","type":"shell","command":"node -e \\"%s\\"","runOptions":{"runOn":"%s"}}]}\n' "$STRONG" "$run_on" > "$1/.vscode/tasks.json"
  printf 'const x = "%s";\n' "$WEAK" > "$1/src/app.js"
  echo '# demo' > "$1/README.md"
}

# ---------------------------------------------------------------- the runner

# run_action CASE WORKSPACE [VAR=value ...]
# Runs the steps of action.yml in order. Leaves the step outputs, the summary
# and the log in $T/out/CASE.
run_action() {
  local name=$1 ws=$2; shift 2
  local out="$T/out/$name"
  rm -rf "$out" "$T/runner"; mkdir -p "$out/gh" "$T/runner"
  (
    export RUNNER_TEMP="$T/runner" RUNNER_OS=Linux RUNNER_ARCH=$ARCH
    export GITHUB_WORKSPACE=$ws GITHUB_REPOSITORY=owner/repo GITHUB_EVENT_NAME=push
    GITHUB_SHA=$(git -C "$ws" rev-parse HEAD 2>/dev/null)
    export GITHUB_REF=refs/heads/main GITHUB_SHA
    export GITHUB_STEP_SUMMARY="$out/summary.md" GH_LOG="$out/gh"
    export INPUT_MODE=check INPUT_PATH=. INPUT_FAIL_ON=confirmed INPUT_COMMENT=false INPUT_SARIF_FILE=""
    export PR_HEAD_REPO="" PR_HEAD_REF="" PR_HEAD_SHA="" PR_NUMBER=""
    for v in POLINRIDER_VERSION POLINRIDER_INDICATORS_REVIEWED POLINRIDER_SHA256_LINUX_X86_64 \
             POLINRIDER_SHA256_LINUX_ARM64 POLINRIDER_SHA256_MACOS_ARM64 POLINRIDER_SHA256_MACOS_X86_64; do
      export "$v=$(pin "$v")"
    done
    export POLINRIDER_RELEASES="file://$DIST"
    for kv in "$@"; do export "${kv?}"; done
    cd "$ws" || exit 3

    step() { # id script
      : > "$out/$1.out"
      GITHUB_OUTPUT="$out/$1.out" bash "$ACTION/scripts/$2.sh" >> "$out/log" 2>&1
      echo $? > "$out/$1.rc"
    }
    outcome() { [[ -f "$out/$1.rc" ]] || { echo skipped; return; }; [[ $(cat "$out/$1.rc") == 0 ]] && echo success || echo failure; }
    get() { sed -n "s/^$2=//p" "$out/$1.out" 2>/dev/null | tail -n 1; }

    step install install
    [[ $(outcome install) == success ]] && step scan scan
    [[ $(get scan fix-ready) == true ]] && GH_TOKEN="test" step publish publish
    PUBLISH_OUTCOME=$(outcome publish) step report report
    [[ $(get report comment-ready) == true ]] && GH_TOKEN="test" step comment comment
    VERDICT=$(get report verdict) PUBLISH_OUTCOME=$(outcome publish) step result result
  )
}
o() { sed -n "s/^$3=//p" "$T/out/$1/$2.out" 2>/dev/null | tail -n 1; }
rc() { cat "$T/out/$1/$2.rc" 2>/dev/null || echo skipped; }
sum() { cat "$T/out/$1/summary.md" 2>/dev/null; }
log() { cat "$T/out/$1/log" 2>/dev/null; }

reviewed_long=$(RUNNER_TEMP=/x bash -c ". '$ACTION/scripts/lib.sh'; long_date $(pin POLINRIDER_INDICATORS_REVIEWED)")

# ================================================================ cases

echo "== clean"
ws=$(repo clean); echo 'console.log(1)' > "$ws/index.js"; commit "$ws"
run_action clean "$ws"
check "verdict is clean" '[[ $(o clean report verdict) == clean ]]'
check "the step passes" '[[ $(rc clean result) == 0 ]]'
expected="## PolinRider Scanner: clean

Nothing found in 1 file.\\
PolinRider $VERSION, indicators last reviewed $reviewed_long."
check "the summary is the mock" '[[ "$(sum clean)" == "$expected" ]]' "$(diff <(echo "$expected") <(sum clean))"
check "the hash was checked and said" 'log clean | grep -q "SHA-256 .* matches the pin"'

echo "== review"
ws=$(repo review); mkdir -p "$ws/src"; printf 'const x = "%s";\n' "$WEAK" > "$ws/src/we:ird,name.js"; commit "$ws"
run_action review "$ws"
check "verdict is review" '[[ $(o review report verdict) == review ]]'
check "review passes with fail-on: confirmed" '[[ $(rc review result) == 0 ]]'
check "counts" '[[ $(o review report confirmed) == 0 && $(o review report review) == 1 ]]'
check "the annotation escapes : and , in the file name" \
  'log review | grep -qF "::warning file=src/we%3Aird%2Cname.js::TO REVIEW  mentions something the campaign also uses"' "$(log review | grep '::warning')"
run_action review-strict "$ws" INPUT_FAIL_ON=review
check "review fails with fail-on: review" '[[ $(rc review-strict result) == 1 ]]'

echo "== infected, check mode"
ws=$(repo infected); infected_tree "$ws"; commit "$ws"
run_action infected "$ws" INPUT_SARIF_FILE=out/polinrider.sarif
check "verdict is infected" '[[ $(o infected report verdict) == infected ]]'
check "the step fails" '[[ $(rc infected result) == 1 ]]'
check "counts" '[[ $(o infected report confirmed) == 2 && $(o infected report review) == 1 ]]'
check "annotation on vite.config.js" 'log infected | grep -qxF "::error file=vite.config.js::CONFIRMED  a build config carries the payload"'
check "annotation on .vscode/tasks.json" 'log infected | grep -qxF "::error file=.vscode/tasks.json::CONFIRMED  an editor task runs the payload when the folder opens"'
check "check mode changed nothing" '[[ -z $(git -C "$ws" status --porcelain --untracked-files=no) ]]'
check "check mode made no GitHub call" '[[ -z $(ls "$T/out/infected/gh") ]]'
check "the summary heading" 'sum infected | head -n 1 | grep -qxF "## PolinRider Scanner: infected"'
check "the summary count line" 'sum infected | grep -qxF "2 confirmed and 1 to review, in 4 files.\\"'
check "the table row" 'sum infected | grep -qxF "| CONFIRMED | a build config carries the payload | vite.config.js |"'
check "next steps point at the fix mode" 'sum infected | grep -qxF "2. Remove the payload: run this action with mode: fix, or run"'
check "SARIF is valid JSON with 3 results" '[[ $(jq ".runs[0].results | length" "$ws/out/polinrider.sarif") == 3 ]]'
check "binary output cannot issue workflow commands" 'log infected | grep -q "^::stop-commands::polinrider-"'

echo "== infected, fix mode"
ws=$(repo fix); infected_tree "$ws"; commit "$ws"; tip=$(git -C "$ws" rev-parse HEAD)
run_action fix "$ws" INPUT_MODE=fix
g="$T/out/fix/gh"
check "verdict is still infected, for the commit that was scanned" '[[ $(o fix report verdict) == infected ]]'
check "the step fails" '[[ $(rc fix result) == 1 ]]'
check "the pull request URL is an output" '[[ $(o fix publish pr-url) == https://github.com/owner/repo/pull/7 ]]'
check "branch created at the scanned commit" 'grep -lq "git/refs" "$g"/*.args && grep -h "git/refs" "$g"/*.args | grep -q "sha=$tip"'
check "no branch but its own is written" '! grep -h "ref=refs/heads/" "$g"/*.args | grep -vq "ref=refs/heads/polinrider/remove-payload-"'
mut=$(grep -l graphql "$g"/*.args | head -n 1); mut=${mut%.args}.body
check "the commit starts from the scanned commit" '[[ $(jq -r .variables.input.expectedHeadOid "$mut") == "$tip" ]]'
check "the commit cuts vite.config.js" '[[ $(jq -r ".variables.input.fileChanges.additions[0].path" "$mut") == vite.config.js ]]'
check "the cut file no longer carries the indicator" \
  '! jq -r ".variables.input.fileChanges.additions[0].contents" "$mut" | base64 -d | grep -qF "$STRONG"'
check "the commit removes .vscode/tasks.json" '[[ $(jq -r ".variables.input.fileChanges.deletions[0].path" "$mut") == .vscode/tasks.json ]]'
check "the commit headline" '[[ $(jq -r .variables.input.message.headline "$mut") == "Remove the PolinRider payload (2 files)" ]]'
pr=$(grep -l -- "-X POST repos/owner/repo/pulls" "$g"/*.args | head -n 1); pr=${pr%.args}.body
expected_body="PolinRider Scanner found the payload on main and removed it.

Cut out, the rest of the file kept:
- vite.config.js

Removed, the whole file was the payload:
- .vscode/tasks.json

Not changed, for a person to look at:
- src/app.js: mentions something the campaign also uses ($WEAK)

Before merging: check every computer that worked on this repository
(https://polinriderscanner.com/docs/guides/machine/), because the payload
came from one of them and will come back from it."
check "the pull request is the mock" '[[ "$(jq -r .body "$pr")" == "$expected_body" ]]' "$(diff <(echo "$expected_body") <(jq -r .body "$pr"))"
check "into the scanned branch" '[[ $(jq -r .base "$pr") == main ]]'
check "never merges" '! grep -qhE "pulls/[0-9]+/merge|/merges" "$g"/*.args'
check "never force-pushes, never pushes at all" '! log fix | grep -q "git push"'
check "the scanned branch did not move" '[[ $(git -C "$ws" rev-parse main) == "$tip" ]]'
check "the quarantine is outside the workspace" '[[ -d "$T/runner/polinrider-action/quarantine" ]] && [[ -z $(find "$ws" -path "$ws/.git" -prune -o -name RESTORE.txt -print) ]]'
check "the summary points at the pull request" 'sum fix | grep -qxF "   https://github.com/owner/repo/pull/7"'

echo "== fix mode on a pull request from a fork"
git -C "$ws" checkout -q -- .
run_action fork "$ws" INPUT_MODE=fix GITHUB_EVENT_NAME=pull_request PR_HEAD_REPO=someone/repo \
  PR_HEAD_REF=main PR_HEAD_SHA="$tip" PR_NUMBER=3 INPUT_COMMENT=true
check "no GitHub call at all" '[[ -z $(ls "$T/out/fork/gh") ]]'
check "the summary says why" 'sum fork | grep -qF "No pull request was opened: this pull request comes from a fork"'
check "no comment either" 'log fork | grep -qF "No comment: a pull request from a fork"'

echo "== fix mode when the checkout is not the branch tip"
git -C "$ws" checkout -q -- .
run_action merge-ref "$ws" INPUT_MODE=fix GITHUB_EVENT_NAME=pull_request PR_HEAD_REPO=owner/repo \
  PR_HEAD_REF=feature PR_HEAD_SHA=1111111111111111111111111111111111111111 PR_NUMBER=3
check "no pull request, and says why" 'sum merge-ref | grep -qF "No pull request was opened: the checkout is not the tip of the branch"'
check "no GitHub call" '[[ -z $(ls "$T/out/merge-ref/gh") ]]'

echo "== fix mode when a pull request is already open"
git -C "$ws" checkout -q -- .
run_action again "$ws" INPUT_MODE=fix GH_EXISTING='{"state":"open","url":"https://github.com/owner/repo/pull/5","merged":false}'
check "reports the open one" '[[ $(o again publish pr-url) == https://github.com/owner/repo/pull/5 ]]'
check "opens no second one" '! grep -qh -- "-X POST" "$T/out/again/gh"/*.args'

echo "== comment on a pull request"
ws2=$(repo comment); infected_tree "$ws2"; commit "$ws2"
run_action comment "$ws2" GITHUB_EVENT_NAME=pull_request PR_HEAD_REPO=owner/repo PR_NUMBER=9 INPUT_COMMENT=true
# shellcheck disable=SC2034  # read by check()
c=$(grep -l -- "-X POST repos/owner/repo/issues/9/comments" "$T/out/comment/gh"/*.args | head -n 1)
check "posts one comment carrying the summary" '[[ -n "$c" ]] && jq -r .body "${c%.args}.body" | grep -qxF "## PolinRider Scanner: infected"'
check "the comment carries the marker that finds it next time" 'jq -r .body "${c%.args}.body" | head -n 1 | grep -qxF "<!-- polinrider-action -->"'

echo "== a hash mismatch is refused"
ws=$(repo mismatch); echo x > "$ws/a.js"; commit "$ws"
PIN_VAR="POLINRIDER_SHA256_$(printf %s "$PLAT" | tr "a-z-" "A-Z_")"
bad_pin=$(printf '0%.0s' $(seq 64))
run_action mismatch "$ws" "$PIN_VAR=$bad_pin"
check "install fails" '[[ $(rc mismatch install) == 1 ]]'
check "the scan never ran" '[[ $(rc mismatch scan) == skipped ]]'
check "the archive was not unpacked" '[[ ! -e "$T/runner/polinrider-action/dist" ]]'
check "verdict is error" '[[ $(o mismatch report verdict) == error ]]'
check "fails even with fail-on: never" 'run_action mismatch2 "$ws" "$PIN_VAR=$bad_pin" INPUT_FAIL_ON=never; [[ $(rc mismatch2 result) == 1 ]]'
check "the summary says could not run and why" \
  'sum mismatch | head -n 1 | grep -qxF "## PolinRider Scanner: could not run" && sum mismatch | grep -q "does not match the SHA-256 this action pins"'

echo "== an unsupported runner"
run_action windows "$ws" RUNNER_OS=Windows RUNNER_ARCH=X64
check "refused, could not run" '[[ $(o windows report verdict) == error && $(rc windows result) == 1 ]]'

echo "== bad inputs"
run_action badmode "$ws" INPUT_MODE=delete
check "an unknown mode is refused" '[[ $(o badmode report verdict) == error ]]'

# SHOW="clean fix" prints those cases' summaries and logs, to read by eye.
for c in ${SHOW:-}; do
  printf '\n---- %s: summary\n' "$c"; sum "$c"
  printf '\n---- %s: log\n' "$c"; log "$c"
done

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
