# VPS 中继与 Windows / Mac 住宅出口部署

提供两套可选的反向 TCP 隧道方案：**纯 GOST v3** 与 **FRP + GOST**。住宅机支持 Windows 与 macOS，均主动连接 VPS，无需住宅宽带具备公网入站地址。首次安装先选方案，再选住宅机系统。

本项目不安装、不修改 S-UI，也不保证平台账号安全、固定内存占用或“零延迟”。性能和稳定性取决于两端设备、网络及实际负载。

## 选择方案

| 项目 | 纯 GOST v3 | FRP + GOST |
| --- | --- | --- |
| VPS 进程 | GOST | frps |
| 住宅机进程（Windows / Mac） | GOST：SOCKS 与反向转发 | GOST：SOCKS；frpc：反向转发 |
| 后台管理 | Windows：Servy；Mac：系统 launchd | Windows：Servy；Mac：系统 launchd |
| 传输与认证 | Multiplex TLS + 双向证书认证 + relay 账号密码 | TCP/TLS + 双向证书认证 + FRP Token |
| 适用情况 | 希望减少组件和配置数量 | 已熟悉 FRP 或需衔接其现有部署 |
| 详细说明 | [纯 GOST](01_Pure_GOST_v3/README_GOST_V3.md) | [FRP + GOST](02_FRP_GOST/README_FRP_GOST.md) |

**注意：GOST 的 `mtls` 是 Multiplex TLS（多路复用 TLS），不是“双向认证”的开关。** 双向认证来自两端 CA、证书、私钥及客户端服务器身份校验配置。

## 流量路径与端口

```text
设备 → VPS S-UI / VLESS Reality :8443（已有或自行配置）
     → VPS 127.0.0.1:10001
     → 住宅机主动建立的加密反向隧道（VPS TCP :9000）
     → Windows / Mac 127.0.0.1:10000 SOCKS5 → 住宅宽带出口

Windows 住宅机可另行使用：
维护电脑 → SSH 本地转发 → VPS 127.0.0.1:33389
         → 反向隧道 → Windows 127.0.0.1:3389
Mac 客户端只建立 SOCKS 映射，不照搬 Windows RDP、不自动开启 SSH / 屏幕共享。
```

- 新生成的 SOCKS 映射绑定 **VPS 127.0.0.1:10001**；Windows 另有回环 RDP 33389。Mac 不申请 33389，FRP 的 Mac 服务端仅允许申请 10001，不直接公开 SOCKS/RDP。
- 当前方案提供 TCP 转发；不能据此保证 UDP、QUIC、DNS 或 IPv6 流量全部经过住宅出口，需按客户端和路由策略单独验收。
- S-UI 出站需能访问宿主机回环地址；如果 S-UI 在独立容器网络中，容器的 `127.0.0.1` 不等于 VPS，需另行设计受限的容器到宿主机连接，不能简单公开代理端口。

## 前置条件

- VPS：Debian / Ubuntu，运行中的 systemd，root 权限，amd64 或 arm64。脚本要求 `apt-get` 与 `flock`（util-linux）。其他发行版不在自动部署范围内。
- Windows：x64 Windows 10/11 或 Windows Server 2019 及以上，64 位 Windows PowerShell 5.1 或 PowerShell 7（5.1 需系统自带 .NET Framework 4.8）、管理员权限。Windows on ARM 不在当前支持范围内。组件已在离线包内预置，安装时不联网，也不要求系统自带 `tar.exe` 解压 `.7z`。
- Mac：macOS 12 或以上，Apple Silicon / Intel，系统自带的 Bash、curl、plutil、shasum、tar 与 launchctl；无需 Python、Homebrew 或 Servy。使用普通本地账号执行 `sudo bash setup_macos.sh`，后台进程使用该普通账号而不是 root。实际系统兼容性仍需实机验收。
- RDP 仅适用于 Windows，需自行启用，通常需要 Pro/Enterprise/Server、有效账号和网络级身份验证；脚本不会启用 RDP 或修改 Windows 防火墙。
- VPS TCP 9000 必须可从住宅机访问；8443 由你的 S-UI 设置决定。脚本不修改防火墙、IPv6、系统路由或现有 S-UI 配置。
- VPS 需通过 HTTPS 访问 GitHub API、Linux Release 和仓库 codeload；自动发现 IPv4 时访问 `https://api.ipify.org`。可用 `VPS_PUBLIC_IP` 显式指定地址，避免该发现请求。
- 安装包始终为完整离线包：VPS 在打包时下载、校验并内置所选系统的全部组件，住宅机安装时无需访问 GitHub。Mac 包同时内置 amd64 与 arm64 两种架构，安装脚本按本机架构选择，不使用 VPS 架构代替客户端架构。

## 首次安装：先选方案，再选住宅机系统

**先检查完整仓库源码，再运行。请确认所用提交包含当前安全修复；尚未推送的本地修改不会出现在 GitHub 在线入口中。** 不要用旧版本脚本覆盖已配置的 VPS。

在完整仓库目录中：

```bash
sudo bash install.sh
# 第一步：1 纯 GOST、2 FRP + GOST、3 升级、4 退出。
# 首次安装第二步：1 Windows、2 macOS。回车不会默认安装。

# 或跳过全部菜单，显式选择方案和住宅机系统：
sudo bash install.sh gost --client windows
sudo bash install.sh frp --client windows
sudo bash install.sh gost --client mac
sudo bash install.sh frp --client mac

# 指定证书绑定的 VPS 公网 IPv4：
sudo env VPS_PUBLIC_IP=203.0.113.10 bash install.sh gost --client mac
```

省略 `--client` 时，首次安装会交互询问住宅机系统；非交互执行必须指定。选择升级时不询问住宅机系统，也不允许用 `--client` 切换系统。

两套方案共用 9000/10001（Windows 另用 33389），**不支持在同一 VPS 同时安装**。检测到已有配置目录、服务、目标二进制或本方案旧 ZIP 时，首次安装会拒绝覆盖；不要通过删除现有目录来强行绕过，应先备份并规划迁移。

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

可以在最后一行追加 `gost --client mac`、`frp --client windows` 或 `gost --upgrade`。如果需要固定仓库快照，下载并审阅对应提交的入口文件，并设置 `REPO_COMMIT=<完整40位提交号>`。HTTPS 与提交固定不能替代源码审阅，也不是独立的代码签名。

两个方案子目录下的 Bash 入口仍可从**完整仓库**运行，但不支持单独下载后执行。

## 安装会做什么

1. 安装所需系统依赖，不做全局网络“优化”。
2. 查询官方稳定 Release，按 Linux 架构选择文件；下载后验证 GitHub 官方资产元数据中的 SHA-256，缺少摘要或校验失败即终止，不回退到未校验版本。
3. 生成私有 CA、服务端和客户端证书；服务端 SAN 绑定公网 IPv4。CA 有效期 3650 天，叶证书 825 天，并限定 serverAuth/clientAuth 用途。
4. 按住宅机系统从仓库模板生成安装包。安装包为完整离线包：除安装/卸载脚本、连接参数、`ca.crt`、`client.crt`、`client.key`、`components.json` 和 `VERSIONS.txt` 外，还内置已在 VPS 校验的全部程序——Windows 为 `gost.exe`、可选 `frpc.exe` 与完整 `servy/` 树；Mac 为两种架构的 GOST/可选 frpc 及 `offline-sha256.txt`，不包含 Servy。
5. Linux 下载/校验、客户端元数据校验、证书与打包成功后写入本方案路径，注册 systemd 服务并检查服务是否持续运行。任一组件在 VPS 上下载或校验失败即终止，不会生成缺程序的包。
6. 输出 ZIP 路径、包模式及 S-UI SOCKS 凭据。服务运行不代表住宅机已经接入，必须完成后面的链路验收。

| 项目 | 纯 GOST | FRP + GOST |
| --- | --- | --- |
| VPS 二进制 | `/usr/local/bin/gost` | `/usr/local/bin/frps` |
| VPS 配置 | `/etc/gost/gost.yaml` | `/etc/frp/frps.toml` |
| 证书目录 | `/etc/gost/certs/` | `/etc/frp/certs/` |
| systemd 服务 | `gost` | `frps` |
| Windows 离线包 | `/root/windows_gost_v3_pkg.zip` | `/root/windows_frp_gost_pkg.zip` |
| Mac 离线包 | `/root/macos_gost_v3_pkg.zip` | `/root/macos_frp_gost_pkg.zip` |
| Mac 运行目录 | `/Library/Application Support/ResidentialTunnel/gost` | `/Library/Application Support/ResidentialTunnel/frp` |
| Mac launchd 标识 | `org.residentialtunnel.gost.gost` | `org.residentialtunnel.frp.gost`、`org.residentialtunnel.frp.frpc` |

Windows 的具体运行目录、服务名和旧版迁移说明见对应[纯 GOST 文档](01_Pure_GOST_v3/README_GOST_V3.md)或 [FRP + GOST 文档](02_FRP_GOST/README_FRP_GOST.md)。现有内部标识保持兼容，不因主页措辞调整而改名。

配置目录与 ZIP 默认仅 root 可访问。CA 私钥留在服务端证书目录中，**不会进入任何客户端包**；客户端 ZIP 含客户端私钥与凭据，必须当作秘密文件保管。证书续期和更换 VPS IP **尚未自动化**，应提前规划两端证书轮换；`--upgrade` 不续期。

## 将配置包交给 Windows

首次安装完成时，脚本会自动创建一个**一次性临时下载账号**，并把下载指引按 **第 1–4 步** 分行打印：第 1 步是可整行复制的下载命令（Windows 是 PowerShell 语法，下载后自动比对 SHA-256；Mac 是终端语法），第 2 步提示首次连接输入 yes，第 3 步单独输出密码一行（提示“不回显属正常”），第 4 步给出预期 SHA-256。该账号不是 root，家目录里只有这一个配置包，且**经 SSH 强制限定为仅可取包**：安装器在 `sshd_config` 末尾追加一段带标记的 `Match Group pkgdl` 规则（追加前备份、`sshd -t` 校验、失败自动回滚、`systemctl reload` 不中断现有连接），配合 ForceCommand 白名单封装只放行 sftp 子系统（以 `-R` 只读模式运行，仅可下载、禁止上传/改名/删除）与对家目录内配置包的 `scp -f` 下载——**没有交互 shell、没有上传、没有端口转发**，因此拿到密码的人也无法在 VPS 上执行命令。账号次日过期，25 小时后由**持久化 systemd 定时器**自动删除（重启不丢失；定时器先 `terminate-user` 再 `userdel -r`，驻留进程无法卡住清理），也可随时 `userdel -r <账号>` 撤销；**链路验证通过后脚本会立即删除该账号并关闭下载通道**（同样先终止会话；万一删除失败会先锁定账号再提示）。住宅机复制命令、粘贴密码即可完成下载和校验，**全程不需要服务器 root 密码**。装了 WinSCP 的机器可改用输出里的 `sftp://` 一步登录 URL。若服务器 SSH 禁用了密码登录，或安装器无法安全写入上述 sshd 限制（校验不通过会自动回滚并放弃建号），临时账号不可用，回退用 root 密钥。

离线包仍含客户端私钥、密码与全部组件，不是可公开分享的普通安装器。配置包同时保留在 `/root/` 下，可随时用 root SFTP 重新下载：

```bash
scp root@<VPS_IP>:/root/windows_gost_v3_pkg.zip .
# FRP 方案则下载 /root/windows_frp_gost_pkg.zip
```

项目刻意**不提供 HTTP/浏览器下载**：包内含客户端私钥与凭据，明文或无认证的 URL 等于把密钥放在公网（URL 会进入浏览器历史与访问日志）。需要方便分发时，正确的方向是每台机器独立证书，而不是公开链接。

### 安装后等待住宅机并自动验证

首次安装结束时可直接选择“等待并验证”，或之后随时运行（凭据在安装时以 root 权限保存于服务端配置目录，仅用于此项验证）：

```bash
bash install.sh gost --verify   # FRP 方案改为 frp；VERIFY_TIMEOUT_MIN=60 可延长等待
```

它会每 5 秒检查反向映射，住宅机安装完成后自动完成并输出 PASS/FAIL：

- 10001（及 Windows 的 33389）**仅监听 127.0.0.1**，绑定公网立即 FAIL；
- **匿名**与**错误密码**的 SOCKS5 请求必须被拒绝；
- 正确凭据经 `VPS 回环 → 反向隧道 → 住宅 SOCKS → 住宅出口` 访问成功，并显示出口 IP（应等于住宅宽带公网 IP、不等于 VPS IP）。

验证只做本机只读探测，不修改任何服务（例外：**验证全部通过时会自动删除临时下载账号**——先停用其清理定时器并 `terminate-user` 终止全部会话，再删除账号与家目录；万一 `userdel` 仍失败会先锁定账号并提示手动处理，`/root/` 下的配置包保留供住宅机重装）；不包含 S-UI 出站切换、RDP 实际登录和住宅机服务/ACL 状态。早于本功能的旧部署没有存储凭据，会提示手动 `curl` 命令。

Windows 上完整解压 ZIP 到运行目录之外。**仅使用 PS1 入口，新包不再包含 BAT**。打开 64 位 **Windows PowerShell 5.1 或 PowerShell 7**（两者均可），进入解压后的方案目录（不是 ZIP 内或 `C:\Windows\System32`），运行对应的一条安装命令：

```powershell
# 纯 GOST
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_gost_v3.ps1" -PauseOnFailure
# FRP + GOST（两方案不可同时安装）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_frp_gost.ps1" -PauseOnFailure
```

不要双击/右键运行 PS1。非管理员会请求 UAC；`-PauseOnFailure` 会传给提权子进程，失败时等待回车。父窗口保留，可用 `$LASTEXITCODE` 查看退出码。`-ExecutionPolicy Bypass` 仅限该子进程，不永久修改执行策略。卸载使用同目录的 `uninstall_gost_v3.ps1` / `uninstall_frp_gost.ps1`，传同样的可选 `-PauseOnFailure`；默认保留运行目录和凭据。

可先运行只读诊断：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\diagnose_windows.ps1" -Pause`。它检查语法、文件与清单，不下载、不提权、不改服务，不打印凭据或源码片段；通过不代表安装、权限或链路验收通过。

- **完整离线包（唯一模式）**：组件（GOST、Servy，FRP 方案另含 frpc）在 VPS 打包时按固定版本下载、逐个校验官方 SHA-256 后预置进包：Windows 为 `gost.exe`、可选 `frpc.exe` 与完整 `servy/` 树，安装时不联网、不要求 `tar.exe`；Mac 为两种架构的原生程序。缺少文件即失败，不回退 PATH、旧运行目录或在线下载。
- `components.json` 在打包时固定组件版本、精确官方 URL 和 SHA-256；frpc 必须与本次 VPS frps 同版本，纯 GOST 两端也固定同一版本。住宅机不查询 `latest`，不从任何网址下载程序。
- 必须信任从 VPS 安全取得的**整个 ZIP**；包内清单不是独立签名，不能防止 ZIP 本身被篡改。

- 打包后的 PowerShell 文件统一为 UTF-8 BOM 与 CRLF，以兼容 Windows PowerShell 5.1 的中文源码读取。
- 在校验组件和停服务之前检查运行路径 owner/DACL、祖先目录及既有文件树；写入程序、私钥、配置和密码之前，将方案运行目录及内容限制为安装账户、Administrators、SYSTEM。发现不可信 owner 或可写入/删除/改 ACL 的路径时拒绝继续，不自动接管，不修改已有共享 `C:\Tools` 权限。不要用删除整个 `C:\Tools` 或全盘改权限来绕过检查。此保护不涵盖解压包、备份及管理员访问，也不能撤销旧凭据的泄漏。
- 本项目的业务程序使用独立目录与服务，遇到旧 `C:\Tools` 共享服务、归属不明或其他 Servy wrapper 服务时拒绝继续，旧版迁移需人工检查。
- **Servy v10.7 不是完全目录隔离的便携服务管理器**：官方 CLI 会在 `C:\ProgramData\Servy` 部署共享组件及 host，并可能管理它们的生命周期。因此预检会保守拒绝其他 Servy wrapper；本项目卸载不删除共享 host 或 ProgramData，不能保证卸载后机器上不留任何 Servy 组件。
- 重新部署本方案时先停止自己的服务，再替换文件，避免覆盖运行中的 EXE。
- Windows 安装脚本写入配置时，会将实际 SOCKS5 账号、密码及连接地址同步保存到本方案运行目录的 `SOCKS5账号密码.txt`，并显示完整保存路径；具体目录见各方案文档及包内安装说明。TXT 使用 UTF-8 BOM/Windows 换行，不包含隧道认证凭据或证书私钥；重新安装按本次配置包更新，不重新生成账号密码。**文件含明文密码，请勿公开分享**；卸载默认保留，确认删除运行目录时也会删除该文件。
- 不自动添加 Defender 排除项。若安全软件拦截，请检查来源与告警，而不是排除整个 `C:\Tools`。
- 安装会尝试关闭交流供电时的睡眠/休眠超时，并报告失败；不会改变电池策略，不代表断电或网络中断也能保持在线。卸载不会自动恢复原电源策略。
- Servy 开启进程健康监控与异常重启；这不是网络可达性检测，也不是零中断保证。日志大小轮转不等于所有日志合计严格不超过 50MB。

## Mac 住宅机安装与卸载

在 VPS 首次安装时选择 macOS，或指定 `--client mac`。Mac 的安装包与 Windows 分开，不含 Servy、PowerShell 或 BAT。下载方式与 Windows 相同：安装结束时按步骤输出的一次性临时账号命令与密码（次日过期自动删除、链路验证通过后立即删除，无需 root 密码），或用 root SFTP：

```bash
# 在住宅 Mac 上安全下载对应配置包；先核对 SSH 主机指纹。
scp root@<VPS_IP>:/root/macos_gost_v3_pkg.zip .
# FRP 方案改为 macos_frp_gost_pkg.zip。
umask 077
mkdir -m 700 macos-client
unzip macos_gost_v3_pkg.zip -d macos-client
cd macos-client
sudo bash setup_macos.sh

# 卸载自己的 launchd 服务，默认保留配置、证书、日志与凭据 TXT：
sudo bash uninstall_macos.sh
# 确认不再需要这些文件后，显式删除本方案运行目录：
# sudo bash uninstall_macos.sh --purge
```

- 从普通本地账号执行 `sudo`，后台进程使用该账号，plist 与程序由 root 管理。使用系统 LaunchDaemons，不依赖登录桌面的用户会话；无需创建额外账号或安装第三方服务管理器。
- 组件已内置两种架构（`bin/amd64`、`bin/arm64`），安装脚本自动选择原生 Apple Silicon arm64 或 Intel amd64，并使用 `offline-sha256.txt` 校验本地程序；安装不联网，缺少文件不回退 PATH 或旧安装。纯 GOST 两端版本一致，frpc 与 VPS frps 同版。
- 下载、校验、解压与候选配置检查完成后，才停止本方案旧服务。拒绝同名归属不明服务、另一方案或符号链接路径；不按程序名批量终止进程。
- 实际 SOCKS 账号、密码与地址仍写入本方案私有配置目录中的 `SOCKS5账号密码.txt`。它和客户端私钥都是秘密；完整配置包与摘要清单不是独立签名，不应公开分享。
- Mac 只反向映射 SOCKS：`VPS 127.0.0.1:10001 → Mac 127.0.0.1:10000`。不创建 Windows 3389/33389 映射，不启用远程登录、屏幕共享，不改防火墙、电源或系统安全策略。
- `launchd KeepAlive` 是进程重启策略，不等于端到端连通或防睡眠。睡眠、断网仍会断开隧道；启用 FileVault 的 Mac 重启后需先解锁系统卷，不能保证停电后完全无人值守恢复。具体路径、日志、服务标识见包内说明。

## S-UI 对接与验收

在现有 S-UI 中手动添加 SOCKS 出站：`127.0.0.1:10001`，填入 VPS 安装完成时输出的 SOCKS 账号密码。将相应 VLESS Reality 入站（例如 8443）的业务流量路由到该出站。Reality 密钥、客户端和分流规则由你现有配置管理，脚本不覆盖。

住宅机安装后，在 VPS 上检查：

```bash
systemctl status gost      # FRP 方案改为 frps
journalctl -u gost -n 100  # FRP 方案改为 frps
ss -lntp | grep -E ':(9000|10001|33389)\b'  # Mac 无 33389 映射

# 让 SOCKS 端解析目标域名；替换用户和密码。注意命令行凭据可能被进程列表/历史记录看到。
curl --fail --show-error --max-time 20 \
  --proxy socks5h://127.0.0.1:10001 --proxy-user '<用户>:<密码>' \
  https://api.ipify.org
```

出口应与住宅机的实际公网出口一致。还应验证错误 SOCKS 凭据被拒绝、客户端证书校验有效、10001（以及 Windows 的 33389）没有绑定到公网。服务为 `running` 或端口已监听不足以证明这些条件。

### Windows 远程桌面

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
- **只升级 VPS 核心组件**，不会更新住宅机、已有 Windows/Mac ZIP、Servy/launchd 或旧 systemd 配置，也不重新生成配置包。`VERSIONS.txt` 与 `components.json` 记录打包时版本，升级后不要将旧包当作新客户端；`--upgrade` 不能与 `--client` 同用。已有部署目前没有独立的重打包命令，不应通过首次安装强行覆盖或重新签发证书。
- 当前模板的核心组件最低版本为 GOST 3.3.2 / FRP 0.71.1。跨版本升级仍需阅读官方兼容性说明。
- 旧 FRP 路径 `/root/frp/frps`、`/root/frp/frps.toml` 可被识别用于二进制升级，但不会自动迁移目录或修复旧配置。旧 `transport.wireProtocol` 服务端字段应先按文档人工纠正，否则严格配置验证会阻止升级。
- 二进制升级**不会修复旧版公网绑定、HTTP 分发或错误客户端配置**。若旧 HTTP 服务曾向不可信网络开放证书目录，应按私钥可能泄漏处理，轮换 CA、两端证书及凭据，停止旧分发服务；仅删除 ZIP 或升级程序不能撤销已泄露的密钥。

FRP/GOST 使用官方 Release 二进制，不是通过本项目建立的 apt 软件仓库。`apt` 仅安装系统依赖；`apt upgrade` 不会替你升级这些组件。

## 本地验证与边界

离线测试（不会修改主机服务或连接 VPS）：

```bash
python3 -I -m unittest discover -s tests -v
```

测试涵盖摘要/归档/模板校验、固定版本清单、Bash 语法、证书签发/用途/IP 校验、双方案离线模拟打包、下载失败传播和模拟的原子升级/回滚；离线打包使用合成的 EXE 占位文件。PowerShell 预检顺序的静态回归不等于 Windows 运行时测试。

GOST 的 `-C ... -O yaml` 仅解析并输出配置，不加载服务、验证监听或进行 TLS 握手；FRP 使用自身 `verify -c`。服务持续运行检查也不等于网络健康检查。

`tests/integration_local.py` 是需要显式启用官方二进制下载/执行的可选回环协议测试：

```bash
python3 -I tests/integration_local.py --download
```

2026-10-30 经授权，已使用 SHA-256 校验后的官方 GOST v3.3.2 / FRP v0.71.1，在 Linux amd64 VPS 和本机 Apple Silicon Mac 分别通过双向证书认证、GOST Multiplex TLS 反向 TCP、FRP 严格配置验证/v2 反向 TCP。另在独立测试端口完成 Mac → Linux VPS 的双方案真实 SOCKS 链路：VPS 回环 → 反向隧道 → Mac 认证 SOCKS → Mac 出口，回显数据与出口 IPv4 核对通过，错误 SOCKS 密码及匿名认证被拒绝，反向监听仅绑定 VPS IPv4 回环。为避开生产端口，跨机测试包只替换了测试端口，不改协议或证书校验字段；未通过 S-UI 改写或切换生产出站。

VPS 测试进程运行于独立临时服务，限制 CPU、内存、进程数及最长运行时间。测试前后已对比选定生产服务 PID/启动时间/重启计数、已有监听及进程、已检查的部署配置摘要和运行中容器标识，均未改变；这不是 S-UI 数据库或全系统完整性审计。未执行生产安装或替换现有服务，也未执行 Windows 程序。

新增 Mac 的固定双架构清单、双方案离线模拟打包、二级菜单、配置/归档/权限防护通过本地回归；模拟程序均为惰性测试数据，不是官方组件。Mac 的官方原生组件校验与前台跨机协议测试已通过，但脚本与 plist 检查不等于系统服务实装。

上述协议测试不等于完整 Linux 安装、Windows PowerShell/UAC/Servy 实机安装、Intel Mac 实机运行、Mac launchd 开机启动/安装卸载或实际 S-UI 到住宅出口验收。这些仍需在隔离测试机验证，不能用 `bash -n` 或静态字段检查替代。服务端身份错误、非受信客户端证书和隧道凭据错误的负向测试还需使用强化后的错误日志判定重新验证；旧判定可能匹配启动日志中的配置文件名，不将其计作最终负向验收通过。

## 官方依据

本次字段核对基线：**FRP v0.71.1、GOST v3.3.2、Servy v10.7**；安装默认动态获取官方稳定 Release，不将这些版本号当作永远的“最新版”。

- FRP：[服务端字段](https://gofrp.org/en/docs/reference/server-configures/)、[客户端字段](https://gofrp.org/en/docs/reference/client-configures/)、[TLS](https://gofrp.org/en/docs/features/common/network/network-tls/)。`wireProtocol` 仅配置在客户端；新服务端配置限制代理端口并绑定回环。
- 固定版本源码：[FRP server.go](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/server.go)、[client.go](https://github.com/fatedier/frp/blob/v0.71.1/pkg/config/v1/client.go)。
- GOST：[远程转发](https://gost.run/en/tutorials/port-forwarding/)、[TLS](https://gost.run/en/tutorials/tls/)、[Multiplex TLS](https://gost.run/en/reference/listeners/mtls/)、[relay](https://gost.run/en/reference/handlers/relay/)。反向转发的 `chain` 属于 `listener`，不能放在服务根级。
- [Servy 官方文档与发布](https://github.com/aelassas/servy)。
- [Windows 内置 tar 与 `.7z` 支持](https://learn.microsoft.com/en-us/windows/tar/)。
- [Apple launchd / LaunchDaemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。
