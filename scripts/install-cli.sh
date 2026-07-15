#!/usr/bin/env bash
set -euo pipefail

REQUESTED_VERSION="${1:-latest}"
INSTALL_DIR="${2:-$HOME/.local/bin}"
RELEASES_BASE_URL="https://releases.getpolyglot.ai"
BINARY_NAME="polyglot"

if [[ ! "$REQUESTED_VERSION" =~ ^(latest|v?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?)$ ]]; then
  echo "::error::Invalid Polyglot CLI version: $REQUESTED_VERSION" >&2
  exit 1
fi

VERSION="$REQUESTED_VERSION"
if [ "$VERSION" != "latest" ]; then
  VERSION="v${VERSION#v}"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64) TARGET="x86_64-unknown-linux-gnu" ;;
      *) echo "::error::Unsupported Linux architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  Darwin)
    case "$ARCH" in
      arm64|aarch64) TARGET="aarch64-apple-darwin" ;;
      x86_64) TARGET="x86_64-apple-darwin" ;;
      *) echo "::error::Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  *) echo "::error::Unsupported OS: $OS" >&2; exit 1 ;;
esac

URL="$RELEASES_BASE_URL/$VERSION/$BINARY_NAME-$VERSION-$TARGET.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "::error::No SHA-256 tool is available on this runner" >&2
    return 1
  fi
}

fetch_and_verify() {
  local cache_buster="$1"
  curl --proto '=https' --tlsv1.2 -fsSL "$URL$cache_buster" -o "$TMP/polyglot.tar.gz" || return 1
  curl --proto '=https' --tlsv1.2 -fsSL "$URL.sha256$cache_buster" -o "$TMP/polyglot.sha256" || return 1

  local expected actual
  expected="$(awk 'NR == 1 {print $1}' "$TMP/polyglot.sha256")"
  if [[ ! "$expected" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    echo "::error::Release checksum sidecar is missing or malformed for $URL" >&2
    return 1
  fi

  actual="$(checksum "$TMP/polyglot.tar.gz")" || return 1
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  if [ "$actual" != "$expected" ]; then
    echo "::warning::Checksum mismatch for $URL; retrying from the release origin" >&2
    return 2
  fi
}

echo "Installing Polyglot CLI from $URL"
result=0
fetch_and_verify "" || result=$?
if [ "$result" -ne 0 ]; then
  result=0
  fetch_and_verify "?cb=$(date +%s)-$RANDOM" || result=$?
fi
if [ "$result" -ne 0 ]; then
  echo "::error::Could not download and verify Polyglot CLI $REQUESTED_VERSION" >&2
  exit 1
fi

tar -xzf "$TMP/polyglot.tar.gz" -C "$TMP"
if [ ! -f "$TMP/$BINARY_NAME" ]; then
  echo "::error::Verified release archive does not contain $BINARY_NAME" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"

VERSION_OUTPUT="$("$INSTALL_DIR/$BINARY_NAME" --version)"
INSTALLED_VERSION="$(printf '%s\n' "$VERSION_OUTPUT" | awk 'NR == 1 {print $2}')"
if [[ ! "$INSTALLED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::Installed binary returned an invalid version: $VERSION_OUTPUT" >&2
  exit 1
fi

if [ "$REQUESTED_VERSION" != "latest" ] && [ "$INSTALLED_VERSION" != "${REQUESTED_VERSION#v}" ]; then
  echo "::error::Requested Polyglot ${REQUESTED_VERSION#v}, but the archive contains $INSTALLED_VERSION" >&2
  exit 1
fi

echo "Installed polyglot $INSTALLED_VERSION ($TARGET)"
