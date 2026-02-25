#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

function install_mtg() {
    echo "=== 安装/重新配置 MTG 代理 ==="
    read -p "请输入端口 [默认 33380]: " PORT
    PORT=${PORT:-33380}
    
    read -p "请输入 Fake-TLS 伪装域名 [默认 update.microsoft.com, 留空使用默认域名]: " TLS_DOMAIN
    TLS_DOMAIN=${TLS_DOMAIN:-update.microsoft.com}

    WORKDIR="/root/MTProxy"
    SRC_DIR="/opt/mtg-src"
    BIN="/usr/local/bin/mtg"
    SERVICE="/etc/systemd/system/mtg.service"
    GO_VER="1.24.6"

    mkdir -p "$WORKDIR"

    echo "[1/7] 安装依赖..."
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates git openssl xxd tar >/dev/null

    echo "[2/7] 安装 Go ${GO_VER}..."
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

    echo "[3/7] 拉取并编译 mtg..."
    rm -rf "$SRC_DIR"
    git clone https://github.com/9seconds/mtg.git "$SRC_DIR" >/dev/null 2>&1
    cd "$SRC_DIR"
    /usr/local/go/bin/go build -trimpath -ldflags="-s -w" -o "$BIN" .

    if [[ ! -x "$BIN" ]]; then
      echo "mtg 编译失败" >&2
      exit 1
    fi

    echo "[4/7] 生成代理密钥..."
    RAND_HEX="$(openssl rand -hex 16)"
    if [[ -n "$TLS_DOMAIN" ]]; then
      DOMAIN_HEX="$(printf '%s' "$TLS_DOMAIN" | xxd -p -c 256 | tr -d '\n')"
      SECRET_HEX="ee${RAND_HEX}${DOMAIN_HEX}"
    else
      SECRET_HEX="dd${RAND_HEX}"
    fi

    SECRET_RAW="$(printf '%s' "$SECRET_HEX" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=')"
    echo "$SECRET_RAW" > "$WORKDIR/mtg.secret.raw"
    echo "$SECRET_HEX" > "$WORKDIR/mtg.secret.hex"
    chmod 600 "$WORKDIR/mtg.secret.raw" "$WORKDIR/mtg.secret.hex"

    echo "[5/7] 写入 systemd 服务..."
    cat > "$SERVICE" <<EOS
[Unit]
Description=mtg MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=$BIN simple-run 0.0.0.0:$PORT $SECRET_RAW
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS

    echo "[6/7] 启动服务..."
    systemctl daemon-reload
    systemctl enable --now mtg >/dev/null 2>&1
    sleep 1

    echo "[7/7] 生成导入链接..."
    IP="$(curl -4fsSL ifconfig.me 2>/dev/null || curl -4fsSL ip.sb 2>/dev/null || echo YOUR_SERVER_IP)"
    LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET_HEX}"

    echo
    echo "====== 安装/配置完成 (mtg) ======"
    echo "PORT       : $PORT"
    echo "TLS_DOMAIN : ${TLS_DOMAIN:-<无>}"
    echo "SECRET_HEX : $SECRET_HEX"
    echo "链接       : $LINK"
    echo "================================="
    echo
    read -p "按回车键返回主菜单..."
}

function uninstall_mtg() {
    echo "=== 卸载 MTG 代理 ==="
    read -p "确定要彻底卸载 mtg 吗？(y/n) [默认 n]: " CONFIRM
    CONFIRM=${CONFIRM:-n}
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "已取消卸载。"
        sleep 1
        return
    fi

    echo "[1/4] 停止并禁用 mtg 服务..."
    systemctl stop mtg 2>/dev/null || true
    systemctl disable mtg 2>/dev/null || true

    echo "[2/4] 删除服务与二进制文件..."
    rm -f /etc/systemd/system/mtg.service
    systemctl daemon-reload
    systemctl reset-failed
    rm -f /usr/local/bin/mtg

    echo "[3/4] 清理源码与配置目录..."
    rm -rf /opt/mtg-src
    rm -rf /root/MTProxy

    echo "[4/4] 卸载完成。"
    echo
    read -p "按回车键返回主菜单..."
}

while true; do
    clear
    echo "====================================="
    echo "     MTG Proxy (MTProto) 管理脚本    "
    echo "====================================="
    echo "  1. 安装 / 重新配置 MTG 代理"
    echo "  2. 彻底卸载 MTG 代理"
    echo "  3. 退出脚本"
    echo "====================================="
    read -p "请输入选项 [1-3]: " OPTION

    case $OPTION in
        1) install_mtg ;;
        2) uninstall_mtg ;;
        3) echo "退出。"; exit 0 ;;
        *) echo "无效选项，请重新输入。"; sleep 1 ;;
    esac
done
