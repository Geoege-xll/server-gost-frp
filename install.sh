#!/bin/bash
# ==============================================================================
# 🚀 TikTok 日本/跨境电商双入站物理隔离网络 - VPS 一体化主入口引导脚本
# 仓库：https://github.com/Geoege-xll/server-gost-frp
# 功能：交互式 2 选 1 安装菜单、平滑升级、快捷运维
# ==============================================================================

set -e

# 必须以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限运行此脚本！(例如 sudo bash $0)\033[0m"
    exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main"

# 检查网络镜像加速 (国内网络自动/手动切换)
check_mirror() {
    if ! curl -s --connect-timeout 3 -I "https://raw.githubusercontent.com" >/dev/null 2>&1; then
        echo -e "\033[33m⚠️ 检测到直连 GitHub 访问受限，已自动启用加速镜像源...\033[0m"
        REPO_RAW="https://ghproxy.net/https://raw.githubusercontent.com/Geoege-xll/server-gost-frp/main"
    fi
}

install_pure_gost() {
    echo -e "\n\033[36m🚀 正在启动【方案一：纯 GOST v3 极速架构】安装程序...\033[0m\n"
    if [ -f "./01_Pure_GOST_v3/install_vps_gost_v3.sh" ]; then
        bash ./01_Pure_GOST_v3/install_vps_gost_v3.sh
    else
        check_mirror
        bash <(curl -fsSL "${REPO_RAW}/01_Pure_GOST_v3/install_vps_gost_v3.sh")
    fi
}

install_frp_gost() {
    echo -e "\n\033[36m🚀 正在启动【方案二：FRP + GOST 经典双进程架构】安装程序...\033[0m\n"
    if [ -f "./02_FRP_GOST/install_vps_frp_gost.sh" ]; then
        bash ./02_FRP_GOST/install_vps_frp_gost.sh
    else
        check_mirror
        bash <(curl -fsSL "${REPO_RAW}/02_FRP_GOST/install_vps_frp_gost.sh")
    fi
}

upgrade_service() {
    echo -e "\n\033[36m🔍 正在检查当前 VPS 已运行的隧道服务...\033[0m"
    if systemctl is-active --quiet gost 2>/dev/null; then
        echo -e "   -> 检测到已运行 \033[32mGOST v3\033[0m 服务，正在执行平滑升级..."
        if [ -f "./01_Pure_GOST_v3/install_vps_gost_v3.sh" ]; then
            bash ./01_Pure_GOST_v3/install_vps_gost_v3.sh --upgrade
        else
            check_mirror
            bash <(curl -fsSL "${REPO_RAW}/01_Pure_GOST_v3/install_vps_gost_v3.sh") --upgrade
        fi
    elif systemctl is-active --quiet frps 2>/dev/null; then
        echo -e "   -> 检测到已运行 \033[32mFRP\033[0m 服务，正在执行平滑升级..."
        if [ -f "./02_FRP_GOST/install_vps_frp_gost.sh" ]; then
            bash ./02_FRP_GOST/install_vps_frp_gost.sh --upgrade
        else
            check_mirror
            bash <(curl -fsSL "${REPO_RAW}/02_FRP_GOST/install_vps_frp_gost.sh") --upgrade
        fi
    else
        echo -e "\033[33m[!] 未检测到后台有运行中的 gost 或 frps 守护服务。\033[0m"
        echo "请选择您要升级的具体方案："
        echo "1) 升级 GOST v3"
        echo "2) 升级 FRP"
        read -p "请输入 [1-2]: " UP_CHOICE </dev/tty
        if [ "$UP_CHOICE" == "1" ]; then
            check_mirror
            bash <(curl -fsSL "${REPO_RAW}/01_Pure_GOST_v3/install_vps_gost_v3.sh") --upgrade
        elif [ "$UP_CHOICE" == "2" ]; then
            check_mirror
            bash <(curl -fsSL "${REPO_RAW}/02_FRP_GOST/install_vps_frp_gost.sh") --upgrade
        fi
    fi
}

# 命令行静默参数直接处理
if [ "$1" == "1" ] || [ "$1" == "gost" ]; then
    install_pure_gost
    exit 0
elif [ "$1" == "2" ] || [ "$1" == "frp" ]; then
    install_frp_gost
    exit 0
elif [ "$1" == "3" ] || [ "$1" == "--upgrade" ] || [ "$1" == "-u" ] || [ "$1" == "upgrade" ]; then
    upgrade_service
    exit 0
fi

# 交互式主菜单
clear
echo "======================================================================"
echo -e "\033[36m🚀 TikTok 日本/跨境电商双入站物理隔离网络 - VPS 一体化安装引擎\033[0m"
echo -e "   项目源码: \033[34mhttps://github.com/Geoege-xll/server-gost-frp\033[0m"
echo "======================================================================"
echo ""
echo -e "请选择您想要部署或操作的方案：\n"
echo -e "  \033[32m[1]\033[0m \033[1m方案一：纯 GOST v3 极速架构\033[0m \033[33m【🌟 强烈推荐】\033[0m"
echo -e "      • 架构：单进程、全链路 mTLS 强证书认证、TCP NoDelay 零延迟"
echo -e "      • 优势：超轻量 (~15MB 内存)、无 FRP 协议指纹、视频流极度丝滑、排障最简单"
echo ""
echo -e "  \033[32m[2]\033[0m \033[1m方案二：FRP + GOST 经典双进程架构\033[0m"
echo -e "      • 架构：FRP v0.71.1 (WireProtocol v2 硬件 AEAD) + GOST v3.3.2 出口网关"
echo -e "      • 优势：经典架构成熟稳健、带 WebStatus 仪表盘、适合习惯 FRP 的团队"
echo ""
echo -e "  \033[32m[3]\033[0m \033[1m在线平滑升级内核 (保留现有配置与证书)\033[0m"
echo -e "  \033[31m[4]\033[0m 退出安装"
echo ""
echo "----------------------------------------------------------------------"
read -p "请输入序号 [1-4] (默认回车选择 1 纯GOSTv3): " USER_CHOICE </dev/tty
USER_CHOICE=${USER_CHOICE:-1}

case "$USER_CHOICE" in
    1)
        install_pure_gost
        ;;
    2)
        install_frp_gost
        ;;
    3)
        upgrade_service
        ;;
    4)
        echo "已退出安装。"
        exit 0
        ;;
    *)
        echo -e "\033[31m输入错误，请输入 1 ~ 4 之间的数字！\033[0m"
        exit 1
        ;;
esac
