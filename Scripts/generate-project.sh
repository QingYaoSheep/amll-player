#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$REPOSITORY_ROOT/Scripts/bootstrap-xcodegen.sh"
"$REPOSITORY_ROOT/.tools/xcodegen/2.46.0/bin/xcodegen" \
    generate \
    --spec "$REPOSITORY_ROOT/project.yml" \
    --project "$REPOSITORY_ROOT"
