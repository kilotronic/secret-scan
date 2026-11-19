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

Which commits it scans by default:

- On a pull request, every commit in the PR.
- On a push, the newly pushed commits, or only the tip of a newly created branch. Deleting a branch
  scans nothing.
- On other events (schedule, manual runs), the whole history.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `commits` | empty (this event's commits) | A git range such as `main..HEAD`, or `all` for the whole history |
| `gitleaks` | `true` | Run gitleaks. A `.gitleaks.toml` at the repo root (e.g. to allow known look-alikes) is used |
| `trufflehog` | `true` | Run trufflehog (needs Docker) |
| `trufflehog-args` | `--results=verified` | Extra trufflehog arguments; the default fails only on working keys |
| `trufflehog-version` | `3.99.8` | trufflehog image tag |

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
