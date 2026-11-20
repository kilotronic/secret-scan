# secret-scan

A GitHub Action that scans **only the commits a pull request or push brings in** for secrets, with two
scanners:

- **gitleaks** fails on anything *shaped like* a secret: keys, tokens, passwords in config. It is
  installed at a pinned version and its download checksum is checked.
- **trufflehog** tries each key it finds against its service and, by default, fails only on a key that
  **still works**. It runs at a pinned image version, not `latest`.

Both always run, so one run shows every finding; the job fails if either found something. Older history
is never judged, so secrets that were already in the history (and have been rotated) don't fail every
new pull request.

## Use

```yaml
on: [pull_request]
permissions:
  contents: read
jobs:
  secret-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: kilotronic/secret-scan@v1   # pin a commit SHA in production
```

The default shallow checkout is fine: the action fetches the history it needs. trufflehog runs in
Docker, so use a Linux runner with Docker (GitHub's `ubuntu-latest` has it), or set `trufflehog: false`.

Which commits it scans by default (both scanners scan the same commits):

- On a pull request, every commit in the PR.
- On a push, the newly pushed commits. Deleting a branch scans nothing.
- On a push that creates a branch (or tag), its commits that the repository's default branch doesn't have
  yet (as the default branch stands when the job runs). Commits a branch merged in from the default
  branch are not scanned again. A new branch with no such commits scans nothing. The default branch's own first push (or a repository with no default
  branch to compare with) scans the whole history, since nothing has been scanned yet.
- On other events (schedule, manual runs), the whole history: every branch and tag the checkout has,
  remote-tracking branches included, and HEAD.

With `commits` set, the commits it names: git revisions or ranges such as `main..HEAD`, `main...HEAD`, one
commit (its history) or `all` (the whole history, as above). A value that filters commits instead (by date,
count, author or path, such as `--since=2024-01-01 HEAD`) is refused while trufflehog is on, since trufflehog
can't be told to scan exactly those commits; gitleaks alone (`trufflehog: false`) takes any `git log` options.

trufflehog walks back from one commit to another, so the Action hands it a commit it makes for the scan: an
empty merge of the commits to scan, which changes no files and is under no branch. To see it, trufflehog
scans the checkout in place (`--trust-local-git-config`) instead of a clone of it, so don't pass that flag
in `trufflehog-args` yourself.

Neither scanner reads what a merge commit itself changes (such as a conflict resolution), only the
commits it brings together.

## Use as a pre-commit or prek hook

The same scan runs on your machine with [prek](https://github.com/j178/prek) or
[pre-commit](https://pre-commit.com). In your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/kilotronic/secret-scan
    rev: 814f89d661368214fc3fedb2bd583bef835a17cd  # v1.2.0
    hooks:
      - id: secret-scan        # pre-commit: the staged changes
      - id: secret-scan-push   # pre-push: the commits being pushed
```

Then install the hook types you use: `prek install -t pre-commit -t pre-push`.

| Hook | Stage | Scans |
| --- | --- | --- |
| `secret-scan` | `pre-commit` (also `pre-merge-commit`, `manual`) | The staged changes |
| `secret-scan-push` | `pre-push` | The commits being pushed; on a new branch, its commits that no remote has yet |

The hooks run gitleaks only, at the same pinned version and with the same checksum check as the Action. It
is downloaded once into `~/.cache/kilotronic-secret-scan`. trufflehog stays in the Action, since it needs
Docker and calls each key's service. The hooks need `bash`, `curl` and `tar` (Linux or macOS), and
`.gitleaks.toml` at your repository root applies to them too.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `commits` | empty (this event's commits) | Git revisions or a range such as `main..HEAD`, or `all` for the whole history |
| `gitleaks` | `true` | Run gitleaks. A `.gitleaks.toml` at the repo root (e.g. to allow known look-alikes) is used |
| `trufflehog` | `true` | Run trufflehog (needs Docker) |
| `trufflehog-args` | `--results=verified` | Extra trufflehog arguments; the default fails only on working keys |
| `trufflehog-version` | `3.99.9` | trufflehog image tag |

Output: `range`, the git range that was scanned.

## Allowing a false alarm

gitleaks reads `.gitleaks.toml` at the repository root. To allow a known look-alike (a test fixture, a
documented example key), add an allowlist there, for example:

```toml
[extend]
useDefault = true

[allowlist]
description = "Example keys in the docs"
regexes = ['''EXAMPLEKEY[0-9]+''']
```

## Versions

Releases are tagged `vX.Y.Z` with a moving `vX` tag. gitleaks and trufflehog are updated in new
releases, never silently.
