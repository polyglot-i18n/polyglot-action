# Polyglot i18n Check — GitHub Action

Compare immutable Git revisions and prevent pull requests from introducing new untranslated strings.

The recommended differential mode is brownfield-safe: existing localization debt is reported but allowed, while new untranslated strings fail. The original full-tree scan and coverage behavior remains available as `legacy` mode for every existing v1 workflow.

## Usage

```yaml
# .github/workflows/polyglot.yml
name: i18n Check

on:
  pull_request:
    branches: [main]
  merge_group:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Polyglot i18n Check
        uses: polyglot-i18n/polyglot-action@v1
        with:
          api-key: ${{ secrets.POLYGLOT_API_KEY }}
          check-mode: differential
          version: '0.9.2'
          comment: 'false'
```

## What it does

1. Installs the requested checksum-verified Polyglot CLI release.
2. Resolves explicit immutable base/head SHAs from `pull_request`, `merge_group`, `push`, or `workflow_dispatch`.
3. Fails closed if either commit is unavailable; use `fetch-depth: 0` as shown above.
4. Runs `polyglot check --format json` with the repository's `[ci]` policy. The default is `no-new`.
5. Validates the complete v1 result schema and exit-code consistency.
6. Emits GitHub annotations and, when an API key is configured, reports bounded run metadata even when comments are disabled.

Run reports contain counts, immutable SHAs, hashes, conclusions, coverage/validation summaries, and timing metadata. They do not upload source values or finding excerpts.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | no | `''` | Polyglot API key, exported as `POLYGLOT_API_KEY`. If empty, the CLI runs in guest mode. |
| `api-url` | no | `https://api.getpolyglot.ai` | HTTPS API origin for authenticated CI run reporting. |
| `check-mode` | no | `legacy` | `differential` runs `polyglot check`; `legacy` preserves the original v1 full-tree behavior. |
| `coverage-threshold` | no | `'100'` | Minimum average translation coverage percentage required to pass (`0` disables the coverage gate). |
| `fail_on_untranslated` | no | `'true'` | Fail the check if untranslated strings are found. |
| `comment` | no | `'true'` | Post a PR comment with the scan results. |
| `config_path` | no | `''` | Path to a `polyglot.toml` inside the checkout. Scan, coverage, and sync run from its directory; default is the checkout root. |
| `github_token` | no | `${{ github.token }}` | GitHub token used to post PR comments. |
| `version` | no | `'latest'` | Polyglot CLI version to install. Explicit versions are verified against the installed binary; all downloads require a matching SHA-256 sidecar. |
| `sync` | no | `'false'` | After scanning, run `polyglot push` to sync this repo's existing translations into your project's backend memory. Requires `api-key`. Runs **only** on a push to the default branch — never on `pull_request`. |

## Legacy v1 behavior

Existing workflows require no changes. Because `check-mode` defaults to `legacy`, the original inputs retain their exact behavior:

```yaml
- uses: actions/checkout@v4
- uses: polyglot-i18n/polyglot-action@v1
  with:
    api-key: ${{ secrets.POLYGLOT_API_KEY }}
    coverage-threshold: '100'
    fail_on_untranslated: 'true'
    comment: 'true'
```

Legacy mode runs `polyglot scan` and `polyglot coverage` over the whole checked-out tree. Move to differential mode deliberately; legacy thresholds are not reinterpreted as differential policy fields.

## Outputs

| Output | Description |
|--------|-------------|
| `total_strings` | Total number of untranslated strings found. |
| `files_scanned` | Number of files scanned. |
| `files_with_strings` | Number of files with untranslated strings. |
| `has_untranslated` | Whether untranslated strings were found (`true`/`false`). |
| `average_coverage` | Average translation coverage percentage across configured languages. |

## Getting an API key

Create a project and copy its API key from the [Polyglot dashboard](https://getpolyglot.ai). Store it as a repository secret (e.g. `POLYGLOT_API_KEY`) and pass it via `api-key`.

## Keeping the dashboard in sync

Your repo's locale files and your project's backend translation memory are two stores that can drift — if you translate locally, the dashboard can re-translate work you already have. Enable `sync` on a push to your default branch to reconcile them automatically after every merge:

```yaml
on:
  pull_request:        # PRs: scan + coverage gate (read-only)
  push:
    branches: [main]   # merges: also push existing translations into memory

jobs:
  polyglot:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: polyglot-i18n/polyglot-action@v1
        with:
          api-key: ${{ secrets.POLYGLOT_API_KEY }}
          sync: 'true'
```

`sync` is gated to default-branch pushes, so un-merged PR translations are never written to shared memory. It needs `api-key` (push is authenticated); without one it logs a warning and skips.
