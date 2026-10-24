#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Engine/build.sh
PAPERWORK_ENGINE="$PWD/Engine/build/canonical-pdf" swift test --jobs 2
