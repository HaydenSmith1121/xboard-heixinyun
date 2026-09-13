#!/usr/bin/env bash
#
# 黑心云 · Xboard 一键部署脚本
#
# 在仓库根目录执行：  bash install.sh
#
# 可用环境变量覆盖：
#   ADMIN_ACCOUNT   管理员邮箱（默认 admin@haoyongjichang.top）
#   HOST_PORT       宿主端口（默认 7001）
#
set -euo pipefail

ADMIN_ACCOUNT="${ADMIN_ACCOUNT:-admin@haoyongjichang.top}"
HOST_PORT="${HOST_PORT:-7001}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m[停止] %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")"

step "1/7 前置检查"

command -v docker >/dev/null 2>&1 || die "本机未安装 Docker。

    装之前务必先备份防火墙规则（Docker 会改 iptables/nftables）：
      mkdir -p /root/fw-backup
      iptables-save > /root/fw-backup/iptables-before-docker.txt
      nft list ruleset > /root/fw-backup/nftables-before-docker.txt 2>/dev/null

    安装 Docker 的步骤见 DEPLOY.md 第 2 节，装好后重新执行本脚本。"

docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用（docker compose version 失败）。"
docker info >/dev/null 2>&1 || die "连不上 Docker 守护进程。确认服务已启动，且当前用户在 docker 组内（新加组后要重新登录 shell）。"

ok "Docker : $(docker --version)"
ok "Compose: $(docker compose version --short 2>/dev/null || echo unknown)"

step "2/7 端口与资源检查"

if ss -lnt 2>/dev/null | grep -qE "[:.]${HOST_PORT}[[:space:]]"; then
  warn "端口 ${HOST_PORT} 已被占用："
  ss -lntp 2>/dev/null | grep -E "[:.]${HOST_PORT}[[:space:]]" || true
  die "换一个端口重跑，例如：HOST_PORT=17001 bash install.sh
    （同时要把 compose.yaml 里的 ports 改成 \"127.0.0.1:17001:7001\"）"
fi
ok "端口 ${HOST_PORT} 空闲"

AVAIL_KB=$(df -Pk . | awk 'NR==2 {print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
ok "可用磁盘 ${AVAIL_GB} GB"
if [ "$AVAIL_GB" -lt 5 ]; then
  warn "可用空间不足 5GB，构建镜像可能失败"
fi

if command -v free >/dev/null 2>&1; then
  MEM_MB=$(free -m | awk 'NR==2 {print $7}')
  ok "可用内存 ${MEM_MB} MB"
  if [ "${MEM_MB:-0}" -lt 800 ] 2>/dev/null; then
    warn "可用内存偏低，构建阶段可能被 OOM kill"
  fi
fi

step "3/7 准备挂载点"

if [ -d .env ]; then
  die "./.env 是个目录（上次 compose 误建的）。删除后重跑：rm -rf .env"
fi
if [ ! -f .env ]; then
  touch .env
  ok "已创建空 .env"
fi
mkdir -p .docker/.data storage/logs storage/theme plugins
ok ".env / .docker/.data / storage/ / plugins/ 就绪"

IS_INSTALLED=false
if [ -s .env ] && grep -q '^INSTALLED=true' .env; then
  IS_INSTALLED=true
  warn ".env 显示已安装过，本次跳过初始化，只做构建与启动"
fi

step "4/7 构建镜像（首次约 5-15 分钟，取决于网络）"

export CACHEBUST="$(date +%s)"
ok "CACHEBUST=${CACHEBUST}（让构建重新 clone 仓库代码，而不是复用旧缓存）"
docker compose build
ok "构建完成"

step "5/7 初始化（建表 + 建管理员）"

if [ "$IS_INSTALLED" = "true" ]; then
  ok "已安装过，跳过"
else
  ok "管理员账号：${ADMIN_ACCOUNT}"
  docker compose run --rm \
    -e ENABLE_SQLITE=true \
    -e ENABLE_REDIS=true \
    -e ADMIN_ACCOUNT="${ADMIN_ACCOUNT}" \
    xboard php artisan xboard:install
  printf '\n'
  warn "上面输出的【管理员密码】和【访问路径】只打印这一次，请立刻记录下来！"
fi

step "6/7 启动"

docker compose up -d
sleep 8
docker compose ps

step "7/7 自检"

if ss -lnt 2>/dev/null | grep -qE "(0\.0\.0\.0|\*|\[::\]):${HOST_PORT}[[:space:]]"; then
  warn "危险：${HOST_PORT} 绑在 0.0.0.0，面板暴露到公网了！"
  warn "检查 compose.yaml 的 ports 段后执行：docker compose up -d"
else
  ok "端口绑定正确（仅 127.0.0.1）"
fi

if command -v curl >/dev/null 2>&1; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/" || echo 000)
  ok "http://127.0.0.1:${HOST_PORT}/  ->  ${CODE}"
  if [ "$CODE" = "000" ]; then
    warn "无响应。用这个排查：docker compose logs --tail=80 xboard"
  fi
else
  warn "未安装 curl，跳过 HTTP 自检"
fi

step "完成"

echo "  容器地址  : http://127.0.0.1:${HOST_PORT}/"
echo "  查看日志  : docker compose logs -f xboard"
echo "  重启      : docker compose restart"
echo "  停止      : docker compose down"
echo "  彻底清空  : docker compose down -v && rm -f .docker/.data/database.sqlite"
echo
echo "  注意：它只监听本地，公网访问不到。从你自己的电脑连，先建 SSH 隧道："
echo "    ssh -N -L ${HOST_PORT}:127.0.0.1:${HOST_PORT} root@<服务器IP>"
echo "  然后浏览器打开  http://127.0.0.1:${HOST_PORT}/<安装时打印的访问路径>"
echo
