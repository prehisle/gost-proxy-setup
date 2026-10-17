#!/usr/bin/env bash
# gost-proxy-setup: 用 Docker Compose + gost 部署带认证的 SOCKS5 代理(固定出口 IP 测试用)
#
# 安装: curl -fsSL https://raw.githubusercontent.com/prehisle/gost-proxy-setup/main/install.sh | bash
# 限制来源 IP: ... | bash -s -- --allow-ip 1.2.3.4
# 卸载: ... | bash -s -- --uninstall
# 选项: --dir DIR        安装目录(默认 /opt/gost)
#       --port PORT      对外端口(默认 1080)
#       --user NAME      用户名(默认 proxy)
#       --allow-ip IP    只允许该 IP 访问端口(通过 DOCKER-USER 链,可重复指定多个 IP)
#       --uninstall      停止并删除容器(保留目录与 .env,需手动删除)
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/prehisle/gost-proxy-setup/main"
INSTALL_DIR="${INSTALL_DIR:-/opt/gost}"
PORT="1080"
PROXY_USER="proxy"
UNINSTALL=0
ALLOW_IPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?--dir 需要参数}"; shift 2 ;;
    --port) PORT="${2:?--port 需要参数}"; shift 2 ;;
    --user) PROXY_USER="${2:?--user 需要参数}"; shift 2 ;;
    --allow-ip) ALLOW_IPS+=("${2:?--allow-ip 需要参数}"); shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) echo "用法: install.sh [--dir DIR] [--port PORT] [--user NAME] [--allow-ip IP ...] [--uninstall]"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "错误: 端口无效: $PORT" >&2; exit 1
fi
if ! [[ "$PROXY_USER" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "错误: 用户名只能包含字母、数字、_ . -" >&2; exit 1
fi
for ip in "${ALLOW_IPS[@]}"; do
  if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "错误: --allow-ip 目前只支持 IPv4 地址: $ip" >&2; exit 1
  fi
done

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# 限制来源 IP:在 DOCKER-USER 链里放行指定 IP,其余丢弃
apply_firewall() {
  command -v iptables >/dev/null 2>&1 || { echo "警告: 未找到 iptables,跳过来源 IP 限制" >&2; return 0; }
  $SUDO iptables -N DOCKER-USER 2>/dev/null || true
  for ip in "${ALLOW_IPS[@]}"; do
    $SUDO iptables -C DOCKER-USER -p tcp -s "$ip" --dport "$PORT" -j ACCEPT 2>/dev/null \
      || $SUDO iptables -I DOCKER-USER -p tcp -s "$ip" --dport "$PORT" -j ACCEPT
  done
  $SUDO iptables -C DOCKER-USER -p tcp --dport "$PORT" -j DROP 2>/dev/null \
    || $SUDO iptables -A DOCKER-USER -p tcp --dport "$PORT" -j DROP
  echo "    已限制端口 $PORT 仅允许: ${ALLOW_IPS[*]}"
  echo "    注意: 此规则重启后可能失效,请用 iptables-persistent 等工具持久化。"
}

if [ "$UNINSTALL" -eq 1 ]; then
  echo "==> 停止 gost 容器"
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    (cd "$INSTALL_DIR" && $SUDO docker compose down) || true
  fi
  echo "==> 完成。目录 $INSTALL_DIR 未删除(含密码文件 .env),确认不再需要后手动删除。"
  exit 0
fi

echo "==> 检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "    未安装,使用官方脚本安装"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.$$.sh
  $SUDO sh /tmp/get-docker.$$.sh
  rm -f /tmp/get-docker.$$.sh
fi
docker compose version >/dev/null 2>&1 || { echo "错误: 需要 docker compose 插件" >&2; exit 1; }
if command -v systemctl >/dev/null 2>&1; then $SUDO systemctl enable --now docker >/dev/null 2>&1 || true; fi

echo "==> 准备目录 $INSTALL_DIR"
$SUDO mkdir -p "$INSTALL_DIR"

ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "    已有 .env,保留原密码"
  # shellcheck disable=SC1090
  PASS=$(grep '^GOST_PASS=' "$ENV_FILE" | cut -d= -f2-)
else
  PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
fi
umask 077
$SUDO tee "$ENV_FILE" >/dev/null <<EOF
GOST_USER=$PROXY_USER
GOST_PASS=$PASS
GOST_PORT=$PORT
EOF
$SUDO chmod 600 "$ENV_FILE"

echo "==> 写入 docker-compose.yml"
$SUDO tee "$INSTALL_DIR/docker-compose.yml" >/dev/null <<'EOF'
services:
  gost:
    image: gogost/gost:latest
    container_name: gost-socks5
    restart: unless-stopped
    ports:
      - "${GOST_PORT}:1080"
    command: -L "socks5://${GOST_USER}:${GOST_PASS}@:1080"
EOF

echo "==> 启动容器"
(cd "$INSTALL_DIR" && $SUDO docker compose up -d)

if [ ${#ALLOW_IPS[@]} -gt 0 ]; then
  echo "==> 设置来源 IP 限制"
  apply_firewall
fi

echo "==> 本机自测"
sleep 3
EXIT_IP=$(curl -s -m 15 --socks5-hostname "$PROXY_USER:$PASS@127.0.0.1:$PORT" https://ifconfig.me || true)
if [ -n "$EXIT_IP" ]; then
  echo "    通过,出口 IP: $EXIT_IP"
else
  echo "    自测失败,请运行: cd $INSTALL_DIR && docker compose logs" >&2
fi

PUBLIC_IP=$(curl -s -m 10 https://ifconfig.me || echo "服务器IP")
echo ""
echo "==> 完成!连接信息:"
echo "    地址: $PUBLIC_IP   端口: $PORT   协议: SOCKS5"
echo "    用户: $PROXY_USER"
echo "    密码: $PASS"
echo "    密码保存在 $ENV_FILE(权限 600)"
echo "    测试: curl --socks5-hostname $PROXY_USER:<密码>@$PUBLIC_IP:$PORT https://ifconfig.me"
echo ""
echo "注意:SOCKS5 不加密,账号密码明文传输。请在云安全组中只放行你自己的 IP。"
