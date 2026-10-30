#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/module-cache"
TEST_ARGS=(--cache-path .build/cache --config-path .build/config --security-path .build/security)
if [[ "${DESKANCHOR_DISABLE_PACKAGE_SANDBOX:-0}" == 1 ]]; then TEST_ARGS+=(--disable-sandbox); fi
swift test "${TEST_ARGS[@]}"
