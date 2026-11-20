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

# scans_same <name> <commit...>: after `range`, gitleaks finds a token in exactly these commits, and so does
# trufflehog, run the way action.yml runs it: the pinned image, handed the range step's base and head and the
# action's extra_args (with --no-verification, so a made-up token counts). Needs Docker; skipped without it,
# except in CI.
ACTION="$(dirname "$SCAN")/../action.yml"
TRUFFLEHOG_IMAGE="ghcr.io/trufflesecurity/trufflehog:$(awk '/trufflehog-version:/{f=1} f && /default:/{gsub(/[" ]/,"",$2); print $2; exit}' "$ACTION")"
TRUFFLEHOG_ARGS=$(sed -n 's/^ *extra_args: //p' "$ACTION" | sed 's/\${{ inputs.trufflehog-args }}/--no-verification/')
if docker info >/dev/null 2>&1 && docker pull -q "$TRUFFLEHOG_IMAGE" >/dev/null; then
  docker=true
elif [ -n "${CI:-}" ]; then
  docker=false
  fail "Docker is needed to run trufflehog"
else
  docker=false
  echo "skip trufflehog checks: no Docker"
fi
scans_same() {
  local name=$1 base head want got
  shift
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)
  got=$(env RANGE="$(output range)" bash "$SCAN" gitleaks 2>/dev/null | sed -n 's/^Commit: *//p' | sort -u || true)
  equals "$name: gitleaks" "$got" "$want"
  [ "$docker" = true ] || return 0
  base=$(output base) head=$(output head)
  if [ -z "$head" ]; then
    fail "$name: trufflehog (no head: the trufflehog action would pick its own commits)"
    return 0
  elif [ "$base" = "$head" ]; then
    fail "$name: trufflehog (base and head are the same commit, which the trufflehog action refuses)"
    return 0
  fi
  # shellcheck disable=SC2086 # extra_args is split into words, as the trufflehog action does
  got=$(docker run --rm -v "$PWD:/tmp" -w /tmp "$TRUFFLEHOG_IMAGE" git file:///tmp/ --since-commit "$base" \
    --branch "$head" --no-update --json $TRUFFLEHOG_ARGS 2>/dev/null |
    grep -oE '"commit":"[0-9a-f]+"' | cut -d'"' -f4 | sort -u || true)
  equals "$name: trufflehog" "$got" "$want"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset COMMITS EVENT PR_BASE PR_HEAD PUSH_BEFORE PUSH_AFTER PUSH_REF DEFAULT_BRANCH RUNNER_TEMP RANGE GITLEAKS TRUFFLEHOG \
  TRUFFLEHOG_ENABLED TRUFFLEHOG_VERSION PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF GITHUB_OUTPUT
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
  env "$@" bash "$SCAN" range >"$tmp/log" 2>&1 || {
    fail "range $*"
    sed 's/^/     /' "$tmp/log"
  }
}
export GITHUB_OUTPUT="$tmp/out"
range EVENT=pull_request PR_BASE="$base" PR_HEAD="$clean"
equals "pull request scans base..head" "$(output range)" "$base..$clean"
scans_same "pull request" "$leak"
range EVENT=push PUSH_BEFORE="$leak" PUSH_AFTER="$clean"
equals "push scans before..after" "$(output range)" "$leak..$clean"
scans_same "push"
range EVENT=push PUSH_BEFORE="$leak" PUSH_AFTER="$zero"
equals "deleted branch skips the scan" "$(output skip)" "true"
equals "deleted branch has no range" "$(output range)" ""
range EVENT=schedule
equals "other events scan everything" "$(output range)" "all"
range EVENT=pull_request PR_BASE="$base" PR_HEAD="$clean" COMMITS="HEAD~1..HEAD"
equals "an explicit range wins over the event" "$(output range)" "HEAD~1..HEAD"
scans_same "an explicit range: what the scanners find" # clean removes the token: nothing
range COMMITS="HEAD~2..HEAD"
scans_same "an explicit range of names" "$leak"
range COMMITS="HEAD~1..HEAD
" # a YAML | block ends the value with a newline
equals "a commits value's trailing newline is dropped" "$(output range)" "HEAD~1..HEAD"
expect "a commits value over several lines is refused" 1 env COMMITS="HEAD~2..HEAD~1
HEAD~1..HEAD" bash "$SCAN" range
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
git checkout -q -b feature
token >leak.txt && git add leak.txt && git commit -q -m leak
fleak=$(git rev-parse HEAD)
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
scans_same "new branch" "$fleak"
equals "new branch with new commits does not skip" "$(output skip)" ""
expect "new branch: gitleaks refuses a token below its tip" 1 env RANGE="$(output range)" bash "$SCAN" gitleaks
new fresh refs/heads/fresh
equals "new branch off main's tip scans only its own commit" "$(output range)" "$m1..$c1"
expect "new branch: gitleaks does not judge main's commits" 0 env RANGE="$(output range)" bash "$SCAN" gitleaks
scans_same "new branch off main's tip"
new merged refs/heads/merged
equals "new branch with a merge of main scans past the merge" "$(output range)" "$m1..$merged"
scans_same "new branch with a merge of main" "$fleak"
expect "new branch with a merge of main: gitleaks refuses the merged-in token" 1 \
  env RANGE="$(output range)" bash "$SCAN" gitleaks
new nothing-new refs/heads/nothing-new
equals "new branch with no new commits skips the scan" "$(output skip)" "true"
equals "new branch with no new commits has no range" "$(output range)" ""
new main refs/tags/v9
equals "new tag on a commit main has skips the scan" "$(output skip)" "true"
new v8 refs/tags/v8 PUSH_AFTER="$v8"
equals "new annotated tag off main scans its commits main doesn't have" "$(output range)" "$m1..$fclean"
scans_same "new annotated tag off main" "$fleak"
equals "new annotated tag off main does not skip" "$(output skip)" ""
cd "$nb/work" # a full checkout: fetching a missing commit there is not an error by itself
expect "new branch whose commit can't be found is refused, not skipped" 1 \
  env EVENT=push PUSH_BEFORE="$zero" PUSH_AFTER=1234567890123456789012345678901234567890 \
  PUSH_REF=refs/heads/gone DEFAULT_BRANCH=main bash "$SCAN" range
new main refs/heads/main
equals "new default branch scans its whole history" "$(output range)" "$m1"
scans_same "new default branch" "$m1"
expect "new default branch: gitleaks refuses a token in its history" 1 env RANGE="$(output range)" bash "$SCAN" gitleaks
new main ""
equals "new default branch with no ref named scans its whole history" "$(output range)" "$m1"
new fresh refs/heads/fresh DEFAULT_BRANCH=gone
equals "new branch when the default branch is missing scans its whole history" "$(output range)" "$c1"
new fresh refs/heads/fresh DEFAULT_BRANCH=
equals "new branch with no default branch named scans its whole history" "$(output range)" "$c1"

# --- trufflehog scans exactly gitleaks' commits, where its own rules would differ
# trufflehog walks back from one commit (head) and stops at the merge base of head and base, and with no head
# the trufflehog action picks commits by event. A remote whose main and branch cc have two merge bases (x1 and
# y1, from a criss-cross merge), and a branch "other" that a checkout only has as a remote-tracking branch:
#   main   o <- x1 (token) <- a = merge of x1 and y1
#   cc     o <- y1 (token) <- b = merge of y1 and x1 <- c (token)
#   other  o <- t (token)
cc="$tmp/cc"
git init -q --bare "$cc/remote.git"
git init -q "$cc/work"
cd "$cc/work"
git remote add origin "$cc/remote.git"
git checkout -q -b main
echo o >o.txt && git add o.txt && git commit -q -m o
o=$(git rev-parse HEAD)
token >x.txt && git add x.txt && git commit -q -m x1
x1=$(git rev-parse HEAD)
git checkout -q -b cc "$o"
token >y.txt && git add y.txt && git commit -q -m y1
y1=$(git rev-parse HEAD)
git merge -q --no-ff -m b "$x1"
token >c.txt && git add c.txt && git commit -q -m c
c=$(git rev-parse HEAD)
git checkout -q main
git merge -q --no-ff -m a "$y1"
a=$(git rev-parse HEAD)
git checkout -q -b other "$o"
token >t.txt && git add t.txt && git commit -q -m t
t=$(git rev-parse HEAD)
git push -q origin main cc other
git fetch -q origin
git checkout -q cc
git branch -q -D other
range EVENT=pull_request PR_BASE="$a" PR_HEAD="$c"
scans_same "pull request whose base and head have two merge bases" "$c"
range EVENT=push PUSH_BEFORE="$a" PUSH_AFTER="$c"
scans_same "push from a commit with two merge bases" "$c"
range EVENT=schedule
scans_same "schedule: every branch, remote-tracking ones too" "$x1" "$y1" "$c" "$t"
range EVENT=pull_request PR_BASE="$a" PR_HEAD="$c" COMMITS=all
scans_same "commits all on a pull request: the whole history, not the pull request" "$x1" "$y1" "$c" "$t"
range COMMITS="$a...$c"
scans_same "commits a...b: either side, not both" "$c"
range COMMITS="$x1"
scans_same "commits naming one commit: its history" "$x1"
range COMMITS="$a.."
scans_same "commits a..: up to the checked-out commit" "$c"
range COMMITS="HEAD..HEAD"
scans_same "commits HEAD..HEAD: nothing"
cd "$cc" && rm -rf "$cc/checkout"
git -c advice.detachedHead=false clone -q --depth 1 --branch cc "file://$cc/remote.git" "$cc/checkout"
cd "$cc/checkout"
range EVENT=push PUSH_BEFORE="$zero" PUSH_AFTER="$c" PUSH_REF=refs/heads/cc DEFAULT_BRANCH=main
scans_same "new branch with two merge bases" "$c"
cd "$cc/work"
git checkout -q --detach
token >h.txt && git add h.txt && git commit -q -m h
h=$(git rev-parse HEAD)
range EVENT=schedule
scans_same "schedule: a commit only HEAD has" "$x1" "$y1" "$c" "$t" "$h"
git tag blob-tag "$(echo blob | git hash-object -w --stdin)" # a tag that is not on a commit is passed over
range EVENT=schedule SECRET_SCAN_MERGE_WIDTH=2 # head joins the commits to scan two at a time, as with many refs
scans_same "schedule: many refs, one of them on a blob" "$x1" "$y1" "$c" "$t" "$h"
git checkout -q cc
range COMMITS="HEAD --not main"
scans_same "commits HEAD --not main" "$c"
range COMMITS="^main"
scans_same "commits that only exclude: nothing"
range COMMITS="--topo-order HEAD --"
scans_same "commits with an order and a bare --: its history" "$x1" "$y1" "$c"
expect "a width below 2 still joins the commits to scan" 0 env SECRET_SCAN_MERGE_WIDTH=1 bash "$SCAN" range
env COMMITS="nosuch..HEAD" bash "$SCAN" range >"$tmp/log" 2>&1 || true
if grep -q "^::error::.*nosuch" "$tmp/log" && ! grep -q "trufflehog: false" "$tmp/log"; then pass "a name the checkout lacks is named"; else
  fail "a name the checkout lacks is named"
  sed 's/^/     /' "$tmp/log"
fi
# trufflehog can only be handed a set of commits that git revisions name (A..B, A...B, ^A, --all); a commits
# value that filters them (by date, count or path) is refused rather than scanned differently.
cd "$cc/work"
expect "commits filtered by date is refused while trufflehog is on" 1 env COMMITS="--since=2000-01-01 HEAD" bash "$SCAN" range
expect "commits without merges is refused while trufflehog is on" 1 env COMMITS="HEAD --no-merges" bash "$SCAN" range
expect "commits filtered by path is refused while trufflehog is on" 1 env COMMITS="HEAD x.txt" bash "$SCAN" range
git tag -a -m t1 t1 "$x1"
range COMMITS=t1
scans_same "commits naming an annotated tag: its commit's history" "$x1"
expect "a trufflehog older than the one these tests run is refused" 1 env TRUFFLEHOG_VERSION=3.88.0 bash "$SCAN" range
expect "an older trufflehog with a v is refused" 1 env TRUFFLEHOG_VERSION=v3.0.0 bash "$SCAN" range
expect "an older trufflehog with a suffix is refused" 1 env TRUFFLEHOG_VERSION=3.88.0-rc1 bash "$SCAN" range
expect "a newer trufflehog is accepted" 0 env TRUFFLEHOG_VERSION=3.100.0 bash "$SCAN" range
expect "the pinned trufflehog is accepted" 0 env TRUFFLEHOG_VERSION="${TRUFFLEHOG_IMAGE##*:}" bash "$SCAN" range
expect "commits filtered by date is gitleaks' alone with trufflehog off" 0 \
  env COMMITS="--since=2000-01-01 HEAD" TRUFFLEHOG_ENABLED=false bash "$SCAN" range
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
