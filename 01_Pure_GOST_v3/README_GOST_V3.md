# 纯 GOST v3 方案

GOST 同时承担 Windows 本地 SOCKS5 网关与远程 TCP 转发。组件更少，但不据此保证比 FRP 更快或占用固定内存。

完整的环境要求、离线包分发、S-UI、验收、RDP 与升级说明见[项目总说明](../README.md)。以下为本方案特有配置。

## 部署与路径

在完整仓库中，以 root / sudo 运行：

```bash
bash install.sh gost
# 等价子入口：
bash 01_Pure_GOST_v3/install_vps_gost_v3.sh
```

- VPS：`/usr/local/bin/gost`、`/etc/gost/gost.yaml`、`/etc/gost/certs/`。
- systemd：`gost.service`，监听 TCP 9000。
- 包：`/root/windows_gost_v3_pkg.zip`；使用 SFTP/SCP 下载，不能公开包含私钥的目录。
- Windows：`C:\Tools\TikTokGostV3`，服务 `TikTok_GostV3`。
- 模板：`windows_client_gost_v3/`。Bash 打包时直接复制这些文件，不再嵌入另一套脚本。

必须下载完整仓库，单独的子入口不能远程自举；统一在线入口见总说明。

## 关键字段

VPS 使用 `relay` handler 并显式配置 `bind: true`；Windows 通过 relay 请求 VPS 绑定反向端口。

```yaml
# Windows 反向转发片段；实际离线包会注入凭据和证书路径。
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
- 默认模板申请 VPS 回环端口 10001 与 33389。relay 的 BIND 能力只交给持有客户端证书与凭据的受信住宅机；这些秘密泄漏后不能仅依赖客户端模板作为服务端访问控制。

## 运维

```bash
systemctl status gost
journalctl -u gost -f
bash install.sh gost --upgrade
# 固定候选版本：
bash install.sh gost --upgrade --version v3.3.2
```

升级会重启运行中的 VPS 服务、断开连接；不是热更新。保留配置与证书，不会重打 Windows 包或续期证书。已有错误 `listener.chain` 或 TLS 客户端配置不会随 VPS 二进制升级自动修复，需有计划地迁移。

RDP 默认不公开：先在维护电脑运行 `ssh -N -L 13389:127.0.0.1:33389 root@<VPS_IP>`，再连接 `127.0.0.1:13389`。

Windows 卸载入口只停止/移除本方案服务及独立运行目录，不会删除整个 `C:\Tools`，也不会终止所有同名 GOST 进程。旧版共享 `TikTok_Gost` 服务需人工迁移。

## 官方依据

- [远程转发与 listener.chain](https://gost.run/en/tutorials/port-forwarding/)
- [TLS 与证书校验](https://gost.run/en/tutorials/tls/)
- [Multiplex TLS](https://gost.run/en/reference/listeners/mtls/)
- [relay handler](https://gost.run/en/reference/handlers/relay/)

字段核对基线为 GOST v3.3.2（依赖 go-gost/x v0.27.2），不代表后续版本已全部经过实机测试。
