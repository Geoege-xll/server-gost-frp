# 纯 GOST v3 方案

GOST 同时承担 Windows / Mac 本地 SOCKS5 网关与远程 TCP 转发。组件更少，但不据此保证比 FRP 更快或占用固定内存。

完整的环境要求、完整离线包分发、S-UI、验收、RDP 与升级说明见[项目总说明](../README.md)。以下为本方案特有配置。

## 部署与路径

在完整仓库中，以 root / sudo 运行：

```bash
bash install.sh gost                    # 接下来选择住宅机：Windows / macOS
bash install.sh gost --client windows   # Windows 完整离线包
bash install.sh gost --client mac       # Mac 完整离线包，自动识别 Intel / Apple Silicon
# 等价子入口：
bash 01_Pure_GOST_v3/install_vps_gost_v3.sh
```

- VPS：`/usr/local/bin/gost`、`/etc/gost/gost.yaml`、`/etc/gost/certs/`。
- systemd：`gost.service`，监听 TCP 9000。
- Windows 包：`/root/windows_gost_v3_pkg.zip`；Mac 包：`/root/macos_gost_v3_pkg.zip`。均为完整离线包，使用 SFTP/SCP 下载，不能公开包含私钥的目录。
- Mac 模板：`macos_client_gost_v3/` + `lib/macos_client.sh`；完整解压后以普通本地账号执行 `sudo bash setup_macos.sh`，使用 launchd，不安装 Servy。`components.json` 固定两种架构的官方 GOST 版本、URL、SHA-256，包内 `bin/amd64`、`bin/arm64` 已内置程序及摘要。实际凭据保存至私有配置目录的 `SOCKS5账号密码.txt`，卸载默认保留。
- Mac 仅映射 SOCKS 10001→10000，不创建 33389→3389；不改防睡眠、远程登录或屏幕共享，FileVault 重启解锁与实际 launchd 安装仍需验收。
- Windows：`C:\Tools\TikTokGostV3`，服务 `TikTok_GostV3`。
- 模板：`windows_client_gost_v3/` 与公共组件校验脚本 `lib/windows_components.ps1`。Bash 打包时注入连接信息，`components.json` 固定 GOST/Servy 官方版本、URL 和 SHA-256；纯 GOST 的 Windows/VPS 版本一致。包内已内置 `gost.exe` 和完整 `servy/` 树，住宅机只校验结构后安装，不联网下载；全部组件校验完成后才停止已有本方案服务。

必须下载完整仓库，单独的子入口不能远程自举；统一在线入口见总说明。

## 关键字段

VPS 使用 `relay` handler 并显式配置 `bind: true`；Windows / Mac 住宅机通过 relay 请求 VPS 绑定反向端口。

```yaml
# Windows 反向转发片段；实际配置包会注入凭据和证书路径。
- name: rtcp-socks5
  addr: "127.0.0.1:10001"
  handler:
    type: rtcp
  listener:
    type: rtcp
    chain: relay-chain
  forwarder:
    nodes:
      - name: socks5
        addr: "127.0.0.1:10000"
```

`chain` 必须在 `listener` 下；`handler: rtcp` 是有效配置，不需要改成其他 handler。

- `mtls` 是 **Multiplex TLS**。服务端 listener 的 CA 用于验证客户端证书；客户端 dialer 同时配置 CA、客户端证书/私钥、`secure: true` 与服务器身份名称。
- 服务端证书 SAN 是 VPS 公网 IPv4；Windows 地址渲染为 `${VpsServerIp}:9000`，避免 PowerShell 把变量后的冒号当作作用域语法。
- 使用文档中的多路复用心跳参数，保留 relay `nodelay`。它是及时发送 relay 协议头的选项，不是“零延迟”的保证。
- Windows 模板申请 VPS 回环端口 10001 与 33389，Mac 只申请 10001。relay 的 BIND 能力只交给持有客户端证书与凭据的受信住宅机；这些秘密泄漏后不能仅依赖客户端模板作为服务端访问控制。

## 运维

```bash
systemctl status gost
journalctl -u gost -f
bash install.sh gost --upgrade
# 固定候选版本：
bash install.sh gost --upgrade --version v3.3.2
```

升级会重启运行中的 VPS 服务、断开连接；不是热更新。保留配置与证书，不会重打 Windows/Mac 包或续期证书；`--upgrade` 不与 `--client` 同用，也不能用来切换住宅机系统。已有错误 `listener.chain` 或 TLS 客户端配置不会随 VPS 二进制升级自动修复，需有计划地迁移。

RDP 默认不公开：先在维护电脑运行 `ssh -N -L 13389:127.0.0.1:33389 root@<VPS_IP>`，再连接 `127.0.0.1:13389`。

Windows 卸载入口只停止/移除本方案服务及独立运行目录，不会删除整个 `C:\Tools`，也不会终止所有同名 GOST 进程。旧版共享 `TikTok_Gost` 服务需人工迁移。

## 官方依据

- [远程转发与 listener.chain](https://gost.run/en/tutorials/port-forwarding/)
- [TLS 与证书校验](https://gost.run/en/tutorials/tls/)
- [Multiplex TLS](https://gost.run/en/reference/listeners/mtls/)
- [relay handler](https://gost.run/en/reference/handlers/relay/)

字段核对基线为 GOST v3.3.2（依赖 go-gost/x v0.27.2），不代表后续版本已全部经过实机测试。
