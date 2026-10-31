macOS 住宅机安装说明 — 纯 GOST v3

适用范围
- macOS 12 或更新版本；Intel / Apple Silicon 自动选择原生程序。即使终端经 Rosetta 运行，也优先使用 arm64。
- 使用系统自带 Bash 3.2、launchd、plutil 和 shasum；不需要 Homebrew、Python 或第三方服务管理器。
- 仅提供认证 SOCKS5：住宅机 127.0.0.1:10000 -> VPS 127.0.0.1:10001。
- 不映射 RDP、SSH 或屏幕共享。VPS 上额外保留的 33389 端口不由此客户端使用。

准备与安装
1. 使用 VPS 生成的“macOS / 纯 GOST v3”完整 ZIP，在运行目录之外解压。不要使用 Windows 包。
2. 包内应有 setup_macos.sh、uninstall_macos.sh、macos_client.sh、client.conf、components.json，
   以及 ca.crt、client.crt、client.key。不得包含 ca.key、server.key 或 server.crt。
   client.conf 必须是生成器注入的六行 KEY=value，不是可执行脚本；不要添加 shell 命令或引号。
3. 本包为完整离线包：bin/amd64/gost、bin/arm64/gost 已按 components.json 固定的官方版本在 VPS 校验后内置，
   安装时用 offline-sha256.txt 复核本地程序，完全不联网、不查询 GitHub。
   请通过可信渠道传输整个包：摘要不能代替包本身的可信来源。包里含客户端私钥和密码，请勿公开。
4. 在“终端”进入解压目录（可输入 cd 后把文件夹拖入终端），先查看帮助：
     bash ./setup_macos.sh --help
   然后从现有普通本地账户执行：
     sudo bash ./setup_macos.sh
   输入该 Mac 的管理员授权密码，不是 SOCKS5 密码。必须由 sudo 提供有效的 SUDO_USER（本地 uid >= 501）。
   请不要先切换 root shell；不支持新建账户、网络目录账户或更换服务运行账户的覆盖安装。
5. 摘要、程序架构、凭据文件及程序自身的配置解析全部成功后，才停止本方案旧服务并替换程序。
   检测到另一方案、占用 10000 的其他程序、链接路径或不匹配的归属标记时会拒绝操作，不会强杀进程。
   请先正常退出冲突程序，或使用其对应卸载脚本处理；不要手动覆盖已有 LaunchDaemon。

运行位置与验证
- 运行目录：/Library/Application Support/ResidentialTunnel/gost
- 配置及证书：上述目录中的 config/ 和 config/certs/（仅安装账户可读）。
- SOCKS5账号密码.txt：/Library/Application Support/ResidentialTunnel/gost/config/SOCKS5账号密码.txt
  里面是实际写入配置的账号、密码、本地与 VPS 回环端点；不包含隧道令牌、证书或私钥。该文件保存失败会中止安装。
- 日志：/Library/Application Support/ResidentialTunnel/gost/logs/gost.log 和 gost.err.log。
  launchd 不自动轮转这些日志，请自行定期查看并管理磁盘空间。
- LaunchDaemon：/Library/LaunchDaemons/org.residentialtunnel.gost.gost.plist
  只读状态查询：launchctl print system/org.residentialtunnel.gost.gost
- plist 和程序由 root 持有，程序以前述普通账户身份前台运行。系统 launchd 使用 KeepAlive 和 10 秒节流重启。
- 本地成功提示只说明服务在运行且本方案监听了 127.0.0.1:10000，不证明 mTLS、VPS 映射或完整业务链路已连通。
  请检查两端日志，再通过已有受控通道在 VPS 上验证 127.0.0.1:10001 的 SOCKS5 认证及实际出口。
- TLS 严格校验 VPS 的 IPv4 serverName，使用 CA 和客户端证书进行双向认证；不要禁用证书校验。

Mac 特别注意
- 开启 FileVault 的 Mac 重启后，必须先在本地解锁系统磁盘；这不等于磁盘尚未解锁时也能建立隧道。
- 普通注销后 LaunchDaemon 可以继续运行；休眠、合盖、断电或断网时隧道不可用。请自行按设备条件安排供电和睡眠策略。
  安装器不会修改电源/睡眠、系统防火墙、SSH、屏幕共享、Gatekeeper 或隔离属性，也不会绕过系统安全提示。
- 如果系统安全策略阻止程序运行，安装应失败而不是绕过保护。请核实官方来源、系统提示和管理员策略后再处理。
- 覆盖安装会新建配置/日志，原服务先停止，再替换程序。失败时尝试恢复旧文件及原已加载服务；若恢复失败会报告保留现场路径。
  不要同时运行多个安装器；异常退出留下的锁需要管理员先核实没有相关安装进程，再人工处理，不会自动抢锁。

卸载
- 从原安装账户，在同一完整解压包目录执行：
     sudo bash ./uninstall_macos.sh
  仅注销/删除已验证归属的本方案服务和 plist，默认保留整个运行目录、配置、日志和明文凭据。
- 如需连同本方案运行目录彻底删除，先备份需要的 SOCKS5账号密码.txt 和配置，再明确执行：
     sudo bash ./uninstall_macos.sh --purge
  只删除验证过归属的 gost 目录；不会删除 ResidentialTunnel 共享父目录、其他方案或系统文件。
- 默认卸载后留下的本方案目录仍占有其安装归属。切换另一方案前，请用原方案卸载脚本 --purge 清除，避免 SOCKS5 端口冲突。
- 不要手工删除归属标记；无法确认的旧安装会被拒绝，而不是被当成本方案删除。
