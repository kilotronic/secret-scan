#!/usr/bin/env bash
# Tests for src/scan.sh, run against throwaway git repositories: which commits each event scans, that the
# verdict fails when either scanner did, and that the hooks refuse a fake token (and pass a clean change).
# Run: bash tests/test.sh   (downloads the pinned gitleaks once, like the hooks do)
set -euo pipefail

SCAN="$(cd "$(dirname "$0")/.." && pwd)/src/scan.sh"
fails=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
# expect <name> <0|1> <command...>: the command must succeed (0) or fail (1).
expect() {
  local name=$1 want=$2 got=0
  shift 2
  "$@" >"$tmp/log" 2>&1 || got=1
  if [ "$got" = "$want" ]; then pass "$name"; else
    fail "$name"
    sed 's/^/     /' "$tmp/log"
  fi
}
# output <key>: a value scan.sh range wrote to GITHUB_OUTPUT.
output() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1; }
equals() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
token() { echo "token = ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset COMMITS EVENT PR_BASE PR_HEAD PUSH_BEFORE PUSH_AFTER PUSH_REF DEFAULT_BRANCH RUNNER_TEMP RANGE GITLEAKS TRUFFLEHOG \
  PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF GITHUB_OUTPUT
# The pinned gitleaks goes to a cache inside this run, not the user's ~/.cache.
export XDG_CACHE_HOME="$tmp/xdg-cache"

# A remote with one clean commit, and a clone with a leak commit then a clean commit on top.
git init -q --bare "$tmp/remote.git"
git init -q "$tmp/repo"
cd "$tmp/repo"
git remote add origin "$tmp/remote.git"
echo hello >a.txt && git add a.txt && git commit -q -m base
git push -q origin HEAD:refs/heads/main
base=$(git rev-parse HEAD)
token >leak.txt && git add leak.txt && git commit -q -m leak
leak=$(git rev-parse HEAD)
git rm -q leak.txt && echo more >b.txt && git add b.txt && git commit -q -m clean
clean=$(git rev-parse HEAD)
zero=0000000000000000000000000000000000000000

# --- range: which commits each event scans
range() {
  : >"$GITHUB_OUTPUT"
  env "$@" bash "$SCAN" range >/dev/null
}
export GITHUB_OUTPUT="$tmp/out"
range EVENT=pull_request PR_BASE="$base" PR_HEAD="$clean"
equals "pull request scans base..head" "$(output range)" "$base..$clean"
equals "pull request base output" "$(output base)" "$base"
equals "pull request head output" "$(output head)" "$clean"
range EVENT=push PUSH_BEFORE="$leak" PUSH_AFTER="$clean"
equals "push scans before..after" "$(output range)" "$leak..$clean"
range EVENT=push PUSH_BEFORE="$leak" PUSH_AFTER="$zero"
equals "deleted branch skips the scan" "$(output skip)" "true"
equals "deleted branch has no range" "$(output range)" ""
range EVENT=schedule
equals "other events scan everything" "$(output range)" "all"
range EVENT=pull_request PR_BASE="$base" PR_HEAD="$clean" COMMITS="HEAD~1..HEAD"
equals "an explicit range wins over the event" "$(output range)" "HEAD~1..HEAD"
equals "an explicit range resolves base to a commit id" "$(output base)" "$leak"
equals "an explicit range resolves head to a commit id" "$(output head)" "$clean"
cd "$tmp" # outside any checkout; not a subshell, so a failure is counted
expect "range outside a checkout is refused" 1 env EVENT=schedule bash "$SCAN" range
cd "$tmp/repo"

# --- range on a new branch: its commits that the default branch doesn't have yet, from a shallow checkout
# A remote whose main is m0 <- m1 (m1 holds an old token main already has), and branches:
#   feature  m0 <- leak <- fclean       merged  feature + a merge of main       fresh  m1 <- c1 (clean)
nb="$tmp/nb"
git init -q --bare "$nb/remote.git"
git init -q "$nb/work"
cd "$nb/work"
git remote add origin "$nb/remote.git"
git checkout -q -b main
echo hello >a.txt && git add a.txt && git commit -q -m m0
m0=$(git rev-parse HEAD)
git checkout -q -b feature
token >leak.txt && git add leak.txt && git commit -q -m leak
git rm -q leak.txt && echo more >b.txt && git add b.txt && git commit -q -m fclean
fclean=$(git rev-parse HEAD)
git checkout -q main
token >old.txt && git add old.txt && git commit -q -m m1
m1=$(git rev-parse HEAD)
git checkout -q -b fresh
echo fine >c.txt && git add c.txt && git commit -q -m c1
c1=$(git rev-parse HEAD)
git checkout -q -b merged feature
git merge -q --no-ff -m merge main
merged=$(git rev-parse HEAD)
git tag -a -m v8 v8 "$fclean"
v8=$(git rev-parse v8) # the annotated tag's own id, which a tag push reports as its "after"
git push -q origin main feature fresh merged v8 "$m1:refs/heads/nothing-new" "$m1:refs/tags/v9"
# new <branch> <ref> [VAR=value...]: a shallow checkout of <branch> (actions/checkout's default), then the
# range for the push that created <ref> at that branch's tip.
new() {
  local branch=$1 ref=$2
  shift 2
  cd "$nb" && rm -rf "$nb/checkout"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$branch" "file://$nb/remote.git" "$nb/checkout"
  cd "$nb/checkout"
  range EVENT=push PUSH_BEFORE="$zero" PUSH_AFTER="$(git rev-parse HEAD)" PUSH_REF="$ref" DEFAULT_BRANCH=main "$@"
}
new feature refs/heads/feature
equals "new branch scans its commits main doesn't have" "$(output range)" "$m1..$fclean"
equals "new branch gives trufflehog the merge base" "$(output base)" "$m0"
equals "new branch head output" "$(output head)" "$fclean"
equals "new branch with new commits does not skip" "$(output skip)" ""
expect "new branch: gitleaks refuses a token below its tip" 1 env RANGE="$(output range)" bash "$SCAN" gitleaks
new fresh refs/heads/fresh
equals "new branch off main's tip scans only its own commit" "$(output range)" "$m1..$c1"
expect "new branch: gitleaks does not judge main's commits" 0 env RANGE="$(output range)" bash "$SCAN" gitleaks
new merged refs/heads/merged
equals "new branch with a merge of main scans past the merge" "$(output range)" "$m1..$merged"
equals "new branch with a merge of main: merge base" "$(output base)" "$m1"
expect "new branch with a merge of main: gitleaks refuses the merged-in token" 1 \
  env RANGE="$(output range)" bash "$SCAN" gitleaks
new nothing-new refs/heads/nothing-new
equals "new branch with no new commits skips the scan" "$(output skip)" "true"
equals "new branch with no new commits has no range" "$(output range)" ""
new main refs/tags/v9
equals "new tag on a commit main has skips the scan" "$(output skip)" "true"
new v8 refs/tags/v8 PUSH_AFTER="$v8"
equals "new annotated tag off main scans its commits main doesn't have" "$(output range)" "$m1..$fclean"
equals "new annotated tag gives trufflehog a commit as head" "$(output head)" "$fclean"
equals "new annotated tag off main does not skip" "$(output skip)" ""
cd "$nb/work" # a full checkout: fetching a missing commit there is not an error by itself
expect "new branch whose commit can't be found is refused, not skipped" 1 \
  env EVENT=push PUSH_BEFORE="$zero" PUSH_AFTER=1234567890123456789012345678901234567890 \
  PUSH_REF=refs/heads/gone DEFAULT_BRANCH=main bash "$SCAN" range
new main refs/heads/main
equals "new default branch scans its whole history" "$(output range)" "$m1"
equals "new default branch: trufflehog gets no base" "$(output base)" ""
equals "new default branch: head output" "$(output head)" "$m1"
expect "new default branch: gitleaks refuses a token in its history" 1 env RANGE="$(output range)" bash "$SCAN" gitleaks
new main ""
equals "new default branch with no ref named scans its whole history" "$(output range)" "$m1"
new fresh refs/heads/fresh DEFAULT_BRANCH=gone
equals "new branch when the default branch is missing scans its whole history" "$(output range)" "$c1"
new fresh refs/heads/fresh DEFAULT_BRANCH=
equals "new branch with no default branch named scans its whole history" "$(output range)" "$c1"
cd "$tmp/repo"
unset GITHUB_OUTPUT

# --- verdict: fails when either scanner failed
expect "verdict passes when both scanners passed" 0 env GITLEAKS=success TRUFFLEHOG=success bash "$SCAN" verdict
expect "verdict passes when both scanners were off" 0 env bash "$SCAN" verdict
expect "verdict fails when gitleaks found something" 1 env GITLEAKS=failure TRUFFLEHOG=success bash "$SCAN" verdict
expect "verdict fails when trufflehog found something" 1 env GITLEAKS=success TRUFFLEHOG=failure bash "$SCAN" verdict
expect "verdict fails when both found something" 1 env GITLEAKS=failure TRUFFLEHOG=failure bash "$SCAN" verdict

# --- gitleaks over a range
expect "gitleaks passes a clean range" 0 env RANGE="$leak..$clean" bash "$SCAN" gitleaks
expect "gitleaks refuses a range with a token" 1 env RANGE="$base..$leak" bash "$SCAN" gitleaks
expect "gitleaks over all history refuses the old token" 1 env RANGE=all bash "$SCAN" gitleaks

# --- pre-push hook
expect "push hook passes clean pushed commits" 0 env PRE_COMMIT_FROM_REF="$leak" PRE_COMMIT_TO_REF="$clean" bash "$SCAN" push
expect "push hook refuses a pushed token" 1 env PRE_COMMIT_FROM_REF="$base" PRE_COMMIT_TO_REF="$clean" bash "$SCAN" push
expect "push hook on a new branch refuses a token no remote has" 1 env PRE_COMMIT_FROM_REF="$zero" PRE_COMMIT_TO_REF="$clean" bash "$SCAN" push
git push -q origin "$clean:refs/heads/main"
expect "push hook on a new branch skips commits a remote has" 0 env PRE_COMMIT_FROM_REF="$zero" PRE_COMMIT_TO_REF="$clean" bash "$SCAN" push

# --- pre-commit hook
echo fine >c.txt && git add c.txt
expect "commit hook passes a clean staged change" 0 bash "$SCAN" staged
token >leak2.txt && git add leak2.txt
expect "commit hook refuses a staged token" 1 bash "$SCAN" staged
token >unstaged.txt && git rm -q --cached leak2.txt
expect "commit hook ignores unstaged files" 0 bash "$SCAN" staged

# --- gitleaks download: a tarball whose checksum does not match is never installed or run
mkdir -p "$tmp/fakebin" "$tmp/fake"
printf '#!/bin/sh\nexit 0\n' >"$tmp/fake/gitleaks" && chmod +x "$tmp/fake/gitleaks"
tar -czf "$tmp/fake.tgz" -C "$tmp/fake" gitleaks
cat >"$tmp/fakebin/curl" <<CURL
#!/bin/sh
while [ "\$1" != -o ]; do shift; done
cp "$tmp/fake.tgz" "\$2"
CURL
chmod +x "$tmp/fakebin/curl"
expect "a gitleaks download with the wrong checksum is refused" 1 \
  env PATH="$tmp/fakebin:$PATH" XDG_CACHE_HOME="$tmp/cache" bash "$SCAN" staged
if [ -e "$tmp/cache/kilotronic-secret-scan/gitleaks-$(sed -n 's/^GITLEAKS_VERSION=//p' "$SCAN")/gitleaks" ]; then fail "the bad download was installed"; else pass "the bad download was not installed"; fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
