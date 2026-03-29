#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk"
MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"

mkdir -p "$MODULE_CACHE_PATH"

export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH"

cd "$ROOT_DIR"
swift build
