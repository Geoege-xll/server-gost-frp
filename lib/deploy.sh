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
    if ! command -v 7z >/dev/null && ! command -v 7zz >/dev/null; then
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
    cat <<TOML
bindAddr = "$bind"
bindPort = $port
proxyBindAddr = "127.0.0.1"
allowPorts = [{ single = 10001 }, { single = 33389 }]
maxPortsPerClient = 2
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
    printf '未更新 Windows 客户端或旧离线包；跨版本升级前请检查两端兼容性。\n'
}

build_windows_package() {
    local template=$1 package=$2 certs=$3 tag version asset file sevenzip suffix
    if [ "$SCHEME" = gost ]; then suffix=gost_v3; else suffix=frp_gost; fi
    for file in "setup_$suffix.ps1" "uninstall_$suffix.ps1" '一键安装(以管理员运行).bat' '一键卸载(以管理员运行).bat' 'README_住宅机安装说明.txt'; do
        [ -s "$template/$file" ] || fail "缺少 Windows 模板：$file"
    done
    mkdir -m 700 "$WORK_DIR/package"
    cp "$template/"* "$WORK_DIR/package/"
    cp "$certs/ca.crt" "$certs/client.crt" "$certs/client.key" "$WORK_DIR/package/"
    if [ "$SCHEME" = frp ]; then
        tag=$CORE_TAG
        version=${tag#v}
        asset="frp_${version}_windows_amd64.zip"
        download_asset "$WORK_DIR/core-release.json" fatedier/frp "$asset" "$WORK_DIR/frpc.zip"
        extract_asset "$WORK_DIR/frpc.zip" "$WORK_DIR/frpc"
        file=$(find_one "$WORK_DIR/frpc" frpc.exe)
        cp "$file" "$WORK_DIR/package/frpc.exe"
        tag=$(release_info go-gost/gost latest "$WORK_DIR/gost-release.json")
    else
        cp "$WORK_DIR/core-release.json" "$WORK_DIR/gost-release.json"
        tag=$CORE_TAG
    fi
    version=${tag#v}
    asset="gost_${version}_windows_amd64.zip"
    download_asset "$WORK_DIR/gost-release.json" go-gost/gost "$asset" "$WORK_DIR/gost.zip"
    extract_asset "$WORK_DIR/gost.zip" "$WORK_DIR/gost-windows"
    file=$(find_one "$WORK_DIR/gost-windows" gost.exe)
    cp "$file" "$WORK_DIR/package/gost.exe"
    tag=$(release_info aelassas/servy latest "$WORK_DIR/servy-release.json")
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
    # 保留实际组件版本，避免升级后误发旧包。
    printf 'Tunnel: %s %s\nGOST: %s\nServy: %s\nWindows architecture: amd64\n' \
        "$SCHEME" "$CORE_TAG" "$(python3 -I "$REPO_ROOT/lib/release.py" tag "$WORK_DIR/gost-release.json")" "$tag" \
        > "$WORK_DIR/package/VERSIONS.txt"
    (cd "$WORK_DIR/package" && zip -q -r "$WORK_DIR/$package" .)
    unzip -tq "$WORK_DIR/$package" >/dev/null
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
    local template package staged_config flag
    if [ "$SCHEME" = gost ]; then
        template="$REPO_ROOT/01_Pure_GOST_v3/windows_client_gost_v3"
        package=windows_gost_v3_pkg.zip
        flag=-C
        render_gost_server "$WORK_DIR/config" "$RELAY_USER" "$RELAY_PASS" > "$WORK_DIR/gost-check.yaml"
        validate_config "$CORE_BINARY" "$WORK_DIR/gost-check.yaml"
        render_gost_server "$CONFIG_DIR" "$RELAY_USER" "$RELAY_PASS" > "$WORK_DIR/config/gost.yaml"
        staged_config="$WORK_DIR/config/gost.yaml"
    else
        template="$REPO_ROOT/02_FRP_GOST/windows_client_frp_gost"
        package=windows_frp_gost_pkg.zip
        flag=-c
        # FRPS verify 会检查证书路径，先用临时路径验证同一组配置字段。
        render_frps_server "$WORK_DIR/config" "$AUTH_TOKEN" > "$WORK_DIR/frps-check.toml"
        validate_config "$CORE_BINARY" "$WORK_DIR/frps-check.toml"
        render_frps_server "$CONFIG_DIR" "$AUTH_TOKEN" > "$WORK_DIR/config/frps.toml"
        staged_config="$WORK_DIR/config/frps.toml"
    fi
    info '构建离线包：任何下载、摘要校验或必需组件缺失都会终止'
    build_windows_package "$template" "$package" "$WORK_DIR/config/certs"
    write_unit "$SERVICE" "$BINARY" "$CONFIG" "$flag"
    # 所有网络下载/打包成功后才写入部署路径；首次安装拒绝已有配置。
    install -d -m 700 "$CONFIG_DIR"
    cp -R "$WORK_DIR/config/certs" "$CONFIG_DIR/"
    install -m 600 "$staged_config" "$CONFIG"
    install -m 755 "$CORE_BINARY" "$BINARY"
    validate_config "$BINARY" "$CONFIG"
    install -m 600 "$WORK_DIR/$package" "/root/$package"
    install -m 644 "$WORK_DIR/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    wait_service "$SERVICE" || fail "服务启动失败，请检查 journalctl -u $SERVICE"
    info '服务端已启动；尚未验证住宅机连接'
    printf '客户端离线包：/root/%s（含客户端私钥，请妥善保管）\n' "$package"
    printf '使用 WinSCP / SFTP 下载，或在你自己的电脑执行：\n  scp root@%s:/root/%s .\n' "$PUBLIC_IP" "$package"
    printf '\nS-UI SOCKS 出站：127.0.0.1:10001\n账号：%s\n密码：%s\n' "$GOST_USER" "$GOST_PASS"
    printf '\n业务端口与 RDP 映射默认仅监听 VPS 回环地址。\n'
    printf '远程桌面请先在自己的电脑建立 SSH 转发：\n  ssh -N -L 13389:127.0.0.1:33389 root@%s\n再连接 127.0.0.1:13389。\n' "$PUBLIC_IP"
    printf '安装过程未修改 S-UI、防火墙、IPv6 或其他主机网络配置。\n'
}

deploy_main() {
    SCHEME=$1; shift
    local action=install requested=latest
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --upgrade|-u|upgrade) action=upgrade ;;
            --version) shift; [ "$#" -gt 0 ] || fail '--version 缺少版本'; requested=$1 ;;
            --help|-h)
                printf '用法：bash install.sh %s [--upgrade] [--version vX.Y.Z]\n' "$SCHEME"
                return ;;
            *) fail "不支持的参数：$1" ;;
        esac
        shift
    done
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
        [ ! -e /etc/gost ] && [ ! -e /etc/frp ] && [ ! -e /root/frp ] || fail '发现已有隧道配置目录；拒绝重装、换方案或重新签发证书。请先备份并人工迁移'
        ! systemctl cat gost >/dev/null 2>&1 || fail '已有 gost 服务，拒绝覆盖'
        ! systemctl cat frps >/dev/null 2>&1 || fail '已有 frps 服务，拒绝覆盖'
        [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] || fail "已有 ${BINARY}，拒绝覆盖"
        local package_path=/root/windows_gost_v3_pkg.zip
        [ "$SCHEME" != frp ] || package_path=/root/windows_frp_gost_pkg.zip
        [ ! -e "$package_path" ] && [ ! -L "$package_path" ] || fail "已有 ${package_path}，请先自行检查备份，拒绝覆盖"
    else
        [ -f "$BINARY" ] && [ -f "$CONFIG" ] || fail '未找到已安装的对应方案，不能升级'
        systemctl show "$SERVICE" --property=ExecStart --value | grep -F "path=$BINARY ;" >/dev/null || fail 'systemd 服务可执行路径与预期不符，拒绝替换'
    fi
    umask 077
    WORK_DIR=$(mktemp -d)
    UPGRADE_PENDING=0
    trap cleanup_deploy EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    install_dependencies "$action"
    if [ "$action" = install ]; then
        local port
        for port in 9000 10001 33389; do
            if ss -H -ltn "sport = :$port" | grep -q .; then fail "端口 $port 已被占用，拒绝安装"; fi
        done
    fi
    prepare_binary "$requested"
    if [ "$action" = upgrade ]; then upgrade_binary; else new_install; fi
}
