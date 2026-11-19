#!/usr/bin/env bash
# Steps of the Secret Scan action (action.yml). Inputs arrive as env vars.
#   range    work out which commits to scan, fetch their history, and set the step's outputs
#   gitleaks install the pinned gitleaks (checksum checked) and scan RANGE
#   verdict  fail if either scanner failed, so both always run and every finding shows in one run
set -euo pipefail

GITLEAKS_VERSION=8.30.1

out() { echo "$1=$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }

cmd_range() {
  local zero=0000000000000000000000000000000000000000 range="${COMMITS:-}" base="" head=""
  if [ -z "$range" ]; then
    case "${EVENT:-}" in
      pull_request | pull_request_target)
        range="$PR_BASE..$PR_HEAD" base="$PR_BASE" head="$PR_HEAD" ;;
      push)
        if [ -z "${PUSH_AFTER:-}" ] || [ "$PUSH_AFTER" = "$zero" ]; then
          echo "Branch deleted: nothing to scan."
          out skip true
          return 0
        elif [ -z "${PUSH_BEFORE:-}" ] || [ "$PUSH_BEFORE" = "$zero" ]; then
          range="$PUSH_AFTER^!" head="$PUSH_AFTER" # new branch: its tip
        else
          range="$PUSH_BEFORE..$PUSH_AFTER" base="$PUSH_BEFORE" head="$PUSH_AFTER"
        fi
        ;;
      *) range=all ;;
    esac
  elif [[ "$range" == *..* && "$range" != *...* ]]; then
    base="${range%%..*}" head="${range##*..}"
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "::error::secret-scan needs a checkout (run actions/checkout first)"
    exit 1
  fi
  # Scanners read file contents, so a shallow checkout (the actions/checkout default) gets its history.
  local shas=() # (no mapfile: macOS runners ship bash 3.2)
  while read -r sha; do shas+=("$sha"); done < <(grep -oE '[0-9a-f]{40}' <<<"$range" || true)
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch -q --no-tags --unshallow origin ${shas[@]+"${shas[@]}"}
  elif [ "${#shas[@]}" -gt 0 ]; then
    git fetch -q --no-tags origin "${shas[@]}" || true # already present on a full checkout
  fi
  # Resolve names like HEAD~2 now: trufflehog runs in a container and gets plain commit ids.
  [ -n "$base" ] && base=$(git rev-parse "$base")
  [ -n "$head" ] && head=$(git rev-parse "$head")
  echo "Scanning: $range"
  out range "$range"
  out base "$base"
  out head "$head"
}

cmd_gitleaks() {
  local os arch sum
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) os=linux arch=x64 sum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    Linux-aarch64 | Linux-arm64) os=linux arch=arm64 sum=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    Darwin-arm64) os=darwin arch=arm64 sum=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    Darwin-x86_64) os=darwin arch=x64 sum=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    *) echo "::error::secret-scan: no gitleaks build for $(uname -s) $(uname -m)"; exit 1 ;;
  esac
  local dir="${RUNNER_TEMP:-/tmp}/secret-scan-gitleaks-$GITLEAKS_VERSION"
  if [ ! -x "$dir/gitleaks" ]; then
    mkdir -p "$dir"
    local tgz="$dir/gitleaks.tar.gz"
    curl -sSfL -o "$tgz" \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
    if command -v sha256sum >/dev/null; then
      echo "$sum  $tgz" | sha256sum -c - >/dev/null
    else
      echo "$sum  $tgz" | shasum -a 256 -c - >/dev/null
    fi
    tar -xzf "$tgz" -C "$dir" gitleaks
    rm "$tgz"
  fi
  local opts=()
  [ "${RANGE:?}" != all ] && opts=(--log-opts="$RANGE")
  "$dir/gitleaks" git --no-banner --redact --verbose ${opts[@]+"${opts[@]}"} .
}

cmd_verdict() {
  local failed=()
  [ "${GITLEAKS:-}" = failure ] && failed+=(gitleaks)
  [ "${TRUFFLEHOG:-}" = failure ] && failed+=(trufflehog)
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "::error::secret-scan: ${failed[*]} found something (see the steps above)"
    exit 1
  fi
  echo "secret-scan: nothing found (gitleaks: ${GITLEAKS:-off}, trufflehog: ${TRUFFLEHOG:-off})"
}

"cmd_${1:?usage: scan.sh range|gitleaks|verdict}"
