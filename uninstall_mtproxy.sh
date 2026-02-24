#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

echo "[1/5] 停止并禁用服务..."
systemctl stop mtproxy 2>/dev/null || true
systemctl disable mtproxy 2>/dev/null || true

echo "[2/5] 删除 systemd 服务文件..."
rm -f /etc/systemd/system/mtproxy.service
systemctl daemon-reload
systemctl reset-failed

echo "[3/5] 删除程序与日志..."
rm -rf /opt/MTProxy
rm -f /var/log/mtproxy.log

echo "[4/5] 可选关闭常见端口放行(ufw)..."
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 443/tcp 2>/dev/null || true
  ufw delete allow 8443/tcp 2>/dev/null || true
fi

echo "[5/5] 卸载完成。"
echo "如需连 secret 一起删：rm -f /root/MTProxy/mtproxy.secret"
