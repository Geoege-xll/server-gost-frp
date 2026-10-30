====================================================================
TikTok 住宅机离线部署说明（FRP + GOST）
====================================================================

【安装】
1. 完整解压 VPS 生成的 windows_frp_gost_pkg.zip 到运行目录以外的位置，例如桌面。
2. 右键【一键安装(以管理员运行).bat】，选择【以管理员身份运行】；
   也可双击后同意 PowerShell 的 UAC 请求。安装和卸载都将保留脚本退出码。
3. 参数仍含 PLACEHOLDER 或离线文件缺失时，在系统变更前退出（代码 1）；
   旧服务冲突时拒绝继续操作。独立模板不能直接安装，请使用 VPS 生成的完整包。

离线包根目录必须有 frpc.exe、gost.exe、ca.crt、client.crt、client.key；
servy/ 必须保留完整发行包目录树（可含顶层文件夹），其中恰好一个 servy-cli.exe。
安装器不会在线补下载，也不会从 PATH 或旧 C:\Tools 借用程序。

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

【SOCKS5 账号密码备份】
安装脚本写入 gost.yaml 时，会同步保存：
  C:\Tools\TikTokFrpGost\SOCKS5账号密码.txt
文件包含配套 VPS、住宅机本地地址、VPS 回环出站地址，以及实际使用的 SOCKS5
账号和密码；使用 UTF-8 BOM 与 Windows 换行，可用记事本打开。终端会提示路径。
账号密码由 VPS 生成并随离线包注入，住宅机不会另行生成；重新安装时按本次包
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
运行【一键卸载(以管理员运行).bat】，仅停止并注销 TikTok_FRP、TikTok_FRPGost。
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
