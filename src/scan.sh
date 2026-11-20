#!/usr/bin/env bash
# Steps of the Secret Scan action (action.yml). Inputs arrive as env vars.
#   range    work out which commits to scan, fetch their history, and set the step's outputs
#   gitleaks install the pinned gitleaks (checksum checked) and scan RANGE
#   verdict  fail if either scanner failed, so both always run and every finding shows in one run
# Hook modes (.pre-commit-hooks.yaml), run from the root of the repository being committed to:
#   staged   scan the staged changes with gitleaks (pre-commit)
#   push     scan the commits being pushed with gitleaks (pre-push)
set -euo pipefail

GITLEAKS_VERSION=8.30.1

out() { echo "$1=$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }

cmd_range() {
  local zero=0000000000000000000000000000000000000000 range base="" head="" new=""
  range=$(printf '%s' "${COMMITS:-}") # drops the newline a YAML | block ends with
  # One line: it is handed on as a step output, and gitleaks and trufflehog would each read a second line differently.
  [[ "$range" == *$'\n'* ]] && error "commits must be on one line: '$range'"
  if [ -z "$range" ]; then
    case "${EVENT:-}" in
      pull_request | pull_request_target) range="$PR_BASE..$PR_HEAD" ;;
      push)
        if [ -z "${PUSH_AFTER:-}" ] || [ "$PUSH_AFTER" = "$zero" ]; then
          echo "Branch deleted: nothing to scan."
          out skip true
          return 0
        elif [ -z "${PUSH_BEFORE:-}" ] || [ "$PUSH_BEFORE" = "$zero" ]; then
          new=true range="$PUSH_AFTER" # new branch: worked out below, once fetched
        else
          range="$PUSH_BEFORE..$PUSH_AFTER"
        fi
        ;;
      *) range=all ;;
    esac
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
  if [ -n "$new" ]; then
    new_branch_range
    [ -z "$range" ] && return 0
  fi
  [ "${TRUFFLEHOG_ENABLED:-true}" = true ] && trufflehog_ends
  echo "Scanning: $range"
  out range "$range"
  out base "$base"
  out head "$head"
}

# A push that created a branch (or tag) at PUSH_AFTER: scan its commits that the default branch doesn't have
# yet (the pre-push hook skips what any remote branch has; this is stricter). Sets range, or range="" (and skip) when there is
# nothing new. The default branch itself (a first push), or no default branch to compare with, scans the
# whole history: there is nothing to trust yet.
new_branch_range() {
  local default="${DEFAULT_BRANCH:-}" tip="" after
  # A tag push reports the annotated tag's own id; scanners want its commit. A commit that can't be found
  # fails here rather than reading as "nothing new".
  if ! after=$(git rev-parse -q --verify "$PUSH_AFTER^{commit}"); then
    echo "::error::secret-scan: the pushed commit $PUSH_AFTER is not in this checkout"
    exit 1
  fi
  # Without PUSH_REF the default branch's own push can't be told apart, so it falls to the whole history.
  if [ -n "$default" ] && [ -n "${PUSH_REF:-}" ] && [ "$PUSH_REF" != "refs/heads/$default" ] &&
    git fetch -q --no-tags origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    tip=$(git rev-parse -q --verify "refs/remotes/origin/$default^{commit}" || true)
  fi
  if [ -z "$tip" ]; then
    echo "New branch with no default branch to compare with: scanning its whole history."
    range="$after"
    return 0
  fi
  local first
  first=$(git rev-list -1 "$tip..$after") # on its own line, so a git error stops the scan
  if [ -z "$first" ]; then
    echo "New branch with no commits that $default doesn't have (at $tip): nothing to scan."
    out skip true
    range=""
    return 0
  fi
  range="$tip..$after"
}

# Set base and head for trufflehog so that it scans exactly the commits gitleaks scans for RANGE. trufflehog
# (TRUFFLEHOG_MIN and later) scans what git lists for "head ^base", with base swapped for the merge base of head
# and base. That is not RANGE's set when RANGE has more than one start or end (all, a...b) or its ends have two
# merge bases (a criss-cross merge). So head is a new merge of RANGE's starting commits and base, and base is
# RANGE's one stopping commit, or a new merge of several: walking back from head to base visits exactly RANGE's
# commits, plus the new merges, which change no files. They are only objects in this checkout, under no branch,
# so trufflehog scans it in place (action.yml's --trust-local-git-config) rather than a clone that would leave
# them out. A RANGE that filters commits (by date, count, author or path) can't be handed over this way, and is
# refused.
TRUFFLEHOG_MIN=3.99.9
trufflehog_ends() {
  local version=${TRUFFLEHOG_VERSION:-$TRUFFLEHOG_MIN}
  older_than "$version" "$TRUFFLEHOG_MIN" &&
    error "trufflehog-version $version is older than $TRUFFLEHOG_MIN, the oldest that can be handed exactly the commits gitleaks scans"
  local words=() revs starts stops err others
  if [ "$range" = all ]; then
    words=(--all HEAD) # gitleaks' whole-history scan is git log --all, which includes HEAD
  else
    read -ra words <<<"$range" # split on spaces, as gitleaks splits --log-opts
  fi
  # rev-parse passes over a name it can't find, so ask rev-list, which names it.
  err=$(git rev-list -n 1 "${words[@]}" 2>&1 >/dev/null) || error "commits '$range': $(head -1 <<<"$err")"
  revs=$(git rev-parse --revs-only "${words[@]}")
  # Options that filter commits (--max-age=, --no-merges) and paths are what's left besides the revisions and
  # options that only order them.
  others=$(grep -vx -e '--topo-order' -e '--date-order' -e '--author-date-order' -e '--reverse' <<<"$revs" | grep '^-' || true)
  others+=$(git rev-parse --no-revs "${words[@]}" | { grep -vx -e '--' || true; })
  if [ -n "$others" ]; then
    error "trufflehog can't scan exactly the commits '$range' selects: give commits as git revisions or ranges (such as main..HEAD), or set trufflehog: false"
  fi
  # Each revision as a commit, an annotated tag peeled. A tag on a blob or tree has no commits: passed over, as git log does.
  starts=$({ grep -v '^\^' <<<"$revs" || true; } | as_commits)
  stops=$(sed -n 's/^\^//p' <<<"$revs" | as_commits)
  base=""
  if [ "$(grep -c . <<<"$stops")" -gt 1 ]; then
    base=$(merge_all <<<"$stops")
  else
    base=$stops
  fi
  head=$(printf '%s\n' "$starts" "$base" | merge_all)
}

error() {
  echo "::error::secret-scan: $1"
  exit 1
}

# older_than <version> <minimum>: true when version (such as 3.88.0, v3.88.0 or 3.88.0-rc1) is below minimum.
# A tag that isn't a version (latest) is not judged.
older_than() {
  local v=${1#v} i a=() b=()
  v=${v%%-*}
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -ra a <<<"$v"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    [ "$((10#${a[i]}))" -lt "${b[i]}" ] && return 0
    [ "$((10#${a[i]}))" -gt "${b[i]}" ] && return 1
  done
  return 1
}

# as_commits: the commit each object id on stdin peels to, one per line; objects that aren't commits (a tag on a
# blob, which cat-file reports as missing) are left out. Any other git failure stops the scan.
as_commits() {
  sed '/^$/d; s/$/^{commit}/' | git cat-file --batch-check='%(objectname)' | { grep -v ' missing$' || true; }
}

# merge_all: one new commit that has every commit on stdin (duplicates dropped) as an ancestor, joining at most
# SECRET_SCAN_MERGE_WIDTH (at least 2) at a time so that a repository with many refs stays within the command
# line's limit. Command substitution turns set -e off, so each step checks its own failure.
merge_all() {
  local list line width=${SECRET_SCAN_MERGE_WIDTH:-1000}
  [ "$width" -ge 2 ] || width=2
  list=$(awk 'NF && !seen[$0]++') || return 1
  while [ "$(grep -c . <<<"$list")" -gt "$width" ]; do
    # shellcheck disable=SC2086 # each line holds up to $width commit ids
    list=$(xargs -n "$width" <<<"$list" | while read -r line; do empty_merge $line || exit 1; done) || return 1
  done
  # shellcheck disable=SC2086
  empty_merge $list
}

# empty_merge <commit...>: a new commit with these parents and its first parent's files (so it changes nothing),
# under no branch.
empty_merge() {
  local tree parents=() sha
  if [ $# -gt 0 ]; then tree=$(git rev-parse "$1^{tree}") || return 1; else tree=$(git mktree </dev/null) || return 1; fi
  for sha in "$@"; do parents+=(-p "$sha"); done
  GIT_AUTHOR_NAME=secret-scan GIT_AUTHOR_EMAIL=secret-scan@invalid \
    GIT_COMMITTER_NAME=secret-scan GIT_COMMITTER_EMAIL=secret-scan@invalid \
    git commit-tree "$tree" ${parents[@]+"${parents[@]}"} -m "secret-scan: the commits to scan"
}

# Install the pinned gitleaks once into a cache directory (checksum checked) and set GITLEAKS to its path.
install_gitleaks() {
  local os arch sum
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) os=linux arch=x64 sum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    Linux-aarch64 | Linux-arm64) os=linux arch=arm64 sum=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    Darwin-arm64) os=darwin arch=arm64 sum=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    Darwin-x86_64) os=darwin arch=x64 sum=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    *) echo "::error::secret-scan: no gitleaks build for $(uname -s) $(uname -m)"; exit 1 ;;
  esac
  local dir
  if [ -n "${RUNNER_TEMP:-}" ]; then
    dir="$RUNNER_TEMP/secret-scan-gitleaks-$GITLEAKS_VERSION"
  else
    dir="${XDG_CACHE_HOME:-$HOME/.cache}/kilotronic-secret-scan/gitleaks-$GITLEAKS_VERSION"
  fi
  GITLEAKS="$dir/gitleaks"
  if [ ! -x "$GITLEAKS" ]; then
    mkdir -p "$dir"
    local tgz tmp
    tgz=$(mktemp "$dir/gitleaks.tar.gz.XXXXXX")
    tmp=$(mktemp -d "$dir/extract.XXXXXX")
    curl -sSfL -o "$tgz" \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
    if command -v sha256sum >/dev/null; then
      echo "$sum  $tgz" | sha256sum -c - >/dev/null
    else
      echo "$sum  $tgz" | shasum -a 256 -c - >/dev/null
    fi
    tar -xzf "$tgz" -C "$tmp" gitleaks
    mv -f "$tmp/gitleaks" "$GITLEAKS" # atomic, so two hooks running at once never see half a file
    rm -rf "$tgz" "$tmp"
  fi
}

cmd_gitleaks() {
  install_gitleaks
  local opts=()
  [ "${RANGE:?}" != all ] && opts=(--log-opts="$RANGE")
  "$GITLEAKS" git --no-banner --redact --verbose ${opts[@]+"${opts[@]}"} .
}

cmd_staged() {
  install_gitleaks
  "$GITLEAKS" git --no-banner --redact --verbose --pre-commit --staged .
}

cmd_push() {
  # pre-commit and prek set these for the pre-push stage. A new branch has no remote commit to start
  # from, so scan its commits that no remote has yet.
  local zero=0000000000000000000000000000000000000000 from="${PRE_COMMIT_FROM_REF:-}" to="${PRE_COMMIT_TO_REF:-HEAD}"
  local opts
  if [ -n "$from" ] && [ "$from" != "$zero" ]; then
    opts="$from..$to"
  else
    opts="$to --not --remotes"
  fi
  install_gitleaks
  echo "secret-scan: scanning $opts"
  "$GITLEAKS" git --no-banner --redact --verbose --log-opts="$opts" .
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

"cmd_${1:?usage: scan.sh range|gitleaks|verdict|staged|push}"
