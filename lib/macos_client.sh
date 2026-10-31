#!/bin/bash
# macOS 12+, Bash 3.2. Definitions only: safe to source for fixture tests.

mc_die() { printf '错误：%s\n' "$*" >&2; return 1; }
mc_get() { /usr/bin/plutil -extract "$2" raw -expect "${3:-string}" -o - "$1"; }
mc_regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ] || mc_die "需要非空普通文件：$1"; }
mc_secret() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$1" != *PLACEHOLDER* ]] || mc_die '凭据必须为已注入的字母、数字或下划线'; }
mc_ipv4() {
    local ip=$1 part oldifs=$IFS
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=.; set -- $ip; IFS=$oldifs
    for part in "$@"; do
        [ "${#part}" -le 3 ] && [ "$part" = "$((10#$part))" ] && [ "$((10#$part))" -le 255 ] || return 1
    done
}
mc_arch() {
    # sysctl detects Apple Silicon even when this shell itself runs via Rosetta.
    case "${1:-$(/usr/bin/uname -m)}:${2:-$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)}" in
        arm64:*|aarch64:*|x86_64:1) printf 'arm64\n' ;;
        x86_64:*) printf 'amd64\n' ;;
        *) mc_die '仅支持原生 arm64 / amd64 Mac' ;;
    esac
}
mc_version() {
    local value=${1#v} minimum=$2 a b c x y z oldifs=$IFS
    [[ "$value" =~ ^[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?$ ]] || return 1
    case "$value" in *.*.*) ;; *) value=$value.0 ;; esac
    IFS=.; read -r a b c <<EOF
$value
EOF
    read -r x y z <<EOF
$minimum
EOF
    IFS=$oldifs
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
    [ "$a" -gt "$x" ] || { [ "$a" -eq "$x" ] && { [ "$b" -gt "$y" ] || { [ "$b" -eq "$y" ] && [ "$c" -ge "$z" ]; }; }; }
}
mc_read_conf() {
    local file=$1 key value count=0 seen='|'
    mc_regular "$file" || return 1
    while IFS= read -r value || [ -n "$value" ]; do
        [[ "$value" == *=* ]] || { mc_die 'client.conf 必须恰好包含六行 KEY=value'; return 1; }
        key=${value%%=*}; value=${value#*=}
        case "$seen" in *"|$key|"*) mc_die 'client.conf 包含重复键'; return 1 ;; esac
        seen="$seen$key|"; count=$((count + 1))
        case "$key" in
            VPS_PUBLIC_IP) mc_ipv4 "$value" || { mc_die '无效 IPv4'; return 1; }; MC_IP=$value ;;
            TOKEN) mc_secret "$value" || return 1; MC_TOKEN=$value ;;
            RELAY_USER) mc_secret "$value" || return 1; MC_RELAY_USER=$value ;;
            RELAY_PASS) mc_secret "$value" || return 1; MC_RELAY_PASS=$value ;;
            GOST_USER) mc_secret "$value" || return 1; MC_GOST_USER=$value ;;
            GOST_PASS) mc_secret "$value" || return 1; MC_GOST_PASS=$value ;;
            *) mc_die 'client.conf 包含未知键'; return 1 ;;
        esac
    done < "$file"
    [ "$count" -eq 6 ] || mc_die 'client.conf 必须恰好包含六个配置值'
}
mc_manifest() {
    local file=$1 scheme=$2 i=0 id arch repo version asset url digest expected total core
    mc_regular "$file" || return 1
    [ "$(mc_get "$file" schemaVersion integer)" = 1 ] &&
    [ "$(mc_get "$file" platform)" = macos ] &&
    [ "$(mc_get "$file" scheme)" = "$scheme" ] &&
    [ "$(mc_get "$file" architectures array)" = 2 ] &&
    [ "$(mc_get "$file" architectures.0)" = amd64 ] &&
    [ "$(mc_get "$file" architectures.1)" = arm64 ] || { mc_die '不兼容的 macOS 组件清单'; return 1; }
    [ "$(mc_get "$file" mode)" = offline ] || { mc_die '此安装脚本仅支持离线完整包'; return 1; }
    MC_TUNNEL_VERSION=$(mc_get "$file" tunnelVersion) || return 1
    total=2; core=gost; [ "$scheme" != frp ] || { total=4; core=frpc; }
    [ "$(mc_get "$file" components array)" = "$total" ] || return 1
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        for arch in amd64 arm64; do
            expected="components.$i"
            [ "$(mc_get "$file" "$expected" dictionary | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 7 ] || return 1
            [ "$(mc_get "$file" "$expected.id")" = "$id" ] &&
            [ "$(mc_get "$file" "$expected.architecture")" = "$arch" ] || return 1
            repo=$(mc_get "$file" "$expected.repo") || return 1
            version=$(mc_get "$file" "$expected.version") || return 1
            asset=$(mc_get "$file" "$expected.asset") || return 1
            url=$(mc_get "$file" "$expected.url") || return 1
            digest=$(mc_get "$file" "$expected.sha256") || return 1
            case "$id" in
                gost) [ "$repo" = go-gost/gost ] && mc_version "$version" 3.3.2 || return 1; expected="gost_${version#v}_darwin_${arch}.tar.gz" ;;
                frpc) [ "$repo" = fatedier/frp ] && mc_version "$version" 0.71.1 || return 1; expected="frp_${version#v}_darwin_${arch}.tar.gz" ;;
            esac
            [ "$asset" = "$expected" ] && [ "$url" = "https://github.com/$repo/releases/download/$version/$asset" ] &&
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { mc_die '组件来源、版本或摘要无效'; return 1; }
            [ "$id" != "$core" ] || [ "$version" = "$MC_TUNNEL_VERSION" ] || { mc_die '住宅机与 VPS 隧道版本不一致'; return 1; }
            # Both architectures of each component must have exactly the same tag.
            if [ "$arch" = amd64 ]; then
                if [ "$id" = gost ]; then MC_GOST_VERSION=$version; else MC_FRPC_VERSION=$version; fi
            elif [ "$id" = gost ]; then [ "$version" = "$MC_GOST_VERSION" ] || return 1
            else [ "$version" = "$MC_FRPC_VERSION" ] || return 1; fi
            i=$((i + 1))
        done
    done
}
mc_sha256() {
    local actual
    mc_regular "$1" || return 1
    [[ "$2" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(/usr/bin/shasum -a 256 "$1") || return 1
    [ "${actual%% *}" = "$2" ] || mc_die "SHA-256 不匹配：$1"
}
mc_macho() {
    local header expected
    header=$(/usr/bin/od -An -tx1 -N8 "$1" | /usr/bin/tr -d ' \n') || return 1
    case "$2" in amd64) expected=cffaedfe07000001 ;; arm64) expected=cffaedfe0c000001 ;; *) return 1 ;; esac
    [ "$header" = "$expected" ] || mc_die "不是预期架构的 64 位 Mach-O 可执行文件：$1"
}
mc_no_links() {
    local path=$1 current='' part
    case "$path" in /*) path=${path#/} ;; *) mc_die '路径必须为绝对路径'; return 1 ;; esac
    while :; do
        part=${path%%/*}
        case "$part" in ''|.|..) mc_die '不安全路径'; return 1 ;; esac
        current=$current/$part
        [ ! -L "$current" ] || { mc_die "拒绝链接路径：$current"; return 1; }
        [[ "$path" == */* ]] || break
        path=${path#*/}
    done
}
mc_offline() {
    local package=$1 scheme=$2 id arch line digest path index=0
    mc_regular "$package/offline-sha256.txt" || return 1
    exec 3< "$package/offline-sha256.txt"
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        for arch in amd64 arm64; do
            IFS= read -r line <&3 || { exec 3<&-; return 1; }
            digest=${line%% *}; path="bin/$arch/$id"
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && [ "$line" = "$digest  $path" ] || { exec 3<&-; return 1; }
            mc_no_links "$package/$path" && mc_sha256 "$package/$path" "$digest" && mc_macho "$package/$path" "$arch" || { exec 3<&-; return 1; }
            index=$((index + 1))
        done
    done
    if IFS= read -r line <&3 || [ -n "$line" ]; then exec 3<&-; return 1; fi
    exec 3<&-
}
mc_prepare_components() {
    local package=$1 scheme=$2 arch=$3 work=$4 id
    /bin/mkdir "$work/prepared" "$work/prepared/bin"
    # Offline-only: bundled per-architecture binaries are hash-verified in place;
    # no downloader, release lookup or network access exists in this script.
    mc_offline "$package" "$scheme"
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        /bin/cp "$package/bin/$arch/$id" "$work/prepared/bin/$id"
    done
    /bin/chmod 755 "$work/prepared" "$work/prepared/bin" "$work/prepared/bin/"*
    /usr/sbin/chown -R 0:0 "$work/prepared/bin"
}
mc_render_gost() {
    printf 'services:\n  - name: local-socks5\n    addr: "127.0.0.1:10000"\n    handler:\n      type: socks5\n      auth:\n        username: "%s"\n        password: "%s"\n    listener:\n      type: tcp\n' "$MC_GOST_USER" "$MC_GOST_PASS"
    [ "$1" = gost ] || return 0
    /bin/cat <<EOF
  - name: rtcp-socks5
    addr: "127.0.0.1:10001"
    handler:
      type: rtcp
    listener:
      type: rtcp
      chain: relay-chain
    forwarder:
      nodes:
        - name: target-socks5
          addr: "127.0.0.1:10000"
chains:
  - name: relay-chain
    hops:
      - name: vps-relay
        nodes:
          - name: relay-node
            addr: "${MC_IP}:9000"
            connector:
              type: relay
              auth:
                username: "$MC_RELAY_USER"
                password: "$MC_RELAY_PASS"
            dialer:
              type: mtls
              tls:
                certFile: "config/certs/client.crt"
                keyFile: "config/certs/client.key"
                caFile: "config/certs/ca.crt"
                secure: true
                serverName: "$MC_IP"
EOF
}
mc_render_frpc() {
    /bin/cat <<EOF
serverAddr = "$MC_IP"
serverPort = 9000
transport.protocol = "tcp"
transport.wireProtocol = "v2"
transport.tls.enable = true
transport.tls.serverName = "$MC_IP"
transport.tls.certFile = "config/certs/client.crt"
transport.tls.keyFile = "config/certs/client.key"
transport.tls.trustedCaFile = "config/certs/ca.crt"
transport.heartbeatInterval = 15
transport.heartbeatTimeout = 90
transport.tcpMux = true
auth.method = "token"
auth.token = "$MC_TOKEN"
loginFailExit = false

[[proxies]]
name = "mac_socks5"
type = "tcp"
localIP = "127.0.0.1"
localPort = 10000
remotePort = 10001
transport.useEncryption = false
transport.useCompression = false
EOF
}
mc_credentials() {
    /bin/cat <<EOF
SOCKS5 连接信息（macOS，$1）
配套 VPS：$MC_IP
住宅机本地地址：127.0.0.1:10000
VPS 上的 S-UI 出站地址：127.0.0.1:10001（VPS 回环地址，不对公网开放）
账号：$MC_GOST_USER
密码：$MC_GOST_PASS

本文件含明文密码，与本次配置一致，请妥善保管，勿公开或转发。
本文件存在不代表 TLS 或端到端链路已连通。
EOF
}
mc_label() { printf 'org.residentialtunnel.%s.%s\n' "$1" "$2"; }
mc_render_plist() {
    local scheme=$1 id=$2 runtime=$3 user=$4 argument=-C config=config/gost.yaml
    [ "$id" != frpc ] || { argument=-c; config=config/frpc.toml; }
    /bin/cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(mc_label "$scheme" "$id")</string>
<key>ProgramArguments</key><array><string>$runtime/bin/$id</string><string>$argument</string><string>$config</string></array>
<key>UserName</key><string>$user</string>
<key>WorkingDirectory</key><string>$runtime</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>$runtime/logs/$id.log</string>
<key>StandardErrorPath</key><string>$runtime/logs/$id.err.log</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
EOF
}
mc_root_protected() {
    local uid mode
    mc_no_links "$1" || return 1
    uid=$(/usr/bin/stat -f %u "$1") || return 1
    mode=$(/usr/bin/stat -f %Lp "$1") || return 1
    [ "$uid" = 0 ] && [ "$((8#$mode & 0022))" = 0 ] || mc_die "路径必须归 root 所有且不可由组/其他用户写入：$1"
}
mc_marker() { printf 'ResidentialTunnel-macos-v1\nscheme=%s\nuser=%s\nuid=%s\n' "$1" "$2" "$3"; }
mc_owned_runtime() {
    local runtime=$1 scheme=$2 user=$3 uid=$4
    [ -d "$runtime" ] || return 1
    mc_root_protected "$runtime" && mc_regular "$runtime/.residential-owner" && mc_root_protected "$runtime/.residential-owner" || return 1
    /usr/bin/cmp -s "$runtime/.residential-owner" <(mc_marker "$scheme" "$user" "$uid") || { mc_die '运行目录归属标记不匹配'; return 1; }
    [ -z "$(/usr/bin/find "$runtime" ! -type f ! -type d -print)" ] || { mc_die '运行目录包含链接或特殊文件'; return 1; }
    mc_root_protected "$runtime/bin" || return 1
    local id
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        mc_regular "$runtime/bin/$id" && mc_root_protected "$runtime/bin/$id" || return 1
    done
}
mc_validate_plist() {
    local file=$1 scheme=$2 id=$3 runtime=$4 user=$5 flag=-C config=config/gost.yaml
    [ "$id" != frpc ] || { flag=-c; config=config/frpc.toml; }
    mc_regular "$file" && mc_root_protected "$file" || return 1
    [ "$(mc_get "$file" Label)" = "$(mc_label "$scheme" "$id")" ] &&
    [ "$(mc_get "$file" ProgramArguments array)" = 3 ] &&
    [ "$(mc_get "$file" ProgramArguments.0)" = "$runtime/bin/$id" ] &&
    [ "$(mc_get "$file" ProgramArguments.1)" = "$flag" ] &&
    [ "$(mc_get "$file" ProgramArguments.2)" = "$config" ] &&
    [ "$(mc_get "$file" UserName)" = "$user" ] &&
    [ "$(mc_get "$file" WorkingDirectory)" = "$runtime" ] &&
    [ "$(mc_get "$file" StandardOutPath)" = "$runtime/logs/$id.log" ] &&
    [ "$(mc_get "$file" StandardErrorPath)" = "$runtime/logs/$id.err.log" ] || { mc_die '已有 LaunchDaemon 不属于本方案，拒绝修改'; return 1; }
    # Exact canonical plist also rejects hidden Program/RootDirectory overrides,
    # extra environment settings, disabled KeepAlive and other unexpected keys.
    /usr/bin/cmp -s "$file" <(mc_render_plist "$scheme" "$id" "$runtime" "$user") || mc_die '已有 plist 已被改写，拒绝修改'
}
mc_snapshot_field() {
    /usr/bin/awk -v key="$2" 'index($0, "\t" key " = ")==1 { sub("^\t" key " = ", ""); print; count++ } END { if (count != 1) exit 1 }' "$1"
}
mc_validate_snapshot() {
    local header label=${4##*/}
    label=${label%.plist}; IFS= read -r header < "$1" || return 1
    [ "$header" = "system/$label = {" ] &&
    [ "$(mc_snapshot_field "$1" program)" = "$2" ] &&
    [ "$(mc_snapshot_field "$1" username)" = "$3" ] &&
    [ "$(mc_snapshot_field "$1" path)" = "$4" ] || mc_die '已加载的 launchd 服务归属不匹配'
}
mc_gateway() {
    local expected=$1 required=$2 data line pid='' found=0 status
    if data=$(/usr/sbin/lsof -nP -iTCP:10000 -sTCP:LISTEN -Fpn 2>/dev/null); then :
    else
        status=$?
        [ "$status" = 1 ] && [ -z "$data" ] && [ "$required" = no ]
        return
    fi
    while IFS= read -r line; do
        case "$line" in
            p*) pid=${line#p}; [ -n "$expected" ] && [ "$pid" = "$expected" ] || { mc_die '10000 端口被其他进程占用'; return 1; } ;;
            n*) [ "$line" = 'n127.0.0.1:10000' ] || { mc_die '10000 必须仅监听 IPv4 回环地址'; return 1; }; found=1 ;;
        esac
    done <<EOF
$data
EOF
    [ "$required" = no ] || [ "$found" = 1 ]
}
mc_services_preflight() {
    local scheme=$1 id label plist pid='' other
    MC_LOADED=''; MC_OLD_PLISTS=''
    for other in gost frp; do
        [ "$other" != "$scheme" ] || continue
        [ ! -e "$MC_BASE/$other" ] && [ ! -L "$MC_BASE/$other" ] || mc_die '检测到另一方案运行目录，请先用对应卸载脚本 --purge 处理'
        for id in gost frpc; do
            label=$(mc_label "$other" "$id")
            [ ! -e "/Library/LaunchDaemons/$label.plist" ] && [ ! -L "/Library/LaunchDaemons/$label.plist" ] || mc_die '检测到另一方案 LaunchDaemon'
            if /bin/launchctl print "system/$label" >/dev/null 2>&1; then mc_die '检测到另一方案已加载服务'; fi
        done
    done
    if [ -e "$MC_RUNTIME" ] || [ -L "$MC_RUNTIME" ]; then mc_owned_runtime "$MC_RUNTIME" "$scheme" "$MC_USER" "$MC_UID"; fi
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        label=$(mc_label "$scheme" "$id"); plist="/Library/LaunchDaemons/$label.plist"
        if [ -e "$plist" ] || [ -L "$plist" ]; then
            mc_owned_runtime "$MC_RUNTIME" "$scheme" "$MC_USER" "$MC_UID"
            mc_validate_plist "$plist" "$scheme" "$id" "$MC_RUNTIME" "$MC_USER"
            MC_OLD_PLISTS="$MC_OLD_PLISTS $id"
            /bin/cp "$plist" "$MC_WORK/old-$id.plist"
        fi
        if /bin/launchctl print "system/$label" > "$MC_WORK/snapshot-$id" 2>/dev/null; then
            [ -f "$plist" ] || mc_die '已有服务缺少可验证 plist'
            mc_validate_snapshot "$MC_WORK/snapshot-$id" "$MC_RUNTIME/bin/$id" "$MC_USER" "$plist"
            MC_LOADED="$MC_LOADED $id"
            [ "$id" != gost ] || pid=$(mc_snapshot_field "$MC_WORK/snapshot-$id" pid || true)
        fi
    done
    mc_gateway "$pid" no
}
mc_executables_idle() {
    local id pids status
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$MC_SCHEME" = frp ] || continue
        [ -f "$MC_RUNTIME/bin/$id" ] || continue
        if pids=$(/usr/sbin/lsof -t "$MC_RUNTIME/bin/$id" 2>/dev/null); then
            mc_die "本方案程序仍被进程使用（可能是手动启动），不会替换或强杀：$id"
            return 1
        else
            status=$?
            [ "$status" = 1 ] && [ -z "$pids" ] || return 1
        fi
    done
}
mc_wait_stopped() {
    local label=$1 pid=$2 attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if ! /bin/launchctl print "system/$label" >/dev/null 2>&1 && { [ -z "$pid" ] || ! /bin/kill -0 "$pid" 2>/dev/null; }; then return 0; fi
        /bin/sleep 1
    done
    mc_die '服务尚未完全退出，拒绝替换可执行文件'
}
mc_stop_services() {
    local id label pid
    # Reverse order: stop frpc first; never kill by process name.
    for id in frpc gost; do
        case " $MC_LOADED " in *" $id "*) ;; *) continue ;; esac
        label=$(mc_label "$MC_SCHEME" "$id")
        pid=$(mc_snapshot_field "$MC_WORK/snapshot-$id" pid || true)
        MC_STOPPED="$MC_STOPPED $id"
        /bin/launchctl bootout "system/$label"
        mc_wait_stopped "$label" "$pid"
    done
    mc_gateway '' no
    mc_executables_idle
}
mc_rollback() {
    local id label pid failed=0
    printf '安装未完成，尝试恢复本方案原文件和原已加载服务。\n' >&2
    for id in $MC_STARTED; do
        label=$(mc_label "$MC_SCHEME" "$id"); pid=''
        if /bin/launchctl print "system/$label" > "$MC_WORK/rollback-$id" 2>/dev/null; then
            pid=$(mc_snapshot_field "$MC_WORK/rollback-$id" pid || true)
        fi
        /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
        mc_wait_stopped "$label" "$pid" || failed=1
    done
    if [ "$MC_REPLACED" = 1 ]; then mc_executables_idle || failed=1; fi
    [ "$failed" = 0 ] || { mc_die '新服务未停止，保留现场，不覆盖运行文件'; return 1; }
    for id in $MC_NEW_PLISTS; do /bin/rm -f "/Library/LaunchDaemons/$(mc_label "$MC_SCHEME" "$id").plist" || failed=1; done
    if [ "$MC_REPLACED" = 1 ]; then
        mc_owned_runtime "$MC_RUNTIME" "$MC_SCHEME" "$MC_USER" "$MC_UID" && /bin/rm -rf "$MC_RUNTIME" || return 1
    fi
    if [ -d "$MC_WORK/old-runtime" ]; then
        [ ! -e "$MC_RUNTIME" ] && [ ! -L "$MC_RUNTIME" ] || return 1
        /bin/mv "$MC_WORK/old-runtime" "$MC_RUNTIME" || return 1
    fi
    for id in $MC_OLD_PLISTS; do
        /bin/cp "$MC_WORK/old-$id.plist" "/Library/LaunchDaemons/$(mc_label "$MC_SCHEME" "$id").plist" || failed=1
    done
    for id in $MC_STOPPED; do
        label=$(mc_label "$MC_SCHEME" "$id")
        if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then /bin/launchctl bootstrap system "/Library/LaunchDaemons/$label.plist" || failed=1; fi
    done
    [ "$failed" = 0 ] || mc_die '自动恢复未完全成功，请保留现场并检查 launchctl 和日志'
}
mc_cleanup() {
    local status=$1
    trap - EXIT INT TERM
    set +e
    if [ "${MC_TRANSACTION:-0}" = 1 ]; then
        if ! mc_rollback; then printf '恢复资料保留在：%s\n' "$MC_WORK" >&2; MC_KEEP_WORK=1; fi
    fi
    if [ -n "${MC_WORK:-}" ] && [ "${MC_KEEP_WORK:-0}" != 1 ]; then /bin/rm -rf "$MC_WORK"; fi
    if [ "${MC_LOCKED:-0}" = 1 ]; then /bin/rmdir "$MC_BASE/.installer.lock" || status=1; fi
    [ "$status" = 0 ] || printf '操作失败；未宣称隧道连通。\n' >&2
    exit "$status"
}
mc_prepare_config() {
    local package=$1 prepared=$2 scheme=$3 name
    /bin/mkdir -m 700 "$prepared/config" "$prepared/config/certs" "$prepared/logs"
    for name in gost frpc; do
        [ "$name" != frpc ] || [ "$scheme" = frp ] || continue
        : > "$prepared/logs/$name.log"; : > "$prepared/logs/$name.err.log"
    done
    /bin/chmod 600 "$prepared/logs/"*
    for name in ca.crt client.crt client.key; do /bin/cp "$package/$name" "$prepared/config/certs/$name"; done
    mc_render_gost "$scheme" > "$prepared/config/gost.yaml"
    [ "$scheme" != frp ] || mc_render_frpc > "$prepared/config/frpc.toml"
    mc_credentials "$scheme" > "$prepared/config/SOCKS5账号密码.txt"
    mc_regular "$prepared/config/SOCKS5账号密码.txt"
    /bin/chmod 600 "$prepared/config/"*.* "$prepared/config/certs/"*
    /usr/sbin/chown -R "$MC_UID:$MC_GID" "$prepared/config" "$prepared/logs"
    mc_marker "$scheme" "$MC_USER" "$MC_UID" > "$prepared/.residential-owner"
    /bin/chmod 600 "$prepared/.residential-owner"
    # Relative certificate paths are identical during validation and service startup.
    # Only the verified Mach-O executables run; no downloaded scripts/interpreters.
    (cd "$prepared" && /usr/bin/sudo -u "$MC_USER" -- "$prepared/bin/gost" -C config/gost.yaml -O yaml > /dev/null)
    if [ "$scheme" = frp ]; then
        (cd "$prepared" && /usr/bin/sudo -u "$MC_USER" -- "$prepared/bin/frpc" verify -c config/frpc.toml)
    fi
}
mc_install() {
    local package=$1 scheme=$2 arch=$3 id label attempt pid ready
    mc_read_conf "$package/client.conf"
    mc_manifest "$package/components.json" "$scheme"
    for id in ca.crt client.crt client.key; do mc_no_links "$package/$id"; mc_regular "$package/$id"; done
    for id in ca.key server.key server.crt; do [ ! -e "$package/$id" ] && [ ! -L "$package/$id" ] || mc_die '部署包不得包含 CA/服务端私钥或服务端证书'; done
    mc_services_preflight "$scheme"
    mc_prepare_components "$package" "$scheme" "$arch" "$MC_WORK"
    mc_prepare_config "$package" "$MC_WORK/prepared" "$scheme"
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        mc_render_plist "$scheme" "$id" "$MC_RUNTIME" "$MC_USER" > "$MC_WORK/new-$id.plist"
        /usr/bin/plutil -lint "$MC_WORK/new-$id.plist" >/dev/null
    done
    # All downloads, hashes, extraction, credentials and binary config validation
    # have succeeded BEFORE the first stop or runtime executable replacement.
    MC_TRANSACTION=1
    mc_stop_services
    if [ -d "$MC_RUNTIME" ]; then /bin/mv "$MC_RUNTIME" "$MC_WORK/old-runtime"; fi
    /bin/mv "$MC_WORK/prepared" "$MC_RUNTIME"; MC_REPLACED=1
    for id in gost frpc; do
        [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
        label=$(mc_label "$scheme" "$id")
        MC_NEW_PLISTS="$MC_NEW_PLISTS $id"
        /usr/bin/install -o root -g wheel -m 644 "$MC_WORK/new-$id.plist" "/Library/LaunchDaemons/$label.plist"
        MC_STARTED="$MC_STARTED $id"
        /bin/launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
    done
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        ready=1; pid=''
        for id in gost frpc; do
            [ "$id" != frpc ] || [ "$scheme" = frp ] || continue
            label=$(mc_label "$scheme" "$id")
            if /bin/launchctl print "system/$label" > "$MC_WORK/running-$id" 2>/dev/null; then
                [ "$(mc_snapshot_field "$MC_WORK/running-$id" state || true)" = running ] || ready=0
                [ "$id" != gost ] || pid=$(mc_snapshot_field "$MC_WORK/running-$id" pid || true)
            else ready=0; fi
        done
        if [ "$ready" = 1 ] && mc_gateway "$pid" yes; then break; fi
        ready=0; /bin/sleep 1
    done
    [ "$ready" = 1 ] || mc_die 'launchd/本地 SOCKS 检查失败，请检查日志'
    MC_TRANSACTION=0
    printf '本地安装检查通过（不代表 VPS/TLS/端到端连通）。\n运行目录：%s\n凭据：%s/config/SOCKS5账号密码.txt\n' "$MC_RUNTIME" "$MC_RUNTIME"
}
mc_uninstall() {
    local scheme=$1 purge=$2 id label
    mc_services_preflight "$scheme"
    # Uninstall does not require a package manifest/config/certificates or network.
    mc_stop_services
    for id in $MC_OLD_PLISTS; do
        label=$(mc_label "$scheme" "$id")
        mc_validate_plist "/Library/LaunchDaemons/$label.plist" "$scheme" "$id" "$MC_RUNTIME" "$MC_USER"
        /bin/rm "/Library/LaunchDaemons/$label.plist"
    done
    if [ "$purge" = yes ] && [ -d "$MC_RUNTIME" ]; then
        mc_owned_runtime "$MC_RUNTIME" "$scheme" "$MC_USER" "$MC_UID"
        /bin/rm -rf "$MC_RUNTIME"
        printf '仅清除已验证归属的本方案运行目录。\n'
    else printf '卸载服务完成；保留运行目录、配置、日志和明文 SOCKS5 凭据：%s\n' "$MC_RUNTIME"; fi
}
macos_client_help() {
    printf '%s\n' 'macOS 12+ 住宅机 SOCKS5 客户端（原生 arm64/amd64，系统 launchd）' \
        '安装：sudo bash ./setup_macos.sh' '卸载：sudo bash ./uninstall_macos.sh [--purge]' \
        '默认保留配置/凭据；--purge 仅清除已验证归属的本方案目录，请先备份。' \
        '必须从现有普通本地账户运行 sudo；不创建账户，不修改睡眠、SSH、防火墙或安全策略。' \
        '在线包只下载清单固定版本并校验 SHA-256；离线包完全不访问网络。' \
        'FileVault 重启后须先本地解锁磁盘；Mac 睡眠/断网期间隧道不可用。' \
        '仅映射 SOCKS5 127.0.0.1:10000 -> VPS 127.0.0.1:10001；无 RDP/SSH 映射。'
}
macos_client_main() (
    set -euo pipefail
    local action=${1:-} purge=no package scheme arch major user localuid
    shift || true
    for user in "$@"; do case "$user" in -h|--help) macos_client_help; return 0 ;; esac; done
    case "$action" in -h|--help) macos_client_help; return 0 ;; install|uninstall) ;; *) mc_die '未知操作'; return 1 ;; esac
    for user in "$@"; do
        if [ "$action" = uninstall ] && [ "$user" = --purge ] && [ "$purge" = no ]; then purge=yes
        else mc_die '不支持的参数（使用 --help）'; return 1; fi
    done
    scheme=${MACOS_CLIENT_SCHEME:-}
    case "$scheme" in gost|frp) ;; *) mc_die '包装脚本未指定方案'; return 1 ;; esac
    package=${MACOS_PACKAGE_DIR:-}; mc_no_links "$package"
    [ "$(/usr/bin/uname -s)" = Darwin ] || mc_die '仅支持 macOS'
    major=$(/usr/bin/sw_vers -productVersion); major=${major%%.*}
    [ "$major" -ge 12 ] || mc_die '需要 macOS 12 或更新版本'
    [ "$(/usr/bin/id -u)" = 0 ] || mc_die '请从普通本地账户运行 sudo bash ./setup_macos.sh（卸载使用对应脚本）'
    MC_USER=${SUDO_USER:-}
    [[ "$MC_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] && [ "$MC_USER" != root ] || mc_die '需要有效的 SUDO_USER 普通本地账户'
    MC_UID=$(/usr/bin/id -u "$MC_USER"); MC_GID=$(/usr/bin/id -g "$MC_USER")
    localuid=$(/usr/bin/dscl /Local/Default -read "/Users/$MC_USER" UniqueID | /usr/bin/awk '$1=="UniqueID:" {print $2}')
    [ "$MC_UID" -ge 501 ] && [ "$localuid" = "$MC_UID" ] || mc_die '服务账户必须是已存在的普通本地账户（uid >= 501）'
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
    unset TAR_OPTIONS CDPATH ENV BASH_ENV
    IFS=$' \t\n'; umask 077; cd /
    arch=$(mc_arch)
    MC_SCHEME=$scheme; MC_BASE='/Library/Application Support/ResidentialTunnel'; MC_RUNTIME="$MC_BASE/$scheme"
    case "$package/" in "$MC_BASE/"*) mc_die '请从运行目录之外的解压包执行'; return 1 ;; esac
    for user in /Library '/Library/Application Support' /Library/LaunchDaemons; do mc_root_protected "$user"; done
    mc_no_links "$MC_BASE"
    if [ ! -e "$MC_BASE" ]; then /bin/mkdir -m 755 "$MC_BASE"; fi
    mc_root_protected "$MC_BASE"
    MC_LOCKED=0; MC_WORK=''; MC_KEEP_WORK=0; MC_TRANSACTION=0; MC_REPLACED=0; MC_NEW_PLISTS=''; MC_STARTED=''; MC_STOPPED=''; MC_OLD_PLISTS=''
    trap 'mc_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    /bin/mkdir -m 700 "$MC_BASE/.installer.lock" || { mc_die '另一安装/卸载正在运行，或上次中断留下锁；请先人工核实，不会自动删除锁'; return 1; }
    MC_LOCKED=1
    MC_WORK=$(/usr/bin/mktemp -d "$MC_BASE/.prepare.XXXXXXXX")
    /bin/chmod 711 "$MC_WORK"
    if [ "$action" = install ]; then mc_install "$package" "$scheme" "$arch"
    else mc_uninstall "$scheme" "$purge"; fi
)
