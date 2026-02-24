#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-33380}"
WORKDIR="/opt/MTProxy"
SERVICE="/etc/systemd/system/mtproxy.service"
SECRET_FILE="/root/MTProxy/mtproxy.secret"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0 [port]"
  exit 1
fi

echo "[1/9] 安装依赖..."
apt-get update -y
apt-get install -y git build-essential libssl-dev zlib1g-dev curl ca-certificates openssl

echo "[2/9] 拉取源码..."
rm -rf "$WORKDIR"
git clone https://github.com/TelegramMessenger/MTProxy.git "$WORKDIR"

echo "[3/9] 修复高 PID 崩溃补丁..."
python3 - <<'PY'
from pathlib import Path
p = Path('/opt/MTProxy/common/pid.c')
s = p.read_text()
old = "  if (!PID.pid) {\n    int p = getpid ();\n    assert (!(p & 0xffff0000));\n    PID.pid = p;\n  }\n"
new = "  if (!PID.pid) {\n    int p = getpid ();\n    /* Modern Linux may use pid > 65535; keep lower 16 bits for compatibility. */\n    PID.pid = (unsigned short)(p & 0xffff);\n  }\n"
if old in s:
    p.write_text(s.replace(old, new, 1))
    print('patched common/pid.c')
else:
    print('patch block not found, skip')
PY

echo "[4/9] 编译..."
cd "$WORKDIR"
make -j"$(nproc)"

echo "[5/9] 下载 Telegram 官方配置..."
curl -fsSL https://core.telegram.org/getProxySecret -o "$WORKDIR/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "$WORKDIR/proxy-multi.conf"

echo "[6/9] 生成或复用 secret..."
if [[ -s "$SECRET_FILE" ]] && grep -Eq '^[0-9a-f]{32}$' "$SECRET_FILE"; then
  SECRET="$(cat "$SECRET_FILE")"
else
  SECRET="$(openssl rand -hex 16)"
  echo "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

echo "[7/9] 写入 systemd 服务..."
cat > "$SERVICE" <<EOS
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStart=$WORKDIR/objs/bin/mtproto-proxy -u nobody -p 8888 -H $PORT -S $SECRET --aes-pwd $WORKDIR/proxy-secret $WORKDIR/proxy-multi.conf
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS

echo "[8/9] 启动服务..."
systemctl daemon-reload
systemctl enable --now mtproxy
sleep 1
systemctl --no-pager -l status mtproxy

echo "[9/9] 防火墙放行端口(如有 ufw)..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/tcp" || true
fi

IP="$(curl -4fsSL ifconfig.me || curl -4fsSL ip.sb || echo YOUR_SERVER_IP)"
LINK="tg://proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

echo
echo "====== 安装完成 ======"
echo "PORT   : $PORT"
echo "SECRET : $SECRET"
echo "链接   : ${LINK}"
echo "状态   : systemctl status mtproxy --no-pager -l"
echo "日志   : journalctl -u mtproxy -f"
echo "======================"

echo
printf '%s\n' "$LINK"
