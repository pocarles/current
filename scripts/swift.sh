#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
exec swift "$@" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
