# FRP + GOST 方案

Windows GOST 提供本地认证 SOCKS5，frpc 负责将 SOCKS 与 RDP 通过 TLS 反向映射到 VPS。适合已熟悉 FRP 的部署，代价是多一个进程和一份配置。

完整的环境要求、离线包分发、S-UI、验收、RDP 与升级说明见[项目总说明](../README.md)。

## 部署与路径

在完整仓库中，以 root / sudo 运行：

```bash
bash install.sh frp
# 等价子入口：
bash 02_FRP_GOST/install_vps_frp_gost.sh
```

- VPS：`/usr/local/bin/frps`、`/etc/frp/frps.toml`、`/etc/frp/certs/`。
- systemd：`frps.service`，监听 TCP 9000。
- 包：`/root/windows_frp_gost_pkg.zip`；使用 SFTP/SCP 下载，不启动 HTTP 私钥目录分发。
- Windows：`C:\Tools\TikTokFrpGost`；服务 `TikTok_FRPGost`（GOST）与 `TikTok_FRP`（frpc）。
- 模板：`windows_client_frp_gost/`。frpc 与 frps 来自同一个 Release；Windows GOST、Servy 分别获取官方稳定 Release。

必须下载完整仓库，单独的子入口不能远程自举；统一在线入口见总说明。

## 服务端修正

```toml
bindAddr = "0.0.0.0"
bindPort = 9000
proxyBindAddr = "127.0.0.1"
allowPorts = [{ single = 10001 }, { single = 33389 }]
maxPortsPerClient = 2
transport.tcpMux = true
transport.maxPoolCount = 5
transport.heartbeatTimeout = 90
transport.tls.force = true
# 实际配置还包含 Token 与服务端证书、私钥、可信客户端 CA。
```

- **`transport.wireProtocol = "v2"` 仅属于 frpc 客户端**。放入 frps 会被当前严格配置解析拒绝。
- `proxyBindAddr` 限定反向映射监听到回环地址；不设置时默认继承 bindAddr，可能把 10001 暴露到公网。
- allowPorts 限制可申请的两个端口，关闭不必要的管理面板，不开放 7500。
- TLS 强制开启，两端都用 CA 验证对端证书，客户端验证 VPS 公网 IP 身份。

## 客户端配置策略

- `transport.protocol = "tcp"`、`wireProtocol = "v2"`、`tcpMux = true`。
- 10000→10001、3389→33389 两条 TCP 代理。
- TLS 已提供传输加密，不再对代理流量重复启用 `useEncryption`。
- `useCompression = false`：视频等已压缩流量通常不值得再压缩；是否改善性能仍需实际测量，不是固定结论。
- 保留可重连配置与心跳；进程运行不等于代理注册成功，应同时检查 frpc 日志、VPS 映射端口和出口 IP。

## 运维与迁移

```bash
systemctl status frps
journalctl -u frps -f
bash install.sh frp --upgrade
# 固定候选版本：
bash install.sh frp --upgrade --version v0.71.1
```

升级只替换 VPS frps，不更新 Windows frpc/GOST/Servy 或已有离线包。运行中的服务会重启并断连；候选配置验证失败则不替换，启动健康检查失败则回滚二进制。

旧部署 `/root/frp/frps`、`/root/frp/frps.toml` 可以识别用于升级，但不会自动迁移路径、删除服务端非法字段、修改公网绑定或重新签发证书。升级前请备份并检查旧配置；不要误以为更新二进制等于完成安全迁移。

RDP 默认不公开：先在维护电脑运行 `ssh -N -L 13389:127.0.0.1:33389 root@<VPS_IP>`，再连接 `127.0.0.1:13389`。

Windows 卸载只管理本方案独立目录和经路径核验的服务。若发现旧共享 `TikTok_Gost` 或 `TikTok_FRP` 指向其他目录，安装/卸载会拒绝操作，需先人工核实迁移。

## 官方依据

- [FRP 服务端字段](https://gofrp.org/en/docs/reference/server-configures/)
- [FRP 客户端字段](https://gofrp.org/en/docs/reference/client-configures/)
- [FRP 双向 TLS](https://gofrp.org/en/docs/features/common/network/network-tls/)
- [v0.71.1 服务端结构](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/server.go)
- [v0.71.1 客户端结构](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/client.go)

字段核对基线为 FRP v0.71.1、GOST v3.3.2、Servy v10.7；默认下载后续官方稳定 Release 不等于已验证所有未来版本的兼容性。
