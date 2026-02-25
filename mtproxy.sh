#!/usr/bin/env bash
# ====================================================
# Telegram MTProto Proxy 一键终极管理脚本
# 支持：Go语言版(mtg) / 官方C版+TLS / 官方C版原生
# 适配：x86_64 / ARM64 (aarch64) 自动打补丁
# ====================================================

set -e

if [[ $EUID -ne 0 ]]; then
echo "❌ 错误: 请使用 root 用户运行此脚本"
exit 1
fi

# 基础目录配置
WORKDIR_C="/opt/MTProxy"
WORKDIR_GO="/opt/mtg-src"
SECRET_DIR="/root/MTProxy"
SERVICE_C="/etc/systemd/system/mtproxy.service"
SERVICE_GO="/etc/systemd/system/mtg.service"
GO_VER="1.24.6"

mkdir -p "$SECRET_DIR"

# 停止并清理正在运行的代理（防端口冲突）
function cleanup_running_services() {
echo "正在停止旧服务..."
systemctl stop mtproxy mtg 2>/dev/null || true
systemctl disable mtproxy mtg 2>/dev/null || true
}

# ----------------------------------------------------
# 核心构建：编译官方 C 语言版
# ----------------------------------------------------
function build_c_mtproxy() {
echo "[1/4] 安装依赖..."
apt-get update -y >/dev/null
apt-get install -y git build-essential libssl-dev zlib1g-dev curl ca-certificates openssl xxd python3 >/dev/null

echo "[2/4] 拉取官方源码..."
rm -rf "$WORKDIR_C"
git clone https://github.com/TelegramMessenger/MTProxy.git "$WORKDIR_C" >/dev/null 2>&1

echo "[3/4] 应用高 PID 崩溃补丁..."
python3 - <<'PY'
from pathlib import Path
p = Path('/opt/MTProxy/common/pid.c')
s = p.read_text()
old = " if (!PID.pid) {\n int p = getpid ();\n assert (!(p & 0xffff0000));\n PID.pid = p;\n }\n"
new = " if (!PID.pid) {\n int p = getpid ();\n /* Modern Linux may use pid > 65535; keep lower 16 bits */\n PID.pid = (unsigned short)(p & 0xffff);\n }\n"
if old in s:
p.write_text(s.replace(old, new, 1))
PY

# ARM 架构自动打补丁
ARCH="$(uname -m)"
if [[ "$ARCH" == "aarch64" ]]; then
echo "[3.5/4] 检测到 ARM 架构，修补汇编指令..."
sed -i 's/-mpclmul -march=core2 -mfpmath=sse -mssse3//g' "$WORKDIR_C/Makefile"
sed -i 's/objs\/crypto\/aesni256.o//g' "$WORKDIR_C/Makefile"
sed -i 's/objs\/common\/crc32c.o//g' "$WORKDIR_C/Makefile"

python3 - <<'PY_ARM'
from pathlib import Path
import re
p1 = Path('/opt/MTProxy/common/precise-time.h')
s1 = p1.read_text()
s1 = re.sub(r'asm volatile \("rdtsc" : "=a" \(lo\), "=d" \(hi\)\);', r'asm volatile ("mrs %0, cntvct_el0" : "=r" (lo));\n hi = 0;', s1)
p1.write_text(s1)

p2 = Path('/opt/MTProxy/common/server-functions.h')
s2 = p2.read_text()
s2 = re.sub(r'asm volatile \("mfence"\);', r'asm volatile ("dmb ish");', s2)
p2.write_text(s2)

p3 = Path('/opt/MTProxy/net/net-events.c')
s3 = p3.read_text()
s3 = s3.replace('#include <sys/io.h>', '/* #include <sys/io.h> not for ARM */')
p3.write_text(s3)
PY_ARM
fi

echo "[4/4] 开始编译 C 版本内核..."
cd "$WORKDIR_C"
make >/dev/null 2>&1
if [[ ! -f "$WORKDIR_C/objs/bin/mtproto-proxy" ]]; then
echo "❌ C版本编译失败，请检查环境！" >&2
exit 1
fi
curl -sSL "https://core.telegram.org/getProxySecret" -o proxy-secret
curl -sSL "https://core.telegram.org/getProxyConfig" -o proxy-multi.conf
}

# ----------------------------------------------------
# 菜单 1：安装 Go 语言版 (mtg)
# ----------------------------------------------------
function install_go() {
cleanup_running_services
echo "=== 安装 Go 语言版 (mtg) ==="
read -p "请输入端口 [默认 33380]: " PORT; PORT=${PORT:-33380}
read -p "请输入 Fake-TLS 域名 [默认 update.microsoft.com, 留空使用默认]: " TLS_DOMAIN; TLS_DOMAIN=${TLS_DOMAIN:-update.microsoft.com}

echo "[1/4] 安装环境与拉取源码..."
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates git openssl xxd tar >/dev/null

ARCH="$(uname -m)"
case "$ARCH" in
aarch64) GOARCH="arm64" ;;
x86_64) GOARCH="amd64" ;;
*) echo "不支持架构: $ARCH"; exit 1 ;;
esac
curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
export PATH=/usr/local/go/bin:$PATH

rm -rf "$WORKDIR_GO"
git clone https://github.com/9seconds/mtg.git "$WORKDIR_GO" >/dev/null 2>&1
cd "$WORKDIR_GO"
echo "[2/4] 编译 mtg..."
/usr/local/go/bin/go build -trimpath -ldflags="-s -w" -o /usr/local/bin/mtg .

echo "[3/4] 生成全新密钥..."
RAND_HEX="$(openssl rand -hex 16)"
DOMAIN_HEX="$(printf '%s' "$TLS_DOMAIN" | xxd -p -c 256 | tr -d '\n')"
SECRET_HEX="ee${RAND_HEX}${DOMAIN_HEX}"
SECRET_RAW="$(printf '%s' "$SECRET_HEX" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=')"

echo "$SECRET_HEX" > "$SECRET_DIR/mtg.secret"

echo "[4/4] 配置并启动服务..."
cat > "$SERVICE_GO" <<EOS
[Unit]
Description=mtg MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg simple-run 0.0.0.0:$PORT $SECRET_RAW
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now mtg >/dev/null 2>&1
sleep 1

IP="$(curl -4fsSL ifconfig.me 2>/dev/null || echo YOUR_IP)"
LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET_HEX}"
echo -e "\n✅ 安装完成 (Go版 mtg)\n端口: $PORT\n域名: $TLS_DOMAIN\n链接: $LINK\n"
read -p "按回车键返回主菜单..."
}

# ----------------------------------------------------
# 菜单 2：安装 官方 C 语言版 (带 TLS)
# ----------------------------------------------------
function install_c_tls() {
cleanup_running_services
echo "=== 安装官方 C 版 (加 TLS) ==="
read -p "请输入端口 [默认 33380]: " PORT; PORT=${PORT:-33380}
read -p "请输入 Fake-TLS 域名 [默认 www.cloudflare.com, 留空使用默认]: " TLS_DOMAIN; TLS_DOMAIN=${TLS_DOMAIN:-www.cloudflare.com}

build_c_mtproxy

echo "生成全新密钥..."
SECRET="$(openssl rand -hex 16)"
echo "$SECRET" > "$SECRET_DIR/mtproxy.secret"
DOMAIN_HEX="$(printf '%s' "$TLS_DOMAIN" | xxd -p -c 256 | tr -d '\n')"
SHARE_SECRET="ee${SECRET}${DOMAIN_HEX}"

cat > "$SERVICE_C" <<EOS
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
ExecStart=$WORKDIR_C/objs/bin/mtproto-proxy -u nobody -p 8888 -H $PORT -S $SECRET --aes-pwd $WORKDIR_C/proxy-secret $WORKDIR_C/proxy-multi.conf -D $TLS_DOMAIN
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now mtproxy >/dev/null 2>&1
sleep 1

IP="$(curl -4fsSL ifconfig.me 2>/dev/null || echo YOUR_IP)"
LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SHARE_SECRET}"
echo -e "\n✅ 安装完成 (C版 + TLS)\n端口: $PORT\n域名: $TLS_DOMAIN\n链接: $LINK\n"
read -p "按回车键返回主菜单..."
}

# ----------------------------------------------------
# 菜单 3：安装 官方 C 语言版 (原生无 TLS)
# ----------------------------------------------------
function install_c_plain() {
cleanup_running_services
echo "=== 安装官方 C 版 (无 TLS) ==="
echo "⚠️ 警告：此模式极易被 GFW 秒封！"
read -p "请输入端口 [默认 33380]: " PORT; PORT=${PORT:-33380}

build_c_mtproxy

echo "生成全新密钥..."
SECRET="$(openssl rand -hex 16)"
echo "$SECRET" > "$SECRET_DIR/mtproxy.secret"
SHARE_SECRET="dd${SECRET}"

cat > "$SERVICE_C" <<EOS
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
ExecStart=$WORKDIR_C/objs/bin/mtproto-proxy -u nobody -p 8888 -H $PORT -S $SECRET --aes-pwd $WORKDIR_C/proxy-secret $WORKDIR_C/proxy-multi.conf
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now mtproxy >/dev/null 2>&1
sleep 1

IP="$(curl -4fsSL ifconfig.me 2>/dev/null || echo YOUR_IP)"
LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SHARE_SECRET}"
echo -e "\n✅ 安装完成 (C版原生)\n端口: $PORT\n链接: $LINK\n"
read -p "按回车键返回主菜单..."
}

# ----------------------------------------------------
# 菜单 4：彻底卸载
# ----------------------------------------------------
function uninstall_all() {
echo "=== 彻底卸载代理 ==="
read -p "确定要彻底清理机器上的所有代理和源码吗？(y/n) [n]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then return; fi

cleanup_running_services
rm -f "$SERVICE_C" "$SERVICE_GO"
systemctl daemon-reload
systemctl reset-failed

rm -rf "$WORKDIR_C" "$WORKDIR_GO" /usr/local/bin/mtg
echo "✅ 卸载清理完成！(保留了 /root/MTProxy/ 下的旧密钥文件以防万一)"
echo
read -p "按回车键返回主菜单..."
}

# ----------------------------------------------------
# 主菜单逻辑
# ----------------------------------------------------
while true; do
clear
echo "==================================================="
echo " Telegram MTProto 代理终极管理脚本 (All-in-One) "
echo "==================================================="
echo " 1. 安装 Go 语言版 (mtg) [抗封锁强/延迟略高]"
echo " 2. 安装 官方 C 语言版 + TLS [延迟极低/推荐]"
echo " 3. 安装 官方 C 语言版 (无 TLS) [极易被封]"
echo " 4. 彻底卸载代理 (清理所有版本)"
echo " 0. 退出脚本"
echo "==================================================="
read -p "请输入选项 [0-4]: " OPTION

case $OPTION in
1) install_go ;;
2) install_c_tls ;;
3) install_c_plain ;;
4) uninstall_all ;;
0) echo "退出。"; exit 0 ;;
*) echo "无效选项，请重新输入。"; sleep 1 ;;
esac
done
