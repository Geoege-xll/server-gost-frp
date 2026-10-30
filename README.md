# 🚀 TikTok 日本/跨境电商双入站物理隔离网络自动化部署套件

本项目针对跨境电商与 TikTok 运营中的**网络环境纯净度、账号防关联以及高防封要求**，提供一套标准化、傻瓜式的 **“云端 VPS 中继 + 海外真实住宅宽带 IP 落地”** 物理隔离网络解决方案。

用户运营手机或设备仅需连接云端 VPS 的 VLESS Reality 安全入站，流量将经由专属高强度加密反向隧道，直接从海外住宅 Windows 电脑的纯净原生宽带流出，确保所有平台看到的都是真正的家庭 ISP IP，彻底告别机房机房 IP 污染与风控拦截。

---

## 🧭 双方案选型指南：我该选择哪套方案？

本项目同时提供两种高可用生产级架构，均已实现**全离线打包、5秒极速静默安装、UAC提权引导、防休眠防断连与 Servy v10.7 自愈守护**：

| 评估维度 | 方案一：纯 GOST v3 极速架构【强烈推荐】 | 方案二：FRP + GOST 经典双进程架构 |
| :--- | :--- | :--- |
| **存放目录** | `01_Pure_GOST_v3/` | `02_FRP_GOST/` |
| **进程数量** | **单进程 (`gost.exe`)** 全功能统一处理 | 双进程 (`gost.exe` + `frpc.exe`) 协同 |
| **系统资源占用** | 内存仅需 **约 15MB**，极度轻量稳定 | 内存约 35MB ~ 60MB，两个独立守护服务 |
| **加密与认证** | **全链路金融级 mTLS (双向 10 年证书认证)** | mTLS 双向证书校验 + Token 密码鉴权 |
| **协议优化** | **TCP NoDelay 零延迟缓冲**，视频流传输更丝滑 | FRP v0.71.1 WireProtocol v2 + 多路复用 |
| **抗嗅探与伪装** | 全链路伪装为私有 TLS 流量，抗深度包检测 (DPI) | FRP 协议特征经过 AEAD 与 TLS 双重伪装 |
| **故障排查复杂度** | 极低（单一配置文件 `gost.yaml`，统一日志通道） | 适中（需分别排查 GOST 监听与 FRP 映射日志） |
| **适用人群** | 追求极致性能、低占用、高稳定、维护最简单的团队 | 习惯经典 FRP 面板或需要兼容特定 FRP 既有体系的团队 |

---

## 🏗️ 整体通信拓扑架构

```text
[ 运营端手机 / 电脑 (TikTok App / 浏览器) ]
                   │
                   │  1. VLESS Reality 混淆伪装流量 (端口 :8443)
                   ▼
       [ 云端 VPS (S-UI 管理面板) ]
                   │
                   │  2. 内部安全转发 (127.0.0.1:10001)
                   ▼
       [ 云端反向隧道服务端 (端口 :9000) ]
                   │
                   │  ═════════════════════════════════════════════════════════
                   │   双向加密安全隧道 (mTLS 证书强校验 / AEAD 硬件加速加密)
                   │   无公网 IP 住宅机主动向 VPS 发起并维持的长连接穿透
                   │  ═════════════════════════════════════════════════════════
                   ▼
       [ 海外真实住宅宽带 Windows 电脑 ]
                   ├── 业务流量 ──> 本地出口网关 ──> 日本原生家庭宽带出口访问 TikTok (防风控)
                   └── 维护流量 ──> 本地 RDP (3389) ──> 穿透至 VPS:33389 供远程维护机房
```

---

## 📁 目录文件结构规范

整个项目经过严格区分与规范命名，互不干扰：

```text
server-frp-gost/
├── 01_Pure_GOST_v3/                       # 【方案一】纯 GOST v3 极速架构套件
│   ├── install_vps_gost_v3.sh            # VPS 端一键安装脚本 (服务端部署 + 证书生成 + 离线包合成)
│   ├── README_GOST_V3.md                 # 纯 GOST v3 专属技术文档与实操指南
│   └── windows_client_gost_v3/           # 住宅机端离线客户端组件
│       ├── 一键安装(以管理员运行).bat     # Windows 傻瓜式一键运行入口 (自动 UAC 提权)
│       ├── 一键卸载(以管理员运行).bat     # Windows 一键完全注销清理入口
│       ├── setup_gost_v3.ps1             # 核心部署脚本 (加白/防休眠/证书/Servy单服务化)
│       ├── uninstall_gost_v3.ps1         # 核心卸载脚本
│       └── README_住宅机安装说明.txt      # 住宅机操作说明书 (极简 2 步法)
│
├── 02_FRP_GOST/                          # 【方案二】FRP + GOST 经典双进程架构套件
│   ├── install_vps_frp_gost.sh           # VPS 端一键安装脚本 (frps + 证书 + 离线包合成)
│   ├── README_FRP_GOST.md                # FRP + GOST 专属技术文档与实操指南
│   └── windows_client_frp_gost/          # 住宅机端离线客户端组件
│       ├── 一键安装(以管理员运行).bat     # Windows 傻瓜式一键运行入口 (自动 UAC 提权)
│       ├── 一键卸载(以管理员运行).bat     # Windows 一键完全注销清理入口
│       ├── setup_frp_gost.ps1            # 核心部署脚本 (加白/防休眠/证书/Servy双服务化)
│       ├── uninstall_frp_gost.ps1        # 核心卸载脚本
│       └── README_住宅机安装说明.txt      # 住宅机操作说明书 (极简 2 步法)
│
└── README.md                             # 本总览导航指南
```

---

## ⚡ 极速开始部署 (两步即通)

### 第一步：在云端 VPS 上部署服务端

直接在 VPS 终端执行**一体化一键命令**（终端会弹出交互式菜单供您 2 选 1）：

#### 🌟 交互式 2 选 1 主入口命令（强烈推荐）
```bash
curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/install.sh | bash
```
> 执行后终端将弹出友好的菜单，直接敲键盘 `1` 或 `2` 即可选择部署方案；输入 `3` 即可一键平滑升级现有内核！

---

#### 快捷方式：直接指定方案安装 (跳过菜单选择)
* **【方案一：纯 GOST v3 极速版 (强烈推荐)】**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/01_Pure_GOST_v3/install_vps_gost_v3.sh | bash
  ```
* **【方案二：FRP + GOST 经典双进程版】**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/02_FRP_GOST/install_vps_frp_gost.sh | bash
  ```
*(注：中国大陆境内或直连受限网络可前置加速镜像，如在 `https://raw...` 前追加 `https://ghproxy.net/`)*

---

#### 离线/源码方式：克隆仓库运行
```bash
git clone https://github.com/Geoege-xll/server-gost-frp.git
cd server-gost-frp
bash install.sh
```

> **VPS 脚本自动化处理机制**：
> 1. 自动禁用 IPv6，优化网络栈以杜绝握手超时；
> 2. OpenSSL 自动生成 10 年期的私有根 CA 与服务端/客户端 mTLS 证书；
> 3. 在 VPS 端直接下载 Windows 所需的最新二进制工具（无需住宅机再联网访问 GitHub，彻底解决网络环境波动问题）；
> 4. 生成配置完全注入的纯离线客户端压缩包（`windows_gost_v3_pkg.zip` 或 `windows_frp_gost_pkg.zip`）；
> 5. 自动启动临时 Python HTTP 直链下载服务（20 分钟后自动销毁），并在终端打印下载链接与 S-UI 对接参数。

---

### 第二步：在海外住宅 Windows 电脑上运行客户端

1. **下载解压**：在住宅电脑浏览器中直接打开 VPS 终端输出的直链地址，下载压缩包并解压至桌面。
2. **傻瓜运行**：在解压文件夹中，鼠标右键点击 **`一键安装(以管理员运行).bat`**，选择 **【以管理员身份运行】**。
3. **完成状态**：无需任何人工输入，脚本在 5 秒内自动完成加白、防休眠、证书导入、服务注册自启并完成自检。桌面上还会生成【TikTok服务监控】面板快捷方式。

---

## 🌐 第三步：云端 S-UI 面板对接参数

在 VPS 的 S-UI 面板中配置出站、入站与分流路由：

### 1. 添加出站节点 (Outbounds)
* **标签 (Tag)**: `proxy_jp`
* **协议 (Protocol)**: `socks`
* **地址 (Address)**: `127.0.0.1`
* **端口 (Port)**: `10001`
* **账号与密码**: 填写 VPS 终端在部署结束时打印的专属凭据

### 2. 创建业务专属入站 (Inbounds)
* **协议 (Protocol)**: `vless`
* **端口 (Port)**: `8443`
* **传输协议 (Network)**: `tcp`
* **安全模式 (TLS)**: `reality`
* **伪装目标 (Dest)**: `gateway.icloud.com:443`
* **伪装域名 (SNI)**: `gateway.icloud.com`
* **标签 (Tag)**: `tiktok_in`

### 3. 配置路由规则 (Routing)
* **业务引流**：`Inbound Tag = tiktok_in` $\rightarrow$ `Outbound Tag = proxy_jp`
* **国内直连（可选）**：`geosite:cn / geoip:cn` $\rightarrow$ `direct`

---

## 🔍 验证连通性与日常运维

### 1. 在 VPS 终端验证出口 IP
执行以下命令，测试是否成功走住宅宽带出口：
```bash
# 验证端口监听
ss -antp | grep 10001

# 测试出口 IP (应显示海外住宅机当地 ISP 运营商及地理位置)
curl -x socks5://<账号>:<密码>@127.0.0.1:10001 http://ip-api.com/json
```

### 2. 远程桌面运维 (RDP)
在您自己的电脑打开远程桌面连接 (`mstsc`)，输入：
```text
<VPS公网IP>:33389
```
输入海外住宅 Windows 的用户名与密码，即可随时连入住宅机管理运维。

### 3. VPS 端命令一键平滑升级 (保留配置与证书)
当官方有新版本发布时，直接执行一行升级命令即可自动热更新二进制内核，无需重新配置或生成证书：
```bash
# 纯 GOST v3 方案在线升级：
curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/01_Pure_GOST_v3/install_vps_gost_v3.sh | bash -s -- --upgrade

# FRP + GOST 方案在线升级：
curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/02_FRP_GOST/install_vps_frp_gost.sh | bash -s -- --upgrade
```

---

## 🛡️ 企业级服务自愈与防御机制

1. **零崩溃中断 (Crash-Resilient)**：两套方案均采用 Servy v10.7 注入 `--recoveryAction="RestartService" --maxRestartAttempts=0`，遭遇意外崩溃时由 Windows 操作系统在底层毫秒级自动拉起。
2. **防日志写满磁盘 (Log Rotation)**：配置 `--enableSizeRotation --rotationSize=10 --maxRotations=5`，将运行日志上限严格封顶在 50MB 以内，彻底避免住宅机因磁盘空间耗尽导致崩溃。
3. **断电重启无感自启**：服务注册类型为 `Automatic`，住宅机遇到断电恢复或系统重启后，无需人员登录，Windows 引导时自动拉起隧道与网关。
