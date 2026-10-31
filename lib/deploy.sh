#!/bin/bash
# 公共部署逻辑。两个方案共用下载校验、证书、打包和原子升级流程。

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

https_get() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 10 --max-time 600 --retry 3 --output "$2" "$1"
}

release_info() {
    local repo=$1 requested=$2 output=$3 endpoint=latest
    if [ "$requested" != latest ]; then
        [[ "$requested" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail '版本号格式无效'
        endpoint="tags/v${requested#v}"
    fi
    https_get "https://api.github.com/repos/$repo/releases/$endpoint" "$output" || return 1
    python3 -I "$REPO_ROOT/lib/release.py" tag "$output"
}

download_asset() {
    local metadata=$1 repo=$2 name=$3 output=$4 details url digest
    details=$(python3 -I "$REPO_ROOT/lib/release.py" asset "$metadata" "$repo" "$name") || return 1
    url=${details%%$'\n'*}
    digest=${details##*$'\n'}
    https_get "$url" "$output" || return 1
    python3 -I "$REPO_ROOT/lib/release.py" verify "$output" "$digest"
}

extract_asset() {
    mkdir -m 700 "$2"
    python3 -I "$REPO_ROOT/lib/release.py" extract "$1" "$2"
}

find_one() {
    local files count
    files=$(find "$1" -type f -name "$2") || return 1
    count=$(printf '%s\n' "$files" | grep -c . || true)
    [ "$count" = 1 ] || fail "组件 $2 缺失或有多个副本"
    [ -s "$files" ] || fail "组件 $2 为空文件"
    printf '%s\n' "$files"
}

linux_arch() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) fail '仅支持 Linux amd64 / arm64' ;;
    esac
}

install_dependencies() {
    command -v apt-get >/dev/null || fail '当前自动安装支持 Debian / Ubuntu (apt-get)'
    export DEBIAN_FRONTEND=noninteractive
    if [ "$1" = upgrade ]; then
        # 只升级服务端时不安装 Windows 打包工具，也不重复更新已有依赖。
        if command -v curl >/dev/null && command -v python3 >/dev/null; then return; fi
        apt-get update
        apt-get install -y ca-certificates curl python3
        return
    fi
    apt-get update
    apt-get install -y ca-certificates curl python3 openssl tar unzip zip iproute2
    # Windows 离线包在 VPS 上解压 Servy 的 7z 压缩包，需要 7z；macOS 包用系统 tar。
    if [ "${CLIENT_PLATFORM:-windows}" = windows ] && ! command -v 7z >/dev/null && ! command -v 7zz >/dev/null; then
        if apt-cache show p7zip-full >/dev/null 2>&1; then
            apt-get install -y p7zip-full
        else
            apt-get install -y 7zip
        fi
    fi
}

random_secret() { openssl rand -hex "${1:-24}"; }

public_ipv4() {
    local address=${VPS_PUBLIC_IP:-}
    if [ -z "$address" ]; then
        address=$(curl -4fsS --proto '=https' --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
    fi
    if [ -z "$address" ]; then
        printf '请输入 VPS 公网 IPv4：' >/dev/tty
        read -r address </dev/tty || fail '请通过 VPS_PUBLIC_IP 指定公网 IPv4'
    fi
    python3 -I "$REPO_ROOT/lib/release.py" ipv4 "$address"
}

generate_certs() {
    local directory=$1 address=$2
    mkdir -m 700 "$directory"
    # 私有 CA；显式限定证书用途，客户端用 SAN 验证服务器身份。
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -keyout "$directory/ca.key" -out "$directory/ca.crt" -subj '/CN=Residential-Tunnel-CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:%s\n' "$address" > "$directory/server.ext"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > "$directory/client.ext"
    local role
    for role in server client; do
        openssl req -new -newkey rsa:2048 -sha256 -nodes -keyout "$directory/$role.key" \
            -out "$directory/$role.csr" -subj "/CN=tunnel-$role" >/dev/null 2>&1
        openssl x509 -req -in "$directory/$role.csr" -CA "$directory/ca.crt" \
            -CAkey "$directory/ca.key" -set_serial "0x$(random_secret 16)" -days 825 -sha256 \
            -extfile "$directory/$role.ext" -out "$directory/$role.crt" >/dev/null 2>&1
        rm "$directory/$role.csr" "$directory/$role.ext"
    done
    openssl verify -CAfile "$directory/ca.crt" -purpose sslserver -verify_ip "$address" "$directory/server.crt"
    openssl verify -CAfile "$directory/ca.crt" -purpose sslclient "$directory/client.crt"
    chmod 600 "$directory/"*.key
}

render_gost_server() {
    local directory=$1 user=$2 password=$3 bind=${4:-0.0.0.0:9000}
    cat <<YAML
services:
  - name: relay-server
    addr: "$bind"
    handler:
      type: relay
      auth:
        username: "$user"
        password: "$password"
      metadata:
        bind: true
        nodelay: true
    listener:
      type: mtls
      metadata:
        muxKeepAliveInterval: 10s
        muxKeepAliveTimeout: 30s
      tls:
        certFile: "$directory/certs/server.crt"
        keyFile: "$directory/certs/server.key"
        caFile: "$directory/certs/ca.crt"
YAML
}

render_frps_server() {
    local directory=$1 token=$2 port=${3:-9000} bind=${4:-0.0.0.0}
    local allowed='[{ single = 10001 }, { single = 33389 }]' max_ports=2
    if [ "${CLIENT_PLATFORM:-windows}" = mac ]; then
        allowed='[{ single = 10001 }]'
        max_ports=1
    fi
    cat <<TOML
bindAddr = "$bind"
bindPort = $port
proxyBindAddr = "127.0.0.1"
allowPorts = $allowed
maxPortsPerClient = $max_ports
auth.method = "token"
auth.token = "$token"
transport.maxPoolCount = 5
transport.heartbeatTimeout = 90
transport.tcpMux = true
transport.tls.force = true
transport.tls.certFile = "$directory/certs/server.crt"
transport.tls.keyFile = "$directory/certs/server.key"
transport.tls.trustedCaFile = "$directory/certs/ca.crt"
TOML
}

write_unit() {
    local name=$1 binary=$2 config=$3 flag=$4
    cat > "$WORK_DIR/$name.service" <<UNIT
[Unit]
Description=Residential $name tunnel
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$binary $flag $config
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
}

wait_service() {
    local attempt
    for attempt in 1 2 3 4 5; do
        sleep 1
        systemctl is-active --quiet "$1" || return 1
    done
}

validate_config() {
    local binary=$1 config=$2
    if [ "$SCHEME" = frp ]; then
        "$binary" verify -c "$config"
    else
        # -O 只做配置加载/输出，不启动监听；不是端到端健康检查。
        "$binary" -C "$config" -O yaml >/dev/null
    fi
}

cleanup_deploy() {
    local status=$?
    if [ "${UPGRADE_PENDING:-0}" = 1 ]; then
        printf '\n升级未完成，正在恢复原二进制。\n' >&2
        if mv -f "$UPGRADE_BACKUP" "$BINARY"; then
            if [ "${WAS_ACTIVE:-0}" = 1 ]; then
                if systemctl restart "$SERVICE" && wait_service "$SERVICE"; then
                    printf '旧二进制已恢复，服务已重新运行；仍需验收实际链路。\n' >&2
                else
                    printf '回滚后服务健康检查未通过，请检查 journalctl。\n' >&2
                fi
            fi
        else
            printf '自动回滚失败，备份：%s\n' "$UPGRADE_BACKUP" >&2
        fi
        status=1
    fi
    if [ -n "${WORK_DIR:-}" ]; then rm -rf -- "$WORK_DIR"; fi
    exit "$status"
}

prepare_binary() {
    local requested=$1 tag version archive upstream
    if [ "$SCHEME" = gost ]; then upstream=go-gost/gost; else upstream=fatedier/frp; fi
    tag=$(release_info "$upstream" "$requested" "$WORK_DIR/core-release.json")
    version=${tag#v}
    CORE_TAG=$tag
    local minimum=0.71.1
    [ "$SCHEME" != gost ] || minimum=3.3.2
    [ "$(python3 -I "$REPO_ROOT/lib/release.py" compare "$minimum" "$tag")" != -1 ] || fail "当前模板要求 $SCHEME >= $minimum"
    if [ "$SCHEME" = gost ]; then archive="gost_${version}_linux_${ARCH}.tar.gz"; else archive="frp_${version}_linux_${ARCH}.tar.gz"; fi
    info "下载并校验 $archive"
    download_asset "$WORK_DIR/core-release.json" "$upstream" "$archive" "$WORK_DIR/core.tar.gz"
    extract_asset "$WORK_DIR/core.tar.gz" "$WORK_DIR/core"
    CORE_BINARY=$(find_one "$WORK_DIR/core" "$SERVICE")
    chmod 755 "$CORE_BINARY"
    if [ "$SCHEME" = gost ]; then "$CORE_BINARY" -V; else "$CORE_BINARY" -v; fi
}

upgrade_binary() {
    [ -f "$BINARY" ] && [ -f "$CONFIG" ] || fail '未找到本方案的二进制及配置，不能执行升级'
    [ ! -L "$BINARY" ] || fail '目标二进制是符号链接，请先人工确认安装归属'
    local current comparison staging backup
    if [ "$SCHEME" = gost ]; then
        current=$("$BINARY" -V)
        [[ "$current" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || fail '无法识别当前 GOST 版本'
        current=${BASH_REMATCH[1]}
    else
        current=$("$BINARY" -v)
    fi
    comparison=$(python3 -I "$REPO_ROOT/lib/release.py" compare "$current" "$CORE_TAG")
    [ "$comparison" != -1 ] || fail '目标版本比当前版本旧，拒绝自动降级'
    validate_config "$CORE_BINARY" "$CONFIG"
    if [ "$comparison" = 0 ]; then info "已是 ${CORE_TAG}，配置检查通过（非链路验收），无需替换"; return; fi
    # 同目录写入再 rename，避免 cp 截断正在执行的 inode（ETXTBSY）。
    staging=$(mktemp "$(dirname "$BINARY")/.${SERVICE}.new.XXXXXX")
    backup=$(mktemp "$(dirname "$BINARY")/.${SERVICE}.backup.XXXXXX")
    install -m 755 "$CORE_BINARY" "$staging"
    cp -p "$BINARY" "$backup"
    UPGRADE_BACKUP=$backup
    WAS_ACTIVE=0
    if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=1; fi
    UPGRADE_PENDING=1
    mv -f "$staging" "$BINARY"
    if [ "$WAS_ACTIVE" = 1 ]; then
        systemctl restart "$SERVICE" || fail '新版本启动失败，将回滚'
        wait_service "$SERVICE" || fail '新版本服务未保持运行，将回滚'
    fi
    UPGRADE_PENDING=0
    rm "$backup"
    info "已升级到 ${CORE_TAG}；配置及证书未变更。服务重启会中断现有连接。"
    printf '未更新住宅机客户端或旧配置包；跨版本升级前请检查两端兼容性。\n'
}

build_windows_package() {
    local template=$1 package=$2 certs=$3 tag gost_tag version asset file sevenzip suffix
    local manifest_args=()
    if [ "$SCHEME" = gost ]; then suffix=gost_v3; else suffix=frp_gost; fi
    for file in "setup_$suffix.ps1" "uninstall_$suffix.ps1" 'README_住宅机安装说明.txt'; do
        [ -s "$template/$file" ] || fail "缺少 Windows 模板：$file"
    done
    [ -s "$REPO_ROOT/lib/windows_components.ps1" ] || fail '缺少 Windows 组件校验模板'
    [ -s "$REPO_ROOT/lib/windows_diagnostics.ps1" ] || fail '缺少 Windows 只读诊断模板'
    mkdir -m 700 "$WORK_DIR/package"
    # 仅复制明确的 PS1 入口和说明；不把旧 BAT 或模板目录中的其他文件带入包。
    for file in "setup_$suffix.ps1" "uninstall_$suffix.ps1" 'README_住宅机安装说明.txt'; do
        cp "$template/$file" "$WORK_DIR/package/"
    done
    cp "$REPO_ROOT/lib/windows_components.ps1" "$WORK_DIR/package/"
    cp "$REPO_ROOT/lib/windows_diagnostics.ps1" "$WORK_DIR/package/diagnose_windows.ps1"
    cp "$certs/ca.crt" "$certs/client.crt" "$certs/client.key" "$WORK_DIR/package/"
    if [ "$SCHEME" = frp ]; then
        gost_tag=$(release_info go-gost/gost latest "$WORK_DIR/gost-release.json")
    else
        cp "$WORK_DIR/core-release.json" "$WORK_DIR/gost-release.json"
        gost_tag=$CORE_TAG
    fi
    tag=$(release_info aelassas/servy latest "$WORK_DIR/servy-release.json")
    # 组件清单固定官方 URL/版本/摘要；随后在 VPS 下载并内置全部 Windows 组件。
    manifest_args=("$SCHEME" "$CORE_TAG" "$WORK_DIR/gost-release.json" "$WORK_DIR/servy-release.json")
    if [ "$SCHEME" = frp ]; then manifest_args+=("$WORK_DIR/core-release.json"); fi
    python3 -I "$REPO_ROOT/lib/release.py" manifest "$WORK_DIR/package/components.json" "${manifest_args[@]}"
    # 离线内置组件：gost/frpc 解出单文件，Servy 整目录原样内置（住宅机不再解压）。
    if [ "$SCHEME" = frp ]; then
        version=${CORE_TAG#v}
        asset="frp_${version}_windows_amd64.zip"
        download_asset "$WORK_DIR/core-release.json" fatedier/frp "$asset" "$WORK_DIR/frpc.zip"
        extract_asset "$WORK_DIR/frpc.zip" "$WORK_DIR/frpc"
        file=$(find_one "$WORK_DIR/frpc" frpc.exe)
        cp "$file" "$WORK_DIR/package/frpc.exe"
    fi
    version=${gost_tag#v}
    asset="gost_${version}_windows_amd64.zip"
    download_asset "$WORK_DIR/gost-release.json" go-gost/gost "$asset" "$WORK_DIR/gost.zip"
    extract_asset "$WORK_DIR/gost.zip" "$WORK_DIR/gost-windows"
    file=$(find_one "$WORK_DIR/gost-windows" gost.exe)
    cp "$file" "$WORK_DIR/package/gost.exe"
    version=${tag#v}
    asset="servy-${version}-net48-x64-portable.7z"
    download_asset "$WORK_DIR/servy-release.json" aelassas/servy "$asset" "$WORK_DIR/servy.7z"
    mkdir -m 700 "$WORK_DIR/package/servy"
    sevenzip=$(command -v 7z || command -v 7zz)
    "$sevenzip" x -y "-o$WORK_DIR/package/servy" "$WORK_DIR/servy.7z" >/dev/null
    find_one "$WORK_DIR/package/servy" servy-cli.exe >/dev/null
    find_one "$WORK_DIR/package/servy" Servy.exe >/dev/null
    python3 -I "$REPO_ROOT/lib/release.py" inject "$WORK_DIR/package" \
        "VPS_PUBLIC_IP=$PUBLIC_IP" "TOKEN=$AUTH_TOKEN" "RELAY_USER=$RELAY_USER" \
        "RELAY_PASS=$RELAY_PASS" "GOST_USER=$GOST_USER" "GOST_PASS=$GOST_PASS"
    # 保留实际组件版本和分发模式，避免升级后误发旧包。
    printf 'Package mode: offline\nTunnel: %s %s\nGOST: %s\nServy: %s\nWindows architecture: amd64\n' \
        "$SCHEME" "$CORE_TAG" "$gost_tag" "$tag" > "$WORK_DIR/package/VERSIONS.txt"
    (cd "$WORK_DIR/package" && zip -q -r "$WORK_DIR/$package" .)
    unzip -tq "$WORK_DIR/$package" >/dev/null
}

client_platform_from_choice() {
    case "$1" in
        1|windows) printf 'windows\n' ;;
        2|mac|macos) printf 'mac\n' ;;
        *) fail '住宅机系统只能选择 windows 或 mac（菜单 1 或 2）' ;;
    esac
}

select_client_platform() {
    local choice
    if ! printf '\n请选择住宅机系统：\n1) Windows x64（Servy）\n2) macOS Apple Silicon / Intel（launchd）\n请选择 [1-2]：' >/dev/tty 2>/dev/null; then
        fail '无法读取住宅机选择；请使用 --client windows 或 --client mac'
    fi
    read -r choice </dev/tty || fail '无法读取住宅机选择；请使用 --client windows 或 --client mac'
    client_platform_from_choice "$choice"
}

client_package_name() {
    local prefix suffix
    case "$1" in gost) suffix=gost_v3 ;; frp) suffix=frp_gost ;; *) fail '未知方案' ;; esac
    case "$2" in windows) prefix=windows ;; mac) prefix=macos ;; *) fail '未知住宅机系统' ;; esac
    printf '%s_%s_pkg.zip\n' "$prefix" "$suffix"
}

build_macos_package() {
    local template=$1 package=$2 certs=$3
    local gost_tag component arch metadata upstream prefix tag asset file
    local manifest_args=()
    for file in setup_macos.sh uninstall_macos.sh 'README_住宅机安装说明.txt'; do
        [ -s "$template/$file" ] || fail "缺少 macOS 模板：$file"
    done
    [ -s "$REPO_ROOT/lib/macos_client.sh" ] || fail '缺少 macOS 公共客户端模板'
    mkdir -m 700 "$WORK_DIR/package"
    cp "$template/"* "$WORK_DIR/package/"
    cp "$REPO_ROOT/lib/macos_client.sh" "$WORK_DIR/package/"
    cp "$certs/ca.crt" "$certs/client.crt" "$certs/client.key" "$WORK_DIR/package/"
    if [ "$SCHEME" = frp ]; then
        gost_tag=$(release_info go-gost/gost latest "$WORK_DIR/gost-release.json")
    else
        cp "$WORK_DIR/core-release.json" "$WORK_DIR/gost-release.json"
        gost_tag=$CORE_TAG
    fi
    manifest_args=("$SCHEME" "$CORE_TAG" "$WORK_DIR/gost-release.json")
    if [ "$SCHEME" = frp ]; then manifest_args+=("$WORK_DIR/core-release.json"); fi
    python3 -I "$REPO_ROOT/lib/release.py" macos-manifest "$WORK_DIR/package/components.json" "${manifest_args[@]}"
    # 离线包同时内置两种 Mac 架构并记录摘要，住宅机不再下载任何组件。
    : > "$WORK_DIR/package/offline-sha256.txt"
    for component in gost frpc; do
        if [ "$component" = gost ]; then
            metadata="$WORK_DIR/gost-release.json"; upstream=go-gost/gost; prefix=gost; tag=$gost_tag
        else
            [ "$SCHEME" = frp ] || continue
            metadata="$WORK_DIR/core-release.json"; upstream=fatedier/frp; prefix=frp; tag=$CORE_TAG
        fi
        for arch in amd64 arm64; do
            asset="${prefix}_${tag#v}_darwin_${arch}.tar.gz"
            download_asset "$metadata" "$upstream" "$asset" "$WORK_DIR/$component-$arch.tar.gz"
            extract_asset "$WORK_DIR/$component-$arch.tar.gz" "$WORK_DIR/$component-$arch"
            file=$(find_one "$WORK_DIR/$component-$arch" "$component")
            install -d -m 700 "$WORK_DIR/package/bin/$arch"
            install -m 755 "$file" "$WORK_DIR/package/bin/$arch/$component"
            python3 -I -c 'import hashlib, pathlib, sys; p = pathlib.Path(sys.argv[1]); print(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + sys.argv[2])' \
                "$WORK_DIR/package/bin/$arch/$component" "bin/$arch/$component" >> "$WORK_DIR/package/offline-sha256.txt"
        done
    done
    printf '%s\n' 'VPS_PUBLIC_IP=VPS_PUBLIC_IP_PLACEHOLDER' 'TOKEN=TOKEN_PLACEHOLDER' \
        'RELAY_USER=RELAY_USER_PLACEHOLDER' 'RELAY_PASS=RELAY_PASS_PLACEHOLDER' \
        'GOST_USER=GOST_USER_PLACEHOLDER' 'GOST_PASS=GOST_PASS_PLACEHOLDER' > "$WORK_DIR/package/client.conf"
    python3 -I "$REPO_ROOT/lib/release.py" inject "$WORK_DIR/package" \
        "VPS_PUBLIC_IP=$PUBLIC_IP" "TOKEN=$AUTH_TOKEN" "RELAY_USER=$RELAY_USER" \
        "RELAY_PASS=$RELAY_PASS" "GOST_USER=$GOST_USER" "GOST_PASS=$GOST_PASS"
    chmod 600 "$WORK_DIR/package/client.conf" "$WORK_DIR/package/client.key"
    chmod 700 "$WORK_DIR/package/"*.sh
    printf 'Package mode: offline\nClient platform: macos\nTunnel: %s %s\nGOST: %s\nMac architectures: amd64 arm64\nService manager: launchd (built-in)\n' \
        "$SCHEME" "$CORE_TAG" "$gost_tag" > "$WORK_DIR/package/VERSIONS.txt"
    (cd "$WORK_DIR/package" && zip -q -r "$WORK_DIR/$package" .)
    unzip -tq "$WORK_DIR/$package" >/dev/null
}

# 下载账号专用命令封装：ForceCommand 经登录 shell 执行本脚本。
# 仅允许两类操作——sftp 子系统（WinSCP、新版 OpenSSH 客户端；OpenSSH 源码
# session.c 中 subsystem 请求的 SSH_ORIGINAL_COMMAND 是 Subsystem 配置命令串
# 本身，如 /usr/lib/openssh/sftp-server，而非 “sftp” 名字，故按实际值匹配；
# 且 servconf.c 以 “%s %s” 组装该串，无参数时末尾多一个空格，先裁掉再比对）、
# 以及旧式 scp 协议的 “scp -f 家目录内配置包” 下载（Win10/11 自带 OpenSSH ≤8.x，
# 客户端发的是相对路径，需折算到家目录）。其余一切一律拒绝；不使用 eval。
render_pkg_dl_wrapper() {
    local sftp_bin=${1:-}
    printf '#!/bin/sh\n'
    printf '# 由 server-frp-gost 安装器生成：一次性下载账号仅可取包，禁止 shell/上传/其他命令。\n'
    printf 'SFTP_BIN=%s\n' "${sftp_bin:-}"
    cat <<'WRAPPER'
set -u
deny() {
    printf '此账号仅允许下载配置包，禁止其他命令。\n' >&2
    exit 1
}
home=${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}
[ -n "$home" ] || deny
cmd=${SSH_ORIGINAL_COMMAND:-}
# sshd ≥9.6 以 “命令 参数…” 组装 subsystem 命令串，无参数时末尾多一个空格；
# 先裁掉尾部空格再做精确匹配。
while :; do
    case $cmd in
        *\ ) cmd=${cmd% } ;;
        *) break ;;
    esac
done
case $cmd in
    sftp|internal-sftp|"$SFTP_BIN")
        [ -n "$SFTP_BIN" ] && [ -x "$SFTP_BIN" ] || deny
        # -R：sftp 只读（仅可下载，禁止上传/改名/删除）。
        exec "$SFTP_BIN" -R
        ;;
esac
case $cmd in
    scp\ -f\ *) ;;
    *) deny ;;
esac
# -f 关闭路径通配展开，防止 “scp -f *” 借 glob 选取家目录内文件。
set -f
set -- $cmd
[ "$1" = scp ] || deny
shift
while [ $# -gt 1 ]; do
    case $1 in
        -f|-d|-r|-p|-v|-T) shift ;;
        *) deny ;;
    esac
done
[ $# -eq 1 ] || deny
path=$1
case $path in
    "$home"/?*) rest=${path#"$home"/} ;;
    ?*) rest=$path; path="$home/$path" ;;
    *) deny ;;
esac
case $rest in
    *[!A-Za-z0-9._-]*) deny ;;
esac
case $rest in
    .*|*..*) deny ;;
esac
[ -f "$path" ] || deny
# scp 经 PATH 解析（sshd 为会话提供安全默认 PATH）。
exec scp -f "$path"
WRAPPER
}

# 为下载账号安装 SSH 侧限制：专用组 pkgdl + sshd_config 末尾追加 Match 段
# （末尾追加避免吞入后续全局配置；先 sshd -t 校验基线与结果，失败即回滚）。
# 任何一步不可靠都返回 1，调用方将不创建账号、回退 root 下载通道。
# SSHD_CONFIG_PATH / PKG_DL_WRAPPER_PATH 仅为离线测试提供覆盖点，默认为系统路径。
install_pkg_dl_restriction() {
    local sftp_bin marker='# server-frp-gost pkg-dl-restriction (download-only accounts)'
    local sshd_config=${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}
    local wrapper_dest=${PKG_DL_WRAPPER_PATH:-/usr/local/sbin/pkg-dl-command}
    command -v sshd >/dev/null 2>&1 || return 1
    sshd -t >/dev/null 2>&1 || return 1
    getent group pkgdl >/dev/null 2>&1 || groupadd --system pkgdl || return 1
    # sshd ≥9.6 以 “%s %s” 组装 subsystem 命令串，dump（sshd -T）与
    # SSH_ORIGINAL_COMMAND 里的该串在无参数时末尾都带一个空格，先裁掉再比对。
    sftp_bin=$(sshd -T 2>/dev/null | sed -n 's/^subsystem sftp //p' | head -1 | sed 's/[[:space:]]*$//')
    case $sftp_bin in ''|internal-sftp) sftp_bin=/usr/lib/openssh/sftp-server ;; esac
    [ -x "$sftp_bin" ] || sftp_bin=
    render_pkg_dl_wrapper "$sftp_bin" > "$WORK_DIR/pkg-dl-command" || return 1
    install -m 755 "$WORK_DIR/pkg-dl-command" "$wrapper_dest" || return 1
    if grep -Fqx "$marker" "$sshd_config" 2>/dev/null; then
        return 0
    fi
    [ -f "$sshd_config" ] || { rm -f "$wrapper_dest"; return 1; }
    cp -a "$sshd_config" "$WORK_DIR/sshd_config.backup" || { rm -f "$wrapper_dest"; return 1; }
    [ -n "$(tail -c 1 "$sshd_config")" ] && printf '\n' >> "$sshd_config"
    cat >> "$sshd_config" <<MATCH
$marker
Match Group pkgdl
    ForceCommand $wrapper_dest
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    GatewayPorts no
MATCH
    if ! sshd -t >/dev/null 2>&1; then
        cp -a "$WORK_DIR/sshd_config.backup" "$sshd_config"
        rm -f "$wrapper_dest"
        return 1
    fi
    if ! systemctl reload ssh >/dev/null 2>&1 && ! systemctl reload sshd >/dev/null 2>&1; then
        cp -a "$WORK_DIR/sshd_config.backup" "$sshd_config"
        rm -f "$wrapper_dest"
        sshd -t >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# 持久化的 25 小时清理模板单元（瞬态 systemd-run 定时器重启即丢）：
# 先 terminate-user 清掉存活会话/进程，再 userdel -r，避免删除被驻留进程卡死。
write_pkg_dl_cleanup_units() {
    [ -f /etc/systemd/system/pkg-dl-cleanup@.service ] && [ -f /etc/systemd/system/pkg-dl-cleanup@.timer ] && return 0
    cat > /etc/systemd/system/pkg-dl-cleanup@.service <<'UNIT'
[Unit]
Description=Remove one-time download account %i (server-frp-gost)

[Service]
Type=oneshot
ExecStart=-loginctl terminate-user %i
ExecStart=userdel -r %i
ExecStartPost=-systemctl disable --now pkg-dl-cleanup@%i.timer
UNIT
    cat > /etc/systemd/system/pkg-dl-cleanup@.timer <<'UNIT'
[Unit]
Description=25h auto cleanup for download account %i (server-frp-gost)

[Timer]
OnActiveSec=25h
AccuracySec=1min
Unit=pkg-dl-cleanup@%i.service

[Install]
WantedBy=timers.target
UNIT
    chmod 644 /etc/systemd/system/pkg-dl-cleanup@.service /etc/systemd/system/pkg-dl-cleanup@.timer
    systemctl daemon-reload
}

# 首次安装完成后生成仅含配置包的一次性低权下载账号，住宅机无需得知 root 密码。
# 账号经 sshd 限定为仅可取包（无交互 shell、无转发）；次日过期，25 小时后由
# 持久化 systemd 定时器删除，链路验证通过后立即撤销；环境不支持则回退 root SFTP。
create_temp_download_account() {
    local package=$1 user password digest
    if [ "$(id -u)" != 0 ] || [ "$(uname -s)" != Linux ] ||
        ! command -v useradd >/dev/null || ! command -v chpasswd >/dev/null; then
        printf '未创建临时下载账号（当前环境不支持）；请在住宅机执行：scp root@%s:/root/%s .\n' "${PUBLIC_IP:-<VPS_IP>}" "$package"
        return 0
    fi
    if ! install_pkg_dl_restriction; then
        printf '未创建临时下载账号（无法安装 SSH 下载专用限制，已回滚任何改动）；请用 root 下载：scp root@%s:/root/%s .\n' "${PUBLIC_IP:-<VPS_IP>}" "$package"
        return 0
    fi
    user="pkg$(python3 -I -c 'import secrets; print(secrets.token_hex(3))')"
    password=$(python3 -I -c 'import secrets; print("".join(secrets.choice("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(20)))')
    useradd -m -g pkgdl -s /bin/bash "$user" || fail '创建临时下载账号失败；配置包仍在 /root/ 下，可用 root SFTP 下载。'
    usermod -e "$(date -d '+1 day' +%F)" "$user" 2>/dev/null ||
        printf '注意：临时账号未能设置过期日期，仅依赖自动删除。\n'
    chmod 750 "/home/$user"
    install -o "$user" -g pkgdl -m 600 "/root/$package" "/home/$user/$package"
    printf '%s:%s\n' "$user" "$password" | chpasswd
    write_pkg_dl_cleanup_units
    systemctl enable --now "pkg-dl-cleanup@$user.timer" >/dev/null 2>&1 ||
        printf '注意：自动清理定时器启用失败；账号仍将于明日过期，请手动 userdel -r %s。\n' "$user"
    # 记录账号名供验证通过后（含事后 --verify）立即撤销；不影响 25 小时兜底删除。
    printf 'DOWNLOAD_USER=%s\n' "$user" >> "$CONFIG_DIR/client-verify.env"
    digest=$(sha256sum "/root/$package" | awk '{print $1}')
    printf '\n═══ 住宅机下载配置包（按步骤逐步复制执行）═══\n'
    if [ "$CLIENT_PLATFORM" != mac ]; then
        printf '第 1 步 · 在 Windows 住宅机打开 PowerShell，下面整行复制执行（下载完自动校验）：\n'
        printf '  scp %s@%s:%s "$env:USERPROFILE\\Downloads\\"; Get-FileHash "$env:USERPROFILE\\Downloads\\%s" -Algorithm SHA256\n' "$user" "$PUBLIC_IP" "$package" "$package"
    fi
    if [ "$CLIENT_PLATFORM" = mac ] || [ -z "$CLIENT_PLATFORM" ]; then
        printf '第 1 步 · 在 Mac 住宅机打开终端，下面整行复制执行（下载完自动校验）：\n'
        printf '  scp %s@%s:%s ~/Downloads/ && shasum -a 256 ~/Downloads/%s\n' "$user" "$PUBLIC_IP" "$package" "$package"
    fi
    printf '第 2 步 · 首次连接询问 yes/no 时输入 yes\n'
    printf '第 3 步 · 出现 Password: 提示时，复制下面这一行粘贴后回车（屏幕不回显属正常保护）：\n'
    printf '  密码：%s\n' "$password"
    printf '第 4 步 · 核对第 1 步命令末尾输出的 SHA-256 与下面一致：\n'
    printf '  %s\n' "$digest"
    printf '（已装 WinSCP 的机器可跳过以上步骤：把下面整行粘到 WinSCP 登录界面的 URL 框；勿用浏览器打开）\n'
    printf '  sftp://%s:%s@%s/%s\n' "$user" "$password" "$PUBLIC_IP" "$package"
    printf '手动填表用地址：sftp://%s@%s/%s（端口 22，协议 SFTP）\n' "$user" "$PUBLIC_IP" "$package"
    printf '临时账号经 SSH 限定为仅可下载本配置包（无交互 shell、无端口转发）。\n'
    printf '次日过期；25 小时后自动删除（定时器已持久化，重启不丢失）；链路验证通过后立即删除。\n'
    printf '密码仅此处显示一次，不写入任何文件；立即撤销账号：userdel -r %s\n' "$user"
    printf '若 SSH 已禁用密码登录，此账号无法使用，请改用 root 密钥下载 /root/%s。\n' "$package"
}

# 链路验证全部通过后立即撤销临时下载账号：停用清理定时器、终止其全部会话/进程
# （否则驻留进程会卡死 userdel -r）、删除账号与家目录；删除失败则先锁定账号再提示。
# 验证未通过/未运行时不调用，下载通道保留供重试，到期仍由定时器兜底删除。
# /root/ 下的配置包保留（仅 root 可读），住宅机重装时可用 root SFTP 重新下载。
revoke_temp_download_account() {
    local user
    [ -f "${CONFIG_DIR:-}/client-verify.env" ] || return 0
    user=$(sed -n 's/^DOWNLOAD_USER=//p' "$CONFIG_DIR/client-verify.env")
    [ -n "$user" ] || return 0
    if ! [[ "$user" =~ ^pkg[a-f0-9]{6}$ ]]; then
        printf '  NOTE 未清理下载账号：client-verify.env 中的 DOWNLOAD_USER 格式异常\n'
        return 0
    fi
    systemctl disable --now "pkg-dl-cleanup@$user.timer" >/dev/null 2>&1 || true
    loginctl terminate-user "$user" >/dev/null 2>&1 || true
    if id "$user" >/dev/null 2>&1; then
        if userdel -r "$user" >/dev/null 2>&1 ||
            { sleep 2; userdel -r "$user" >/dev/null 2>&1; }; then
            printf '  CLEAN 已删除临时下载账号 %s 及其家目录，下载通道关闭\n' "$user"
        else
            usermod -L "$user" >/dev/null 2>&1 || true
            printf '  NOTE 账号 %s 已锁定但删除失败，请手动执行：userdel -r %s\n' "$user" "$user"
            return 0
        fi
    else
        printf '  CLEAN 临时下载账号 %s 已不存在（过期或已手动撤销）\n' "$user"
    fi
    grep -v '^DOWNLOAD_USER=' "$CONFIG_DIR/client-verify.env" > "$CONFIG_DIR/client-verify.env.tmp" &&
        mv "$CONFIG_DIR/client-verify.env.tmp" "$CONFIG_DIR/client-verify.env" &&
        chmod 600 "$CONFIG_DIR/client-verify.env"
}

# 等待住宅机安装并端到端验证反向链路：只读探测本机回环映射与 SOCKS 认证，
# 不修改任何服务。wait_min 为等待住宅机连接的最长分钟数（0 表示仅检查一次）。
verify_residential() {
    local scheme=$1 platform=$2 user=$3 pass=$4 vps_ip=$5 wait_min=${6:-30}
    local waited=0 bound egress endpoint check_result=0
    info '等待住宅机安装并建立反向隧道（每 5 秒检查 10001，可 Ctrl+C 退出）'
    while ! ss -H -ltn 'sport = :10001' | grep -q .; do
        [ "$waited" -lt $((wait_min * 60)) ] || fail "等待超时（${wait_min} 分钟）：10001 尚未监听。请确认住宅机已完成安装；稍后可重新运行 --verify"
        sleep 5
        waited=$((waited + 5))
        printf '\r  已等待 %d 分 %02d 秒 ...' $((waited / 60)) $((waited % 60))
    done
    printf '\n==> 住宅机已连接；开始端到端验证（仅本机只读探测）\n'
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
            printf '  PASS 服务端 %s 运行中\n' "$SERVICE"
        else
            printf '  FAIL 服务端 %s 未运行\n' "$SERVICE"
            check_result=1
        fi
    else
        printf '  NOTE 无 systemd，跳过服务状态检查\n'
    fi
    bound=$(ss -H -ltn 'sport = :10001' | awk '{for (i = 1; i <= NF; i++) if ($i ~ /:10001$/) {print $i; exit}}')
    if [ "$bound" = '127.0.0.1:10001' ]; then
        printf '  PASS SOCKS 映射仅监听回环 127.0.0.1:10001\n'
    else
        printf '  FAIL SOCKS 映射监听地址异常：%s（应为 127.0.0.1:10001；若为 0.0.0.0 属公网暴露，立即检查服务端配置）\n' "${bound:-未监听}"
        check_result=1
    fi
    if [ "$platform" = windows ]; then
        if ss -H -ltn 'sport = :33389' | grep -q .; then
            bound=$(ss -H -ltn 'sport = :33389' | awk '{for (i = 1; i <= NF; i++) if ($i ~ /:33389$/) {print $i; exit}}')
            if [ "$bound" = '127.0.0.1:33389' ]; then
                printf '  PASS RDP 映射仅监听回环 127.0.0.1:33389\n'
            else
                printf '  FAIL RDP 映射监听地址异常：%s（应为 127.0.0.1:33389）\n' "$bound"
                check_result=1
            fi
        else
            printf '  NOTE 33389 暂未监听（住宅机未注册 RDP 映射；不影响 SOCKS 验证）\n'
        fi
    fi
    if curl -4 -s --max-time 15 --socks5-hostname 127.0.0.1:10001 https://api.ipify.org >/dev/null 2>&1; then
        printf '  FAIL 匿名 SOCKS5 请求未被拒绝\n'
        check_result=1
    else
        printf '  PASS 匿名 SOCKS5 被拒绝\n'
    fi
    if curl -4 -s --max-time 15 --socks5-hostname 127.0.0.1:10001 --proxy-user 'verify_wrong:verify_wrong' https://api.ipify.org >/dev/null 2>&1; then
        printf '  FAIL 错误密码未被拒绝\n'
        check_result=1
    else
        printf '  PASS 错误密码被拒绝\n'
    fi
    egress=
    for endpoint in https://api.ipify.org https://ifconfig.me/ip; do
        egress=$(curl -4 -s --max-time 20 --socks5-hostname 127.0.0.1:10001 --proxy-user "$user:$pass" "$endpoint" 2>/dev/null) || egress=
        if [ -n "$egress" ]; then break; fi
    done
    if [ -z "$egress" ]; then
        printf '  FAIL 正确凭据经隧道访问失败（检查住宅机日志、两端证书与账号密码）\n'
        check_result=1
    elif [ "$egress" = "$vps_ip" ]; then
        printf '  FAIL 出口 IP 等于 VPS IP（%s），流量未走住宅出口\n' "$egress"
        check_result=1
    else
        printf '  PASS 正确凭据经住宅出口访问成功（出口 IP：%s；VPS IP：%s）\n' "$egress" "$vps_ip"
    fi
    if [ "$check_result" != 0 ]; then
        printf '\n验证未全部通过：请处理上方 FAIL 项。本次验证未修改任何服务配置。\n'
        return 1
    fi
    printf '\n全部通过：VPS 回环 10001 → 反向隧道 → 住宅 SOCKS 认证 → 住宅出口。\n'
    revoke_temp_download_account
    printf '未包含：S-UI 出站切换、RDP 实际登录、住宅机服务/ACL 状态（需在住宅机另行检查）。\n'
    printf '配置包仍保留在 /root/ 下（仅 root 可读）；住宅机重装时可用 root SFTP 重新下载。\n'
}

new_install() {
    PUBLIC_IP=$(public_ipv4)
    AUTH_TOKEN=$(random_secret)
    RELAY_USER="relay_$(random_secret 6)"
    RELAY_PASS=$(random_secret)
    GOST_USER="user_$(random_secret 6)"
    GOST_PASS=$(random_secret)
    mkdir -m 700 "$WORK_DIR/config"
    generate_certs "$WORK_DIR/config/certs" "$PUBLIC_IP"
    local template package staged_config flag client_prefix=windows
    [ "${CLIENT_PLATFORM:-windows}" != mac ] || client_prefix=macos
    package=$(client_package_name "$SCHEME" "${CLIENT_PLATFORM:-windows}")
    if [ "$SCHEME" = gost ]; then
        template="$REPO_ROOT/01_Pure_GOST_v3/${client_prefix}_client_gost_v3"
        flag=-C
        render_gost_server "$WORK_DIR/config" "$RELAY_USER" "$RELAY_PASS" > "$WORK_DIR/gost-check.yaml"
        validate_config "$CORE_BINARY" "$WORK_DIR/gost-check.yaml"
        render_gost_server "$CONFIG_DIR" "$RELAY_USER" "$RELAY_PASS" > "$WORK_DIR/config/gost.yaml"
        staged_config="$WORK_DIR/config/gost.yaml"
    else
        template="$REPO_ROOT/02_FRP_GOST/${client_prefix}_client_frp_gost"
        flag=-c
        # FRPS verify 会检查证书路径，先用临时路径验证同一组配置字段。
        render_frps_server "$WORK_DIR/config" "$AUTH_TOKEN" > "$WORK_DIR/frps-check.toml"
        validate_config "$CORE_BINARY" "$WORK_DIR/frps-check.toml"
        render_frps_server "$CONFIG_DIR" "$AUTH_TOKEN" > "$WORK_DIR/config/frps.toml"
        staged_config="$WORK_DIR/config/frps.toml"
    fi
    info "构建 ${CLIENT_PLATFORM} 离线包：组件在 VPS 下载、校验并内置；元数据或摘要缺失即终止"
    if [ "$CLIENT_PLATFORM" = mac ]; then
        build_macos_package "$template" "$package" "$WORK_DIR/config/certs"
    else
        build_windows_package "$template" "$package" "$WORK_DIR/config/certs"
    fi
    write_unit "$SERVICE" "$BINARY" "$CONFIG" "$flag"
    # 所有网络下载/打包成功后才写入部署路径；首次安装拒绝已有配置。
    install -d -m 700 "$CONFIG_DIR"
    cp -R "$WORK_DIR/config/certs" "$CONFIG_DIR/"
    install -m 600 "$staged_config" "$CONFIG"
    install -m 755 "$CORE_BINARY" "$BINARY"
    validate_config "$BINARY" "$CONFIG"
    install -m 600 "$WORK_DIR/$package" "/root/$package"
    # 保存住宅机 SOCKS 凭据与平台（root 只读），供后续 --verify 自动验证使用。
    printf 'GOST_USER=%s\nGOST_PASS=%s\nCLIENT_PLATFORM=%s\n' "$GOST_USER" "$GOST_PASS" "$CLIENT_PLATFORM" > "$CONFIG_DIR/client-verify.env"
    chmod 600 "$CONFIG_DIR/client-verify.env"
    install -m 644 "$WORK_DIR/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    wait_service "$SERVICE" || fail "服务启动失败，请检查 journalctl -u $SERVICE"
    info '服务端已启动；尚未验证住宅机连接'
    printf '客户端安装包：/root/%s（住宅机 %s；完整离线包；含客户端私钥，请妥善保管）\n' "$package" "$CLIENT_PLATFORM"
    printf '这是完整离线包；组件已在 VPS 下载、校验并内置，住宅机安装时无需联网下载组件。\n'
    if [ "$CLIENT_PLATFORM" = mac ]; then
        printf 'Mac 完整解压后，使用普通账号执行 sudo bash setup_macos.sh；无需 Servy。\n'
    fi
    printf '配置包同时保留在 /root/ 下，可随时用 root SFTP 下载。\n'
    create_temp_download_account "$package"
    printf '\nS-UI SOCKS 出站：127.0.0.1:10001\n账号：%s\n密码：%s\n' "$GOST_USER" "$GOST_PASS"
    printf '\nSOCKS 映射仅监听 VPS 回环地址 127.0.0.1:10001。\n'
    if [ "$CLIENT_PLATFORM" = windows ]; then
        printf 'RDP 映射仅监听 VPS 回环地址。先在自己的电脑建立 SSH 转发：\n  ssh -N -L 13389:127.0.0.1:33389 root@%s\n再连接 127.0.0.1:13389。\n' "$PUBLIC_IP"
    else
        printf 'Mac 不建立 Windows RDP 映射，不自动开启远程登录、屏幕共享或防睡眠。\n'
    fi
    printf '安装过程未修改 S-UI、防火墙、IPv6 或其他主机网络配置。\n'
    printf '唯一例外：为一次性下载账号在 sshd_config 末尾追加了 Match 限制段（先备份、sshd -t 校验，失败自动回滚）。\n'
    if printf '\n是否现在等待住宅机安装并自动验证链路？验证通过将立即删除临时下载账号 [y/N]：' >/dev/tty 2>/dev/null; then
        local answer=''
        read -r answer </dev/tty || answer=''
        if [ "$answer" = y ] || [ "$answer" = Y ]; then
            verify_residential "$SCHEME" "$CLIENT_PLATFORM" "$GOST_USER" "$GOST_PASS" "$PUBLIC_IP" "${VERIFY_TIMEOUT_MIN:-30}" ||
                printf '验证未通过或超时；服务端安装本身已完成，可稍后运行 bash install.sh %s --verify 重试。\n' "$SCHEME"
        fi
    else
        printf '住宅机安装完成后，可随时运行：bash install.sh %s --verify\n' "$SCHEME"
    fi
}

deploy_main() {
    SCHEME=$1; shift
    local action=install requested=latest
    CLIENT_PLATFORM=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --upgrade|-u|upgrade) action=upgrade ;;
            --verify) action=verify ;;
            --version) shift; [ "$#" -gt 0 ] || fail '--version 缺少版本'; requested=$1 ;;
            --offline) : ;; # 离线包已是默认且唯一模式；保留参数兼容旧命令
            --client)
                shift; [ "$#" -gt 0 ] || fail '--client 缺少 windows 或 mac'
                case "$1" in windows|mac|macos) CLIENT_PLATFORM=$(client_platform_from_choice "$1") ;; *) fail '--client 只能是 windows 或 mac' ;; esac ;;
            --help|-h)
                printf '用法：bash install.sh %s [--client windows|mac] [--version vX.Y.Z]\n' "$SCHEME"
                printf '      bash install.sh %s --upgrade [--version vX.Y.Z]\n首次安装先选择方案，再选择住宅机系统；非交互使用 --client。安装包为完整离线包：组件已在 VPS 下载、校验并内置。\n' "$SCHEME"
                printf '      bash install.sh %s --verify\n等待住宅机安装并自动验证反向链路（VERIFY_TIMEOUT_MIN 可覆盖默认 30 分钟）。\n' "$SCHEME"
                return ;;
            *) fail "不支持的参数：$1" ;;
        esac
        shift
    done
    if [ "$action" = upgrade ] && [ -n "$CLIENT_PLATFORM" ]; then fail '--client 仅用于首次安装；--upgrade 不切换住宅机系统或重打包'; fi
    if [ "$action" = verify ] && [ -n "$CLIENT_PLATFORM" ]; then fail '--verify 不重新选择住宅机系统；不能与 --client 同用'; fi
    [ "$(uname -s)" = Linux ] || fail '部署仅支持 Linux；本机不要执行生产安装'
    [ "$(id -u)" = 0 ] || fail '请使用 root 或 sudo bash 运行'
    command -v systemctl >/dev/null && [ -d /run/systemd/system ] || fail '需要正在运行的 systemd'
    command -v flock >/dev/null || fail '需要 util-linux 提供的 flock'
    exec 9>/run/server-frp-gost.lock
    flock -n 9 || fail '另一个安装/升级任务正在运行'
    ARCH=$(linux_arch)
    if [ "$SCHEME" = gost ]; then
        SERVICE=gost; BINARY=/usr/local/bin/gost; CONFIG_DIR=/etc/gost; CONFIG=/etc/gost/gost.yaml
    elif [ "$SCHEME" = frp ]; then
        SERVICE=frps; BINARY=/usr/local/bin/frps; CONFIG_DIR=/etc/frp; CONFIG=/etc/frp/frps.toml
        if [ "$action" = upgrade ] && [ ! -f "$CONFIG" ] && [ -f /root/frp/frps.toml ]; then
            BINARY=/root/frp/frps; CONFIG_DIR=/root/frp; CONFIG=/root/frp/frps.toml
        fi
    else
        fail '未知方案'
    fi
    if [ "$action" = install ]; then
        if [ -z "$CLIENT_PLATFORM" ]; then CLIENT_PLATFORM=$(select_client_platform); fi
        [ ! -e /etc/gost ] && [ ! -e /etc/frp ] && [ ! -e /root/frp ] || fail '发现已有隧道配置目录；拒绝重装、换方案或重新签发证书。请先备份并人工迁移'
        ! systemctl cat gost >/dev/null 2>&1 || fail '已有 gost 服务，拒绝覆盖'
        ! systemctl cat frps >/dev/null 2>&1 || fail '已有 frps 服务，拒绝覆盖'
        [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] || fail "已有 ${BINARY}，拒绝覆盖"
        local package_path
        package_path="/root/$(client_package_name "$SCHEME" "$CLIENT_PLATFORM")"
        [ ! -e "$package_path" ] && [ ! -L "$package_path" ] || fail "已有 ${package_path}，请先自行检查备份，拒绝覆盖"
    else
        [ -f "$BINARY" ] && [ -f "$CONFIG" ] || fail '未找到已安装的对应方案，不能升级'
        systemctl show "$SERVICE" --property=ExecStart --value | grep -F "path=$BINARY ;" >/dev/null || fail 'systemd 服务可执行路径与预期不符，拒绝替换'
    fi
    if [ "$action" = verify ]; then
        local verify_user verify_pass verify_platform
        [ -f "$CONFIG_DIR/client-verify.env" ] || fail '此部署未存储住宅机凭据（早于验证功能的安装）。手动验证示例：curl -4 --socks5-hostname 127.0.0.1:10001 --proxy-user 用户:密码 https://api.ipify.org'
        verify_user=$(sed -n 's/^GOST_USER=//p' "$CONFIG_DIR/client-verify.env")
        verify_pass=$(sed -n 's/^GOST_PASS=//p' "$CONFIG_DIR/client-verify.env")
        verify_platform=$(sed -n 's/^CLIENT_PLATFORM=//p' "$CONFIG_DIR/client-verify.env")
        [[ "$verify_user" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$verify_pass" =~ ^[A-Za-z0-9_]+$ ]] || fail 'client-verify.env 中的凭据格式无效'
        case "$verify_platform" in windows|mac) ;; *) fail 'client-verify.env 中的住宅机平台无效' ;; esac
        PUBLIC_IP=$(public_ipv4)
        verify_residential "$SCHEME" "$verify_platform" "$verify_user" "$verify_pass" "$PUBLIC_IP" "${VERIFY_TIMEOUT_MIN:-30}"
        return
    fi
    umask 077
    WORK_DIR=$(mktemp -d)
    UPGRADE_PENDING=0
    trap cleanup_deploy EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    install_dependencies "$action"
    if [ "$action" = install ]; then
        local port ports='9000 10001'
        [ "$CLIENT_PLATFORM" != windows ] || ports="$ports 33389"
        for port in $ports; do
            if ss -H -ltn "sport = :$port" | grep -q .; then fail "端口 $port 已被占用，拒绝安装"; fi
        done
    fi
    prepare_binary "$requested"
    if [ "$action" = upgrade ]; then upgrade_binary; else new_install; fi
}
