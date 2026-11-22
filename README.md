# PolinRider Scanner action

**Guide and docs:** [polinriderscanner.com/github-action](https://polinriderscanner.com/github-action/)

Scans your repository for the PolinRider payload on every push, every pull
request and once a week. It runs the released `polinrider` binary from
[meSingh/polinrider-scanner](https://github.com/meSingh/polinrider-scanner),
the same engine and the same indicators as the tool you run on a laptop, and
gives the same verdict.

- **Pinned by hash.** The version and the SHA-256 of every archive are written
  into [`action.yml`](./action.yml). The action downloads the archive for the
  runner, hashes it and refuses to run anything that does not match.
- **Read-only by default.** `check` needs `contents: read` and nothing else.
- **Fix mode opens a pull request.** It never commits to the branch it
  scanned, never force-pushes and never merges. It does nothing on a pull
  request from a fork.
- **Bash, curl and tar.** No npm, no other actions inside it.

## Use it

Add `.github/workflows/polinrider.yml`:

```yaml
name: PolinRider
on:
  push:
  pull_request:
  schedule:
    - cron: "17 3 * * 1"
permissions:
  contents: read
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: meSingh/polinrider-action@8c71848593f0e58416c5f61845b3bd2e8080d438 # v1.0.0
```

Use the full commit SHA of the release you want, not a tag: the one above is
v1.0.0. The [releases page](https://github.com/meSingh/polinrider-action/releases)
lists each one's SHA. Tags of this action never move, but a SHA is what GitHub
itself guarantees cannot.

A confirmed finding fails the check. The job summary lists each finding and
what to do next, and each one is annotated on its file.

It checks the commit it runs on. It does not read the repository's other
branches or older commits: the scanner on a computer does that, where someone
can act on what it finds.

## So it doesn't come back

1. **Make the check required.** In your repository's Settings, Rules,
   Rulesets, add a branch ruleset for the default branch with "Require status
   checks to pass" and pick `scan`. An infected push or pull request then
   cannot merge. The full ruleset, and the command to create it, are in
   [Block a merge on a finding](https://polinriderscanner.com/docs/action/require/).
2. **Keep the weekly schedule.** The `schedule:` above runs the scan on
   Mondays even when nobody pushes, so indicators added in a new release reach
   code that has not changed.
3. **Let Dependabot move the pin.** Each new scanner release becomes a new
   release of this action, with its new version and hashes. Add
   `.github/dependabot.yml`:

   ```yaml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule:
         interval: weekly
   ```

   Dependabot then opens a pull request that moves the SHA, and you review it
   like any other change.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `mode` | `check` | `check` reads only. `fix` also removes the payload and opens a pull request |
| `path` | `.` | The directory to scan, relative to the workspace |
| `fail-on` | `confirmed` | `confirmed` fails on a confirmed finding. `review` also fails on a finding to review. `never` only reports |
| `comment` | `false` | `true` posts the result on the pull request and keeps that one comment up to date |
| `sarif-file` | empty | Also write the findings as SARIF to this path, for code scanning |
| `token` | `github.token` | Used by fix mode and `comment: true` only. The scan itself never sees a token |

A scan that could not run (a hash that does not match, a runner it cannot
start on) always fails, whatever `fail-on` says. Nothing scanned is never
reported as clean.

## Outputs

| Output | Value |
|---|---|
| `verdict` | `clean`, `review`, `infected` or `error` |
| `confirmed` | The number of confirmed findings |
| `review` | The number of findings to review |
| `files` | The number of files scanned |
| `pr-url` | The pull request fix mode opened, or found already open |

## Permissions per mode

| What you use | Needs |
|---|---|
| `mode: check` | `contents: read` |
| `comment: true` | also `pull-requests: write` |
| `sarif-file` with `upload-sarif` | also `security-events: write` |
| `mode: fix` | `contents: write` and `pull-requests: write` |

Give a job only what its mode uses. The default above is read-only.

## Fix mode

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  fix:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: meSingh/polinrider-action@8c71848593f0e58416c5f61845b3bd2e8080d438 # v1.0.0
        with:
          mode: fix
```

When the scan finds the payload, fix mode runs `polinrider clean --apply` on
the checkout. That cuts an appended payload out of a file and keeps the rest,
and removes a file that was nothing but the payload. Then it creates a branch
`polinrider/remove-payload-<sha>` at the scanned commit, makes one commit on it
through GitHub's API and opens a pull request into the branch it scanned. The
pull request lists what was cut out, what was removed and what was left for a
person to look at.

What it never does:

- commit to the branch it scanned, force-push or merge;
- anything on a pull request from a fork;
- upload the quarantine. The originals `clean` keeps are the payload. They stay
  in the runner's temporary directory, outside your workspace, which the runner
  empties after the job.

The step still fails: the commit it scanned is infected until the pull request
is merged.

Things to know:

- **Allow it once.** In Settings, Actions, General, tick "Allow GitHub Actions
  to create and approve pull requests". Without it GitHub refuses the pull
  request and the step says so.
- **Checks on its pull request wait for approval.** A pull request opened with
  the default token starts its workflow runs only after someone with write
  access approves them. To have them start straight away, pass a GitHub App
  token or a fine-grained token with `token:`.
- **No git credentials needed.** The commit is made through GitHub's API and
  signed by GitHub, so the checkout can keep `persist-credentials: false`.
- **Workflow files.** A payload in `.github/workflows/` needs a token with the
  `workflows` permission to change. The default token cannot.
- **On `pull_request`,** check out the head branch (`ref: ${{ github.head_ref }}`),
  not the merge commit, or there is no branch tip to start the fix from. Fix
  mode then opens its pull request into that branch.

## Code scanning and comments

```yaml
    permissions:
      contents: read
      pull-requests: write
      security-events: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: meSingh/polinrider-action@8c71848593f0e58416c5f61845b3bd2e8080d438 # v1.0.0
        with:
          comment: true
          sarif-file: polinrider.sarif
      - if: ${{ !cancelled() }}
        uses: github/codeql-action/upload-sarif@<sha> # v4
        with:
          sarif_file: polinrider.sarif
```

A pull request from a fork gets a read-only token, so it gets no comment; the
job summary still has the result.

## What it trusts, and the alternative

This action trusts three things: this repository at the SHA you pin, the
scanner's release on GitHub and the hashes in `action.yml`. The hashes are
taken from the release's `SHA256SUMS` by the scanner's release workflow, which
opens a pull request here for each release. Check any of them yourself:

The polinrider version is the `POLINRIDER_VERSION` line in `action.yml` at the
SHA you pin, and each release's notes name it. In a checkout of that SHA:

```bash
VERSION=$(sed -n 's/.*POLINRIDER_VERSION: "\(.*\)"/\1/p' action.yml)
gh release download "v$VERSION" --repo meSingh/polinrider-scanner --pattern SHA256SUMS --pattern "polinrider-v$VERSION-linux-x86_64.tar.gz"
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify "polinrider-v$VERSION-linux-x86_64.tar.gz" --repo meSingh/polinrider-scanner
```

If you would rather trust nothing fetched at scan time, the scanner's
repository has a
[vendored copy](https://github.com/meSingh/polinrider-scanner/tree/main/ci)
that you install into your repository and review like your own code. It is a
shell port of the checks; this action runs the binary itself.

## Runners

| Runner | |
|---|---|
| `ubuntu-latest`, `ubuntu-24.04`, and their arm64 runners | Supported. The Linux binaries need glibc 2.39 or later, so `ubuntu-22.04` cannot start them and the step says so |
| `macos-latest` and the other macOS runners | The macOS archives, the same scripts. Supported, with less mileage than Linux so far |
| Windows | Not yet. The step fails and says so |

Self-hosted runners need bash, curl, tar and a SHA-256 tool; fix mode and
comments also need `gh` and `jq`, which GitHub's own runners have.

## Testing this action

`test/container.sh` runs every step of `action.yml` against fixture
repositories (clean, to review, infected, fix mode, a pull request from a
fork and a hash that does not match) in a disposable container with no network,
with a stand-in for `gh` that records what would have been sent to GitHub.
Fixtures carry no payload: the indicators come from the release itself.

```bash
VERSION=$(sed -n 's/.*POLINRIDER_VERSION: "\(.*\)"/\1/p' action.yml)
gh release download "v$VERSION" --repo meSingh/polinrider-scanner --pattern "polinrider-v$VERSION-linux-*.tar.gz" --dir "dist/v$VERSION"
test/container.sh dist
```

## License

MIT, as the scanner. See [LICENSE](./LICENSE).
