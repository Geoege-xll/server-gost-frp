#!/bin/bash
# 纯 GOST v3 入口；Windows / macOS 客户端共用部署逻辑与独立模板。
set -euo pipefail
SCRIPT_FILE=${BASH_SOURCE[0]:-}
if [ -z "$SCRIPT_FILE" ] || [ ! -f "$SCRIPT_FILE" ]; then
    printf '请下载完整仓库，或使用根目录 install.sh 远程引导入口。\n' >&2
    exit 1
fi
REPO_ROOT=$(cd -- "$(dirname -- "$SCRIPT_FILE")/.." && pwd)
[ -s "$REPO_ROOT/lib/deploy.sh" ] && [ -s "$REPO_ROOT/lib/release.py" ] || {
    printf '缺少公共部署文件；请下载完整仓库后运行 bash install.sh gost。\n' >&2
    exit 1
}
# shellcheck source=../lib/deploy.sh
source "$REPO_ROOT/lib/deploy.sh"
deploy_main gost "$@"
