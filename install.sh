#!/bin/bash
# VPS 双方案入口；远程单文件启动时下载同一提交的完整仓库。
set -euo pipefail

usage() {
    printf '%s\n' \
        '用法：bash install.sh [gost|frp] [--upgrade] [--version vX.Y.Z]' \
        '      bash install.sh --upgrade [--version vX.Y.Z]' \
        '无参数：显示首次安装二选一菜单。升级会重启服务并中断现有连接。'
}

fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 10 --max-time 600 --retry 3 --output "$2" "$1"
}

bootstrap_repository() {
    [ "$(uname -s)" = Linux ] || { printf '远程安装入口仅支持 Linux。\n' >&2; exit 1; }
    [ "$(id -u)" = 0 ] || { printf '请以 root / sudo 运行。\n' >&2; exit 1; }
    command -v apt-get >/dev/null || { printf '自动部署支持 Debian / Ubuntu。\n' >&2; exit 1; }
    # 在任何仓库脚本执行前补齐引导依赖；不自动切换第三方镜像。
    if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl ca-certificates
    fi
    BOOTSTRAP_DIR=$(mktemp -d)
    trap 'rm -rf -- "$BOOTSTRAP_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -m 700 "$BOOTSTRAP_DIR/downloads" "$BOOTSTRAP_DIR/source"
    local commit=${REPO_COMMIT:-}
    if [ -z "$commit" ]; then
        fetch 'https://api.github.com/repos/Geoege-xll/server-gost-frp/commits/main' "$BOOTSTRAP_DIR/downloads/commit.json"
        commit=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha"])' "$BOOTSTRAP_DIR/downloads/commit.json")
    fi
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { printf '仓库提交号无效。\n' >&2; exit 1; }
    printf '下载完整仓库，提交：%s\n' "$commit"
    fetch "https://codeload.github.com/Geoege-xll/server-gost-frp/tar.gz/$commit" "$BOOTSTRAP_DIR/downloads/repository.tar.gz"
    # 归档作为数据处理：拒绝路径穿越、链接和特殊文件。
    python3 -I - "$BOOTSTRAP_DIR/downloads/repository.tar.gz" "$BOOTSTRAP_DIR/source" <<'PY'
import pathlib, shutil, sys, tarfile
root = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    for member in archive:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or '\\' in member.name:
            raise SystemExit('Unsafe repository archive path')
        target = root.joinpath(*path.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
        elif member.isfile():
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as src, target.open('wb') as dst:
                shutil.copyfileobj(src, dst)
        else:
            raise SystemExit('Repository archive links / special files are not allowed')
PY
    local checkout="$BOOTSTRAP_DIR/source/server-gost-frp-$commit"
    [ -s "$checkout/install.sh" ] && [ -s "$checkout/lib/deploy.sh" ] && [ -s "$checkout/lib/release.py" ] || {
        printf '仓库不完整，未执行安装。\n' >&2; exit 1;
    }
    bash "$checkout/install.sh" "$@"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi

SCRIPT_FILE=${BASH_SOURCE[0]:-}
REPO_ROOT=
if [ -n "$SCRIPT_FILE" ] && [ -f "$SCRIPT_FILE" ]; then
    REPO_ROOT=$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd)
fi
if [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/lib/deploy.sh" ] || [ ! -f "$REPO_ROOT/lib/release.py" ]; then
    bootstrap_repository "$@"
    exit 0
fi
# shellcheck source=lib/deploy.sh
source "$REPO_ROOT/lib/deploy.sh"

upgrade_detected() {
    local gost_installed=0 frp_installed=0
    [ ! -f /etc/gost/gost.yaml ] || gost_installed=1
    if [ -f /etc/frp/frps.toml ] || [ -f /root/frp/frps.toml ]; then frp_installed=1; fi
    if [ "$gost_installed" = 1 ] && [ "$frp_installed" = 0 ]; then
        deploy_main gost --upgrade "$@"
    elif [ "$frp_installed" = 1 ] && [ "$gost_installed" = 0 ]; then
        deploy_main frp --upgrade "$@"
    else
        fail '无法唯一确定已有方案；请显式指定 gost --upgrade 或 frp --upgrade'
    fi
}

case "${1:-}" in
    1|gost) shift; deploy_main gost "$@" ;;
    2|frp) shift; deploy_main frp "$@" ;;
    3|--upgrade|-u|upgrade) shift; upgrade_detected "$@" ;;
    '')
        printf '\n住宅出口反向隧道部署\n\n1) 纯 GOST v3（住宅机单进程）\n2) FRP + GOST（住宅机双进程）\n3) 升级已有服务端内核（保留配置，重启会断连）\n4) 退出\n\n'
        printf '请选择 [1-4]：' >/dev/tty
        read -r choice </dev/tty || fail '无法读取选择；请在命令行指定 gost 或 frp'
        case "$choice" in
            1) deploy_main gost ;;
            2) deploy_main frp ;;
            3) upgrade_detected ;;
            4) exit 0 ;;
            *) fail '请输入 1、2、3 或 4；不会默认安装' ;;
        esac ;;
    *) usage >&2; exit 1 ;;
esac
