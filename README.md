# 🚀 Telegram MTProto 代理一键部署脚本集合

适用于 Ubuntu / Debian 系统，全面兼容 **x86_64** 与 **ARM64 (aarch64)** 架构。
本项目提供两种不同底层语言的 Telegram 代理部署方案，以应对不同的网络封锁环境和延迟需求。

---

## ⚖️ 版本选择指南：我该用哪个？

| 特性 | 🐹 Go 语言版 (`mtg_manager.sh`) | ⚡️ C 语言版 (`install_mtproxy*.sh`) |
| :--- | :--- | :--- |
| **延迟** | 较高  | 极低 |
| **抗封锁能力** | **极强 (Active Probing 防御)** | 较弱 (仅表面特征伪装) |
| **Fake-TLS** | 深度模拟，完美伪装 HTTPS | 浅层伪装 |
| **适用场景** | 封锁严厉、连接经常被阻断重置的宽带 | 封锁较轻，追求极致聊天/刷图速度 |
| **管理方式** | 交互式菜单 (一键安装/卸载) | 命令行一键运行 |

---

## 🛠️ 方案一：Go 语言版 (mtg) - 交互式管理脚本 [强烈推荐]

本脚本采用 9seconds 开发的 `mtg` 作为核心。提供友好的多选菜单，**每次安装自动生成全新的随机密钥**，彻底解决特征封锁。

### 文件：`mtg_manager.sh`
```bash
wget -O mtg_manager.sh https://raw.githubusercontent.com/luiaye/MTProxy/refs/heads/main/mtg_manager.sh
chmod +x mtg_manager.sh
sudo bash mtg_manager.sh
菜单功能

1. 安装 / 重新配置：

• 提示输入端口（默认 33380）。
• 提示输入 Fake-TLS 伪装域名（直接敲回车即可使用默认的 update.microsoft.com，留空使用默认域名）。
• 全自动编译安装最新版 Go 语言环境及代理源码。
• 安装完成后自动输出一键导入链接 tg://proxy?... (ee 开头密钥)。

2. 彻底卸载：

• 一键清理 systemd 服务、二进制文件、源码及配置目录。

───

🛠️ 方案二：官方 C 语言版 (修改版) - 极致低延迟

如果你追求最低的延迟，且网络环境对原版 MTProto 宽容度较高，请使用此方案。此方案分为带 TLS 伪装和不带 TLS 伪装两个独立脚本。

1. 官方加 TLS 版 (推荐)
文件：install_mtproxytls.sh
生成 ee 开头的密钥，默认使用 www.cloudflare.com 作为伪装域名（浅层 HTTPS 伪装）。
wget -O install_mtproxytls.sh https://raw.githubusercontent.com/luiaye/MTProxy/refs/heads/main/install_mtproxytls.sh
chmod +x install_mtproxytls.sh
sudo bash install_mtproxytls.sh

2. 原生纯净版 (无 TLS 伪装)
文件：install_mtproxy.sh
生成纯净的 dd 开头密钥。注意：此模式极易被 GFW 秒封。
wget -O install_mtproxy.sh https://raw.githubusercontent.com/luiaye/MTProxy/refs/heads/main/install_mtproxy.sh
chmod +x install_mtproxy.sh
sudo bash install_mtproxy.sh
3. 彻底卸载 C 语言版

文件：uninstall_mtproxy.sh
无论你是用上面哪个脚本安装的 C 版，都可以用这个脚本干净卸载。
wget -O uninstall_mtproxy.sh https://raw.githubusercontent.com/luiaye/MTProxy/refs/heads/main/uninstall_mtproxy.sh
chmod +x uninstall_mtproxy.sh
sudo bash uninstall_mtproxy.sh
───

🔧 本项目核心修复与优化说明

为了让代理能在现代服务器（尤其是 ARM 架构云主机）上完美运行，我们在这套脚本中做了以下底层修复：

1. 修复高 PID 崩溃 Bug (C版)

• 症状：官方 C 语言版在现代 Linux 机器上，若分配到的 PID > 65535，会触发 Assertion !(p & 0xffff0000) 导致进程无限崩溃闪退（假死）。
• 修复：部署脚本内嵌 Python 热补丁，在编译前动态修改 common/pid.c，保留低 16 位以绕过断言，实现完美稳定运行。

2. 完美支持 ARM 架构适配 (C版 & Go版)

• C版：脚本自动检测架构，如果是 aarch64，会自动在 Makefile 中剥离 x86 独占的指令集（-mpclmul, -mssse3 等），并通过正则替换掉源码中写死的 x86 汇编（将 rdtsc 替换为 cntvct_el0，将 mfence 替换为 dmb ish）。
• Go版：自动识别系统架构，拉取对应架构的 Golang 编译器进行原生编译。
