# 🚀 TikTok 日本/跨境电商双入站物理隔离方案 - 纯 GOST v3 极速部署指南 (V3.0)

本方案基于 **纯 GOST v3 统一架构**，彻底替代了传统的「FRP + GOST 双进程拼装架构」。通过单二进制、全链路 **mTLS 双向证书高强度加密**、**反向 TCP 穿透 (`rtcp`)**，实现无需公网 IP 的海外住宅 Windows 电脑与云端 VPS 的无缝闭环互联。

---

## 🌟 纯 GOST v3 核心架构优势对比

| 评估维度 | 传统架构 (FRP + GOST 拼装) | 纯 GOST v3 架构 (本项目) |
| :--- | :--- | :--- |
| **进程数量** | 双进程 (`gost.exe` + `frpc.exe`) | **单进程 (`gost.exe`) 全功能统一处理** |
| **内存与资源占用** | 约 35MB ~ 60MB 内存，双守护服务 | **仅约 15MB 内存，极轻量极稳定** |
| **通信加密级别** | FRP 自带 TLS 加密 / Token 密码校验 | **金融级 mTLS (双向证书校验，无证书握手直接断开)** |
| **抗嗅探与扫描** | 暴露特定 FRP 特征，易被网络扫描器识别 | **完全伪装为私有 TLS 流量，抗主动嗅探与探测** |
| **故障排查点** | 需要排查 GOST 监听 + FRP 映射两套日志 | **单一配置文件 (`gost.yaml`)，日志统一，排障极快** |
| **部署流程** | 需分别配置 FRP 客户端和 GOST 客户端 | **一键全离线打包，5 秒全自动完成注册启动** |

---

## 🏗️ 整体通信拓扑流程

```text
[ 用户手机 / 运营设备 ]
        │  (VLESS Reality 混淆，端口 8443)
        ▼
[ 云端 VPS (S-UI 面板) ]
        │  (本地回环 127.0.0.1:10001，安全物理隔离)
        ▼
[ VPS 端 GOST v3 转发服务 (:9000) ]
        │
        │  ══════════════════════════════════════════════
        │   mTLS 双向证书加密隧道 (CA + Server/Client 证书)
        │   Relay 多路复用 + 反向穿透 (rtcp)
        │  ══════════════════════════════════════════════
        ▼
[ 海外住宅宽带 Windows 电脑 ] 
        ├── 业务流量 ──> 本地 SOCKS5 网关 (127.0.0.1:10000) ──> 日本当地干净原生住宅 IP 访问 TikTok
        └── 管理流量 ──> 本地 RDP (127.0.0.1:3389) ──> 穿透到 VPS:33389 供远程维护
```

---

## 📁 目录文件清单

```text
01_Pure_GOST_v3/
├── install_vps_gost_v3.sh            # [VPS端] 一键部署服务端、生成mTLS证书、制作Windows离线包
├── README_GOST_V3.md                 # [本文件] 架构解析与部署配置全说明
└── windows_client_gost_v3/           # [打包模板] 住宅机全离线客户端套件
    ├── 一键安装(以管理员运行).bat      # 双击提权并调用 setup_gost_v3.ps1 傻瓜部署
    ├── 一键卸载(以管理员运行).bat      # 双击一键停止并彻底清理后台服务
    ├── setup_gost_v3.ps1             # 住宅机核心部署逻辑 (白名单/防休眠/证书/服务化)
    ├── uninstall_gost_v3.ps1         # 住宅机卸载清理脚本
    └── README_住宅机安装说明.txt       # 给海外技术人员或合作机主看的傻瓜操作说明
```

---

## 🚀 第一部分：VPS 云端一键部署

### 1. 运行安装脚本 (二选一)

#### 方式 A：一行命令极速安装 (最推荐，无需上传文件)
```bash
curl -fsSL https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main/01_Pure_GOST_v3/install_vps_gost_v3.sh | bash
```

#### 方式 B：手动上传或克隆脚本运行
```bash
chmod +x install_vps_gost_v3.sh
bash install_vps_gost_v3.sh
```

### 2. 脚本全自动执行事项
1. **安装环境依赖**：自动补齐 `curl`, `wget`, `openssl`, `p7zip-full`, `zip` 等。
2. **优化内核**：禁用 IPv6 避免解析分流偏差。
3. **签发 mTLS 证书**：自动利用 OpenSSL 生成有效期为 10 年的根 CA、服务端证书（绑定 VPS 公网 IP SAN）、客户端证书。
4. **生成服务端 GOST 配置**：配置 `handler: relay (bind: true)` 与 `listener: mtls`，并注册为 `systemd` 守护服务 (`gost.service`)，开机自动运行。
5. **在 VPS 本地离线合成 Windows 客户端包**：
   - 自动获取最新 Windows 版 `gost.exe`；
   - 自动获取最新 Windows 版 `servy-cli.exe` 和 `Servy.exe` 图形监控；
   - 注入动态生成的账号密码与 mTLS 证书；
   - 自动压缩为 `/etc/gost/windows_gost_v3_pkg.zip` 与 `/root/windows_gost_v3_pkg.zip`。
6. **启动 20 分钟临时直链下载服务**：终端直接打印出可在浏览器中打开的极速直链。

---

## 💻 第二部分：海外住宅机 Windows 一键部署

### 1. 下载部署包
在 Windows 电脑的浏览器（Edge / Chrome）中，直接访问 VPS 脚本运行结束时输出的下载直链，例如：
```text
http://<VPS_IP>:<RAND_PORT>/windows_gost_v3_pkg.zip
```
*(注：如果直链已过期，可通过 FinalShell / WinSCP 从 VPS 的 `/root/windows_gost_v3_pkg.zip` 下载)*

### 2. 执行安装（仅需两步）
1. 将下载的 `windows_gost_v3_pkg.zip` 解压到桌面或任意文件夹。
2. 鼠标右键点击 **`一键安装(以管理员运行).bat`**，选择 **【以管理员身份运行】**。

### 3. 安装过程全自动化完成
- **自动添加 Defender 信任区**：将 `C:\Tools` 加入排除项，防止误杀。
- **自动配置电源防休眠策略**：接通电源下永不睡眠、永不休眠，保障 7×24 小时在线。
- **自动安装 mTLS 证书**：部署私有双向证书至 `C:\Tools\certs`。
- **自动注册服务并启动**：通过 Servy 注册唯一的 `TikTok_Gost` 系统服务，支持异常自动重启与开机静默自启。
- **生成可视化管理面板**：在 Windows 桌面自动生成【TikTok服务监控】快捷方式。

---

## 🌐 第三部分：S-UI 面板对接配置指南

打开云端 VPS 的 S-UI 管理面板，依次配置出站、入站和路由规则：

### 1. 添加出站节点 (Outbounds)
* **标签 (Tag)**: `proxy_jp`
* **协议 (Protocol)**: `socks`
* **地址 (Address)**: `127.0.0.1`
* **端口 (Port)**: `10001`
* **账号 (Username)**: 填写 VPS 终端打印的 `GostUser`
* **密码 (Password)**: 填写 VPS 终端打印的 `GostPass`

### 2. 创建业务专属入站 (Inbounds)
* **协议 (Protocol)**: `vless`
* **端口 (Port)**: `8443`
* **传输协议 (Network)**: `tcp`
* **安全模式 (TLS)**: `reality`
* **伪装目标 (Dest)**: `gateway.icloud.com:443`
* **伪装域名 (SNI)**: `gateway.icloud.com`
* **标签 (Tag)**: `tiktok_in`

### 3. 配置分流路由规则 (Routing)
在 S-UI 的路由规划中增加：
1. **TikTok 与境外业务流量**：
   - 入站标签 (`inboundTag`): `tiktok_in`
   - 出站目标 (`outboundTag`): `proxy_jp`
2. **国内直连规则 (可选)**：
   - 域名 (`geosite:cn`) / IP (`geoip:cn`) -> `direct`

---

## 🔍 第四部分：网络连通性验收与运维指令

### 1. 在 VPS 端验证连通性
登录 VPS 终端，执行以下命令：

```bash
# 1. 检查住宅机反向穿透端口是否已建立本地监听
ss -antp | grep 10001

# 2. 通过本地 SOCKS5 代理请求外网，测试出口 IP (应显示住宅机的公网 IP 与当地运营商)
curl -x socks5://<用户名>:<密码>@127.0.0.1:10001 http://ip-api.com/json
```

### 2. 远程桌面 (RDP) 连接测试
在本地电脑打开远程桌面连接 (`mstsc`)，输入：
```text
<VPS公网IP>:33389
```
输入住宅机 Windows 的管理员账号与密码，即可直接进行远程桌面运维。

### 3. VPS 端 GOST 服务维护与命令一键升级
```bash
# 查看服务状态
systemctl status gost

# 重启服务
systemctl restart gost

# 查看实时运行日志
journalctl -u gost -f

# 🌟 命令一键平滑升级 (自动拉取最新 GOST 二进制，保留所有配置与证书)
bash install_vps_gost_v3.sh --upgrade
```

### 4. 住宅机端卸载指令
如需更换机房或清理住宅机环境，进入解压目录或 `C:\Tools`，右键管理员身份运行：
**`一键卸载(以管理员运行).bat`**
即可瞬间注销系统服务并按需彻底清理运行目录。
