# VPS 中继与 Windows 住宅出口部署

提供两套可选的反向 TCP 隧道方案：**纯 GOST v3** 与 **FRP + GOST**。Windows 主动连接 VPS，无需住宅宽带具备公网入站地址。

本项目不安装、不修改 S-UI，也不保证平台账号安全、固定内存占用或“零延迟”。性能和稳定性取决于两端设备、网络及实际负载。

## 选择方案

| 项目 | 纯 GOST v3 | FRP + GOST |
| --- | --- | --- |
| VPS 进程 | GOST | frps |
| Windows 进程 | GOST：SOCKS 与反向转发 | GOST：SOCKS；frpc：反向转发 |
| 传输与认证 | Multiplex TLS + 双向证书认证 + relay 账号密码 | TCP/TLS + 双向证书认证 + FRP Token |
| 适用情况 | 希望减少组件和配置数量 | 已熟悉 FRP 或需衔接其现有部署 |
| 详细说明 | [纯 GOST](01_Pure_GOST_v3/README_GOST_V3.md) | [FRP + GOST](02_FRP_GOST/README_FRP_GOST.md) |

**注意：GOST 的 `mtls` 是 Multiplex TLS（多路复用 TLS），不是“双向认证”的开关。** 双向认证来自两端 CA、证书、私钥及客户端服务器身份校验配置。

## 流量路径与端口

```text
设备 → VPS S-UI / VLESS Reality :8443（已有或自行配置）
     → VPS 127.0.0.1:10001
     → 住宅机主动建立的加密反向隧道（VPS TCP :9000）
     → Windows 127.0.0.1:10000 SOCKS5 → 住宅宽带出口

维护电脑 → SSH 本地转发 → VPS 127.0.0.1:33389
         → 反向隧道 → Windows 127.0.0.1:3389
```

- 新生成的配置将 **10001 与 33389 均绑定到 VPS 回环地址**，不直接公开 SOCKS/RDP。
- 当前方案提供 TCP 转发；不能据此保证 UDP、QUIC、DNS 或 IPv6 流量全部经过住宅出口，需按客户端和路由策略单独验收。
- S-UI 出站需能访问宿主机回环地址；如果 S-UI 在独立容器网络中，容器的 `127.0.0.1` 不等于 VPS，需另行设计受限的容器到宿主机连接，不能简单公开代理端口。

## 前置条件

- VPS：Debian / Ubuntu，运行中的 systemd，root 权限，amd64 或 arm64。脚本要求 `apt-get` 与 `flock`（util-linux）。其他发行版不在自动部署范围内。
- Windows：64 位系统、Windows PowerShell 5.1 或兼容版本、管理员权限；Servy net48 便携版需要 .NET Framework 4.8。Windows on ARM 不在当前离线包支持范围内。
- RDP 需自行启用，通常需要 Windows Pro/Enterprise/Server、有效账号和网络级身份验证；脚本不会启用 RDP 或修改 Windows 防火墙。
- VPS TCP 9000 必须可从住宅机访问；8443 由你的 S-UI 设置决定。脚本不修改防火墙、IPv6、系统路由或现有 S-UI 配置。
- VPS 需通过 HTTPS 访问 GitHub API、Release 和 codeload；自动发现 IPv4 时访问 `https://api.ipify.org`。可用 `VPS_PUBLIC_IP` 显式指定地址，避免该发现请求。

## 首次安装：二选一

**先检查完整仓库源码，再运行。请确认所用提交包含当前安全修复；尚未推送的本地修改不会出现在 GitHub 在线入口中。** 不要用旧版本脚本覆盖已配置的 VPS。

在完整仓库目录中：

```bash
sudo bash install.sh
# 菜单：1 纯 GOST、2 FRP + GOST、3 升级、4 退出；回车不会默认安装。

# 或跳过菜单，显式选择：
sudo bash install.sh gost
sudo bash install.sh frp

# 指定证书绑定的 VPS 公网 IPv4：
sudo env VPS_PUBLIC_IP=203.0.113.10 bash install.sh gost
```

两套方案共用 9000/10001/33389，**不支持在同一 VPS 同时安装**。检测到已有配置目录、服务、目标二进制或本方案旧 ZIP 时，首次安装会拒绝覆盖；不要通过删除现有目录来强行绕过，应先备份并规划迁移。

### 在线入口

只下载主入口文件不足以部署；主入口会获取仓库提交号，再下载该提交的完整快照，避免分别获取 `main` 中不同时间的文件。不再自动切换第三方镜像，也不再使用吞掉下载失败的 `bash <(curl ...)`。

```bash
# 在私有临时目录下载，下载成功后才执行；完成后可自行清理该目录。
workdir=$(mktemp -d) &&
curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/install.sh \
  --output "$workdir/install.sh" &&
sudo bash "$workdir/install.sh"
```

可以在最后一行追加 `gost`、`frp` 或 `gost --upgrade`。如果需要固定仓库快照，下载并审阅对应提交的入口文件，并设置 `REPO_COMMIT=<完整40位提交号>`。HTTPS 与提交固定不能替代源码审阅，也不是独立的代码签名。

两个方案子目录下的 Bash 入口仍可从**完整仓库**运行，但不支持单独下载后执行。

## 安装会做什么

1. 安装所需系统依赖，不做全局网络“优化”。
2. 查询官方稳定 Release，按 Linux 架构选择文件；下载后验证 GitHub 官方资产元数据中的 SHA-256，缺少摘要或校验失败即终止，不回退到未校验版本。
3. 生成私有 CA、服务端和客户端证书；服务端 SAN 绑定公网 IPv4。CA 有效期 3650 天，叶证书 825 天，并限定 serverAuth/clientAuth 用途。
4. 从仓库里的 Windows 模板生成离线包，不再在 Bash 内维护另一份 PowerShell 副本。Servy 完整目录树保留在包内 `servy/` 下。
5. 下载、校验、证书与打包成功后写入本方案路径，注册 systemd 服务并检查服务是否持续运行。
6. 输出 ZIP 路径及 S-UI SOCKS 凭据。服务运行不代表住宅机已经接入，必须完成后面的链路验收。

| 项目 | 纯 GOST | FRP + GOST |
| --- | --- | --- |
| VPS 二进制 | `/usr/local/bin/gost` | `/usr/local/bin/frps` |
| VPS 配置 | `/etc/gost/gost.yaml` | `/etc/frp/frps.toml` |
| 证书目录 | `/etc/gost/certs/` | `/etc/frp/certs/` |
| systemd 服务 | `gost` | `frps` |
| 离线包 | `/root/windows_gost_v3_pkg.zip` | `/root/windows_frp_gost_pkg.zip` |

Windows 的具体运行目录、服务名和旧版迁移说明见对应[纯 GOST 文档](01_Pure_GOST_v3/README_GOST_V3.md)或 [FRP + GOST 文档](02_FRP_GOST/README_FRP_GOST.md)。现有内部标识保持兼容，不因主页措辞调整而改名。

配置目录与 ZIP 默认仅 root 可访问。CA 私钥留在服务端证书目录中，**不会进入 Windows 包**；客户端 ZIP 含客户端私钥与凭据，必须当作秘密文件保管。证书续期和更换 VPS IP **尚未自动化**，应提前规划两端证书轮换；`--upgrade` 不续期。

## 将离线包交给 Windows

使用 **WinSCP/SFTP 或 SCP**，确认 SSH 主机指纹。项目不再启动匿名 HTTP 下载服务。

在自己的电脑执行，替换地址：

```bash
scp root@<VPS_IP>:/root/windows_gost_v3_pkg.zip .
# FRP 方案则下载 /root/windows_frp_gost_pkg.zip
```

Windows 上解压整个 ZIP，右键管理员运行 `一键安装(以管理员运行).bat`。不需要再从 GitHub 下载组件；缺少必需文件会中止，不在线兜底。

- PowerShell 文件带 UTF-8 BOM，以兼容 Windows PowerShell 5.1 的中文源码读取。
- 本项目的业务程序使用独立目录与服务，遇到旧 `C:\Tools` 共享服务、归属不明或其他 Servy wrapper 服务时拒绝继续，旧版迁移需人工检查。
- **Servy v10.7 不是完全目录隔离的便携服务管理器**：官方 CLI 会在 `C:\ProgramData\Servy` 部署共享组件及 host，并可能管理它们的生命周期。因此预检会保守拒绝其他 Servy wrapper；本项目卸载不删除共享 host 或 ProgramData，不能保证卸载后机器上不留任何 Servy 组件。
- 重新部署本方案时先停止自己的服务，再替换文件，避免覆盖运行中的 EXE。
- Windows 安装脚本写入配置时，会将实际 SOCKS5 账号、密码及连接地址同步保存到本方案运行目录的 `SOCKS5账号密码.txt`，并显示完整保存路径；具体目录见各方案文档及包内安装说明。TXT 使用 UTF-8 BOM/Windows 换行，不包含隧道认证凭据或证书私钥；重新安装按本次离线包更新，不重新生成账号密码。**文件含明文密码，请勿公开分享**；卸载默认保留，确认删除运行目录时也会删除该文件。
- 不自动添加 Defender 排除项。若安全软件拦截，请检查来源与告警，而不是排除整个 `C:\Tools`。
- 安装会尝试关闭交流供电时的睡眠/休眠超时，并报告失败；不会改变电池策略，不代表断电或网络中断也能保持在线。卸载不会自动恢复原电源策略。
- Servy 开启进程健康监控与异常重启；这不是网络可达性检测，也不是零中断保证。日志大小轮转不等于所有日志合计严格不超过 50MB。

## S-UI 对接与验收

在现有 S-UI 中手动添加 SOCKS 出站：`127.0.0.1:10001`，填入 VPS 安装完成时输出的 SOCKS 账号密码。将相应 VLESS Reality 入站（例如 8443）的业务流量路由到该出站。Reality 密钥、客户端和分流规则由你现有配置管理，脚本不覆盖。

住宅机安装后，在 VPS 上检查：

```bash
systemctl status gost      # FRP 方案改为 frps
journalctl -u gost -n 100  # FRP 方案改为 frps
ss -lntp | grep -E ':(9000|10001|33389)\b'

# 让 SOCKS 端解析目标域名；替换用户和密码。注意命令行凭据可能被进程列表/历史记录看到。
curl --fail --show-error --max-time 20 \
  --proxy socks5h://127.0.0.1:10001 --proxy-user '<用户>:<密码>' \
  https://api.ipify.org
```

出口应与住宅机的实际公网出口一致。还应验证错误 SOCKS 凭据被拒绝、客户端证书校验有效、10001/33389 没有绑定到公网。服务为 `running` 或端口已监听不足以证明这些条件。

### 远程桌面

在自己的维护电脑上先执行：

```bash
ssh -N -L 13389:127.0.0.1:33389 root@<VPS_IP>
```

保持 SSH 会话，再用远程桌面连接 **`127.0.0.1:13389`**。不再使用 `<VPS_IP>:33389` 直接连接。可按自己的 SSH 策略使用非 root 维护账号。

## 升级与旧版迁移

在已审阅的完整仓库中运行：

```bash
sudo bash install.sh gost --upgrade
sudo bash install.sh frp --upgrade
# 自动识别唯一已安装方案（包括停止的服务）：
sudo bash install.sh --upgrade

# 可固定核心组件版本；拒绝自动降级：
sudo bash install.sh gost --upgrade --version v3.3.2
sudo bash install.sh frp --upgrade --version v0.71.1
```

- 下载并校验候选，检查配置，再在二进制同目录暂存并原子替换，避免直接 `cp` 覆盖运行文件。
- 原来运行的服务会重启，**已有连接会中断**。新服务未保持运行则恢复旧二进制并尝试重启；回滚后仍应检查日志和实际链路。
- 原来停止的服务保持停止。配置、证书和账号不改写；相同版本仅检查配置，不替换。
- **只升级 VPS 核心组件**，不会更新住宅机、Windows 离线 ZIP、Servy 或旧 systemd 配置。离线包中的 `VERSIONS.txt` 记录打包时版本，升级后不要将旧包当作新客户端。
- 当前模板的核心组件最低版本为 GOST 3.3.2 / FRP 0.71.1。跨版本升级仍需阅读官方兼容性说明。
- 旧 FRP 路径 `/root/frp/frps`、`/root/frp/frps.toml` 可被识别用于二进制升级，但不会自动迁移目录或修复旧配置。旧 `transport.wireProtocol` 服务端字段应先按文档人工纠正，否则严格配置验证会阻止升级。
- 二进制升级**不会修复旧版公网绑定、HTTP 分发或错误客户端配置**。若旧 HTTP 服务曾向不可信网络开放证书目录，应按私钥可能泄漏处理，轮换 CA、两端证书及凭据，停止旧分发服务；仅删除 ZIP 或升级程序不能撤销已泄露的密钥。

FRP/GOST 使用官方 Release 二进制，不是通过本项目建立的 apt 软件仓库。`apt` 仅安装系统依赖；`apt upgrade` 不会替你升级这些组件。

## 本地验证与边界

离线测试（不会修改主机服务或连接 VPS）：

```bash
python3 -I -m unittest discover -s tests -v
```

测试涵盖摘要/归档/模板校验、Bash 语法、证书签发/用途/IP 校验、模拟离线打包、下载失败传播和模拟的原子升级/回滚。打包测试使用合成的 EXE 占位文件，不会执行 Windows 程序或证明真实安装成功。

GOST 的 `-C ... -O yaml` 仅解析并输出配置，不加载服务、验证监听或进行 TLS 握手；FRP 使用自身 `verify -c`。服务持续运行检查也不等于网络健康检查。

`tests/integration_local.py` 是需要显式启用官方二进制下载/执行的可选回环协议测试；本次执行被权限策略拦截，尚未运行。真实 Linux systemd 安装、Windows PowerShell/Servy 安装、实际 S-UI 到住宅出口仍需在隔离测试机验收，不能用 `bash -n` 或静态字段检查替代。

## 官方依据

本次字段核对基线：**FRP v0.71.1、GOST v3.3.2、Servy v10.7**；安装默认动态获取官方稳定 Release，不将这些版本号当作永远的“最新版”。

- FRP：[服务端字段](https://gofrp.org/en/docs/reference/server-configures/)、[客户端字段](https://gofrp.org/en/docs/reference/client-configures/)、[TLS](https://gofrp.org/en/docs/features/common/network/network-tls/)。`wireProtocol` 仅配置在客户端；新服务端配置限制代理端口并绑定回环。
- 固定版本源码：[FRP server.go](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/server.go)、[client.go](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/client.go)。
- GOST：[远程转发](https://gost.run/en/tutorials/port-forwarding/)、[TLS](https://gost.run/en/tutorials/tls/)、[Multiplex TLS](https://gost.run/en/reference/listeners/mtls/)、[relay](https://gost.run/en/reference/handlers/relay/)。反向转发的 `chain` 属于 `listener`，不能放在服务根级。
- [Servy 官方文档与发布](https://github.com/aelassas/servy)。
