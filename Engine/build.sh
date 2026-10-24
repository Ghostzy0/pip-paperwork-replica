#!/bin/sh
# Reproducible darwin/arm64 helper build. Build dependencies are downloaded only here.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP=$(CDPATH= cd -- "$ROOT/.." && pwd)
TOOLS="$APP/.build-tools"
GO_VERSION=1.26.0
GO_SHA=b1640525dfe68f066d56f200bef7bf4dce955a1a893bd061de6754c211431023
OUT=${1:-"$ROOT/build/canonical-pdf"}
mkdir -p "$TOOLS" "$(dirname "$OUT")"
if [ ! -x "$TOOLS/go/bin/go" ]; then
  curl -fL "https://go.dev/dl/go${GO_VERSION}.darwin-arm64.tar.gz" -o "$TOOLS/go${GO_VERSION}.darwin-arm64.tar.gz"
  ACTUAL=$(shasum -a 256 "$TOOLS/go${GO_VERSION}.darwin-arm64.tar.gz" | cut -d ' ' -f 1)
  [ "$ACTUAL" = "$GO_SHA" ] || { echo 'Go checksum mismatch' >&2; exit 1; }
  tar -xzf "$TOOLS/go${GO_VERSION}.darwin-arm64.tar.gz" -C "$TOOLS"
fi
[ "$("$TOOLS/go/bin/go" version)" = 'go version go1.26.0 darwin/arm64' ] || { echo 'Pinned Go toolchain required' >&2; exit 1; }
export GOTOOLCHAIN=local GOMODCACHE="$TOOLS/pkg/mod" GOCACHE="$TOOLS/go-cache" GOMAXPROCS=2
cd "$ROOT"
"$TOOLS/go/bin/go" mod download
"$TOOLS/go/bin/go" mod verify
# The caller must acquire a shared heavy lease before invoking this script.
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 "$TOOLS/go/bin/go" build -p 2 -trimpath -buildvcs=false -ldflags='-s -w' -o "$OUT" .
printf '%s\n' "$OUT"
