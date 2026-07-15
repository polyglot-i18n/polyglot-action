#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mock-bin" "$TMP/release" "$TMP/payload"

cat > "$TMP/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$output" ] && [ -n "$url" ]
case "${url%%\?*}" in
  *.sha256) source="$INSTALLER_FIXTURE/checksum" ;;
  *) source="$INSTALLER_FIXTURE/archive.tar.gz" ;;
esac
[ -f "$source" ] || exit 22
cp "$source" "$output"
EOF
chmod +x "$TMP/mock-bin/curl"

make_release() {
  local version="$1"
  cat > "$TMP/payload/polyglot" <<EOF
#!/usr/bin/env bash
echo "polyglot $version"
EOF
  chmod +x "$TMP/payload/polyglot"
  tar -czf "$TMP/release/archive.tar.gz" -C "$TMP/payload" polyglot
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$TMP/release/archive.tar.gz" > "$TMP/release/checksum"
  else
    shasum -a 256 "$TMP/release/archive.tar.gz" > "$TMP/release/checksum"
  fi
}

export INSTALLER_FIXTURE="$TMP/release"
export PATH="$TMP/mock-bin:$PATH"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

echo "Test: checksum-verified explicit version installs"
make_release 1.2.3
if "$ROOT/scripts/install-cli.sh" 1.2.3 "$TMP/install" >/dev/null; then
  if [ "$("$TMP/install/polyglot" --version)" = "polyglot 1.2.3" ]; then
    ok "verified release installed"
  else
    bad "wrong binary installed"
  fi
else
  bad "valid verified release failed"
fi

echo
echo "Test: checksum sidecar is mandatory"
rm -f "$TMP/release/checksum"
if "$ROOT/scripts/install-cli.sh" 1.2.3 "$TMP/missing-checksum" >/dev/null 2>&1; then
  bad "archive without checksum installed"
else
  ok "missing checksum fails closed"
fi

echo
echo "Test: installed binary must match an explicit requested version"
make_release 9.9.9
if "$ROOT/scripts/install-cli.sh" 1.2.3 "$TMP/version-mismatch" >/dev/null 2>&1; then
  bad "mismatched binary version installed"
else
  ok "version mismatch fails closed"
fi

echo
echo "Test: stale or tampered archives are rejected"
make_release 1.2.3
printf '0%.0s' {1..64} > "$TMP/release/checksum"
if "$ROOT/scripts/install-cli.sh" 1.2.3 "$TMP/checksum-mismatch" >/dev/null 2>&1; then
  bad "checksum mismatch installed"
else
  ok "checksum mismatch fails closed"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
