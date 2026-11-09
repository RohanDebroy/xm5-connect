#!/bin/bash
# Source from other scripts; all build state remains inside the project.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
mkdir -p "$PROJECT_ROOT/.build/cache" "$PROJECT_ROOT/.build/config" "$PROJECT_ROOT/.build/security"
SWIFT_OPTIONS=(--package-path "$PROJECT_ROOT" --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security" --manifest-cache local)
# The outer Codex sandbox already isolates the compiler. A normal terminal does
# not need this; opt in explicitly when the host denies nested sandbox setup.
if [[ "${SONY_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then SWIFT_OPTIONS+=(--disable-sandbox); fi
