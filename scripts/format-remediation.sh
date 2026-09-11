#!/usr/bin/env bash
# Static guidance: never interpolate repository-controlled paths or source text
# into suggested shell commands.
set -euo pipefail

cat <<'EOF'
<details>
<summary>Review and resolve findings</summary>

Use CLI 0.14.2 or later. Run `polyglot doctor --apps` to find the app, then change
to the same configured app directory selected by this workflow's `path` input.
Inspect the check artifact and choose one affected screen. Replace `SCREEN_FILE`
with its app-relative path, and `PLAN_ID` with the ID returned by the plan command:

```sh
polyglot scan --path . --format json
polyglot wrap --plan --file SCREEN_FILE --json
polyglot wrap --show PLAN_ID --json
```

Review the proposed source/catalog diff and manual-review entries. When ready:

```sh
polyglot wrap --apply PLAN_ID --json
polyglot translate --plan PLAN_ID --languages LANGUAGE_CODE --estimate
polyglot translate --plan PLAN_ID --languages LANGUAGE_CODE
```

Replace `LANGUAGE_CODE` with a configured target language. Build and inspect the
screen in that language, resolve the remaining findings, then rerun the check.
A stale plan must be rebuilt and reviewed. If the check is incomplete or errored,
resolve its diagnostic first; a candidate count does not establish a clean scan.
See [first-screen setup](https://getpolyglot.ai/docs/getting-started) for an app
without configuration and [recovery](https://getpolyglot.ai/docs/troubleshooting)
if a change needs to be undone.

</details>
EOF
