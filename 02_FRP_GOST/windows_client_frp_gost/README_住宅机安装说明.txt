====================================================================
住宅机部署说明（FRP + GOST，完整离线包）
====================================================================

【安装】
1. 完整解压 VPS 生成的 windows_frp_gost_pkg.zip 到运行目录以外的位置，例如桌面。
2. 打开 64 位【Windows PowerShell】5.1 或【PowerShell】7（不是 CMD），进入解压目录：
     Set-Location -LiteralPath 'C:\Users\你的用户名\Downloads\解压目录'
   不要在 ZIP 内运行，不要双击或右键运行 PS1。本包不提供 BAT 入口。
3. 可先运行只读预检（不联网、不提权、不改服务，不显示密码）：
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\diagnose_windows.ps1" -Pause
   预检通过不代表安装或链路通过。再运行安装：
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_frp_gost.ps1" -PauseOnFailure
   非管理员会请求 UAC；失败窗口等待回车，父窗口保留。用 $LASTEXITCODE 查看退出码。
   -ExecutionPolicy Bypass 仅作用于该子进程，不永久修改系统执行策略。
4. 参数仍含 PLACEHOLDER、清单无效或必需文件缺失时退出（代码 1）；
   旧服务冲突时拒绝继续操作。独立模板不能直接安装，请使用 VPS 生成的完整包。

【包模式与组件准备】
本包为完整离线包，须保留 components.json、windows_components.ps1、diagnose_windows.ps1、
ca.crt、client.crt、client.key 及全部安装/卸载脚本。配置包包含客户端私钥与密码，必须通过 SFTP/SCP 等安全渠道传送。
组件已在 VPS 上按清单中的固定官方版本、URL、SHA-256 下载并校验后随包内置；
frpc 必须与打包时 VPS frps 来自同一 Release，住宅机不查询 latest、不联网下载。
使用 x64 Windows 10/11 或 Server 2019+、64 位 Windows PowerShell 5.1 或 PowerShell 7（5.1 需 .NET 4.8，系统自带）。
安装不要求系统自带 tar.exe，也不下载任何解压器或组件程序。
已有部署不能靠重新首次安装覆盖，也不能通过改清单或复制旧 EXE 来绕过检查。
包根目录须有 gost.exe、frpc.exe，servy/ 须保留完整发行目录树，
其中恰好一个非空 servy-cli.exe 与 Servy.exe；缺少文件即失败。
文件缺失不在线兜底，也不借用 PATH/旧 C:\Tools 程序。
必需组件检查失败时，在停止现有本方案服务之前退出。
清单不是独立签名，不能保护被整体篡改的 ZIP；不要修改清单或公开分享配置包。

【本方案管理范围】
运行目录：C:\Tools\TikTokFrpGost
Windows 服务：TikTok_FRPGost（本地 SOCKS5）、TikTok_FRP（FRP 客户端），均自动启动。
日志目录：C:\Tools\TikTokFrpGost\logs
如果包中有 Servy.exe，会创建【TikTok FRP GOST服务监控】桌面快捷方式。

仅管理本方案服务。重新安装时先停全部服务，再复制程序。
检测到旧 TikTok_Gost，或 TikTok_FRP/同名服务路径不属于本方案时，拒绝安装/卸载，
请先使用对应旧版的卸载方式处理；清理前确认旧脚本不会误删共享文件。
本脚本不修改/删除旧 C:\Tools 共享安装，也不按进程名终止其他程序。
两个方案都使用住宅机本地端口 10000，不能同时运行；冲突时拒绝安装。
Servy 10.7 官方实现会使用共享的 Servy host 服务与 %ProgramData%\Servy，
必要时更新其内嵌运行时；这不是严格的进程级隔离。检测到其他 Servy wrapper
服务时，本脚本会保守拒绝操作，避免其共享运行时更新影响其他安装。
卸载仅删除本方案服务/文件，保留共享 host 与 ProgramData 数据，不做全局清理。
不会自动添加 Windows Defender 排除项。电源设置只对接通电源时禁用自动睡眠/
休眠；失败会显示警告，不能据此保证不断网。卸载不自动还原电源策略。

【运行目录权限】
在校验组件和停服务之前，先只读检查运行路径及既有文件树的 owner、DACL 和链接。
写入程序、私钥或密码前，将本方案目录及既有内容的权限限制为安装账户、
Administrators、SYSTEM。不会修改已有 C:\Tools 的共享权限。
若发现不可信账户持有路径，或具有写入、删除、改 ACL 等危险权限，将拒绝继续，
不自动接管。不要删除整个 C:\Tools 或使用全盘权限重置来绕过；先核对具体报错路径。
此限制不防范管理员或 SYSTEM，也不会修复已泄漏的旧凭据；配置包与备份须自行保护。

【SOCKS5 账号密码备份】
安装脚本写入 gost.yaml 时，会同步保存：
  C:\Tools\TikTokFrpGost\SOCKS5账号密码.txt
文件包含配套 VPS、住宅机本地地址、VPS 回环出站地址，以及实际使用的 SOCKS5
账号和密码；使用 UTF-8 BOM 与 Windows 换行，可用记事本打开。终端会提示路径。
账号密码由 VPS 生成并随配置包注入，住宅机不会另行生成；重新安装时按本次包
同步更新配置与 TXT，不会保留旧包的账号密码。不会写入 FRP Token 或证书私钥。
这是明文密码文件，请妥善保管，不要上传公开仓库或随意转发。
保存 TXT 不代表服务或隧道已经连通；若后续启动失败，凭据文件仍可用于核对。
卸载默认保留整个运行目录；选择删除目录也会删除 TXT，请先备份所需凭据。

【加密、映射与验证边界】
FRP 客户端使用 transport.wireProtocol="v2"、TCP 多路复用与全局 TLS。
CA、客户端证书/私钥和 transport.tls.serverName=VPS 公网 IPv4 用于证书认证；
服务端也须正确要求客户端证书，服务端证书的 IP SAN 必须包含该公网 IPv4。
仅设置证书 CN 不足以通过 IP 校验。脚本只复制证书，不导入系统证书库，
也不验证证书内容。FRP 服务端不应添加客户端专用的 wireProtocol 字段。
全局 TLS 已加密，两个代理的 useEncryption=false，避免重复 payload 加密；
useCompression=false，避免对已经压缩的视频流重复压缩。

两个映射的远端绑定地址只能由 frps 的 proxyBindAddr 控制。
配套服务端必须设置 proxyBindAddr="127.0.0.1"，仅在 VPS 回环监听
127.0.0.1:10001（SOCKS5）和 127.0.0.1:33389（RDP）；客户端 localIP
只决定住宅机转发目标，不能限制 VPS 监听地址。
RDP 不能直连 VPS 公网 IP:33389；应通过 SSH 本地转发或其他受控通道访问。
例如在管理电脑执行：
  ssh -N -L 13389:127.0.0.1:33389 SSH用户@VPS公网IP
再用远程桌面连接管理电脑的 127.0.0.1:13389，并使用 Windows 自身账号认证。
此方案不会自动启用住宅机 RDP、放宽防火墙或取消 Windows 登录认证。

安装成功只表示配置通过 frpc verify、指定 Windows 服务为 Running，且本方案
的 gost.exe 已监听本地 10000 端口；不证明 SOCKS5 认证、FRP 登录、TLS、
VPS 映射或端到端访问成功。请结合两端日志，分别验证实际业务链路。
Servy 的 --enableHealth 启用进程健康监测及恢复，--maxRestartAttempts=0
表示无限重试；它不是端到端网络健康检测。

【卸载】
在同一已打开的 Windows PowerShell 窗口、解压目录中运行：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\uninstall_frp_gost.ps1" -PauseOnFailure
仅停止并注销 TikTok_FRP、TikTok_FRPGost；运行前同样检查运行目录权限与服务归属。
确认后才删除 C:\Tools\TikTokFrpGost（含证书、配置、日志和账号密码 TXT）；默认保留。
不会删除 C:\Tools 整个目录、旧版共享快捷方式或其他方案服务。
若提示文件占用，先关闭本方案的 Servy 界面再重试，不会无差别杀进程。

【官方参考】
https://gofrp.org/en/docs/reference/client-configures/
https://gofrp.org/en/docs/reference/proxy/
https://gofrp.org/en/docs/features/common/network/network/
https://gofrp.org/en/docs/features/common/network/network-tls/
https://github.com/aelassas/servy/wiki/Servy-CLI
https://github.com/aelassas/servy/wiki/Health-Monitoring-&-Recovery
https://learn.microsoft.com/en-us/windows/tar/
