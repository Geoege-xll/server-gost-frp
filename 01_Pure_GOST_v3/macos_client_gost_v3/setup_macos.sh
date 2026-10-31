#!/bin/bash
set -euo pipefail
readonly MACOS_CLIENT_SCHEME=gost
readonly MACOS_PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "$MACOS_PACKAGE_DIR/macos_client.sh"
macos_client_main install "$@"
