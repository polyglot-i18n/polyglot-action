# Polyglot i18n Scanner — GitHub Action

Detect untranslated strings in your codebase and post a translation report on pull requests.

This action installs the Polyglot CLI, runs `polyglot scan` on your repository, posts (and updates) a PR comment with the untranslated-string counts, and can gate the check on a coverage threshold.

## Usage

```yaml
# .github/workflows/polyglot.yml
name: i18n Check

on:
  pull_request:
    branches: [main]

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Polyglot i18n Scan
        uses: polyglot-i18n/polyglot-action@v1
        with:
          api-key: ${{ secrets.POLYGLOT_API_KEY }}
          coverage-threshold: '100'
          fail_on_untranslated: 'true'
          comment: 'true'
```

## What it does

1. Installs the Polyglot CLI (`https://getpolyglot.ai/install.sh`).
2. Runs `polyglot scan` on the checked-out tree and records the untranslated-string counts.
3. On pull requests (when `comment: 'true'`), posts or updates a single PR comment with the untranslated-string counts and a per-file breakdown.
4. Gates the check:
   - Fails if average translation coverage is below `coverage-threshold` (set it to `0` to disable).
   - Fails if untranslated strings are found and `fail_on_untranslated: 'true'`.

The action runs `polyglot scan` / `polyglot coverage` over the whole checked-out tree. It does **not** diff against the base branch.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | no | `''` | Polyglot API key, exported as `POLYGLOT_API_KEY`. If empty, the CLI runs in guest mode. |
| `coverage-threshold` | no | `'100'` | Minimum average translation coverage percentage required to pass (`0` disables the coverage gate). |
| `fail_on_untranslated` | no | `'true'` | Fail the check if untranslated strings are found. |
| `comment` | no | `'true'` | Post a PR comment with the scan results. |
| `config_path` | no | `''` | Path to `polyglot.toml` (default: auto-detect). |
| `github_token` | no | `${{ github.token }}` | GitHub token used to post PR comments. |
| `version` | no | `'latest'` | Polyglot CLI version to install. |

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
