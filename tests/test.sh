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
unset COMMITS EVENT PR_BASE PR_HEAD PUSH_BEFORE PUSH_AFTER RUNNER_TEMP RANGE GITLEAKS TRUFFLEHOG \
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
range EVENT=push PUSH_BEFORE="$zero" PUSH_AFTER="$clean"
equals "new branch scans only its tip" "$(output range)" "$clean^!"
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
