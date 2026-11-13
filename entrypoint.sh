#!/usr/bin/env bash
set -euo pipefail

mkdir -p /data/d1

# 1. 首次启动自动生成随机密钥并保存到 /data/secrets.env（支持外部 -e 环境变量覆盖）
SECRETS_FILE="/data/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
  cat << EOT > "$SECRETS_FILE"
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
RUNNER_SERVICE_TOKEN=$(openssl rand -hex 32)
CREDENTIAL_KEY=$(openssl rand -base64 32)
EOT
  chmod 600 "$SECRETS_FILE"
  echo "[init] 已自动生成密钥并保存至 $SECRETS_FILE"
fi

SAVED_BETTER_AUTH_SECRET=$(grep '^BETTER_AUTH_SECRET=' "$SECRETS_FILE" | cut -d'=' -f2-)
SAVED_RUNNER_SERVICE_TOKEN=$(grep '^RUNNER_SERVICE_TOKEN=' "$SECRETS_FILE" | cut -d'=' -f2-)
SAVED_CREDENTIAL_KEY=$(grep '^CREDENTIAL_KEY=' "$SECRETS_FILE" | cut -d'=' -f2-)

export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-$SAVED_BETTER_AUTH_SECRET}"
export RUNNER_SERVICE_TOKEN="${RUNNER_SERVICE_TOKEN:-$SAVED_RUNNER_SERVICE_TOKEN}"
export CREDENTIAL_KEY="${CREDENTIAL_KEY:-$SAVED_CREDENTIAL_KEY}"
export SITE_URL="${SITE_URL:-http://127.0.0.1:3000}"
export TASK_CONCURRENCY="${TASK_CONCURRENCY:-4}"
export WEBSITE_URL="http://127.0.0.1:3000"
export RUNNER_URL="http://127.0.0.1:8788"
export EXECUTOR_ENABLED="false"
export DAILY_EXECUTOR="legacy"

# 2. 写入本地 .dev.vars 并自动执行本地 SQLite (模拟 D1) 数据库迁移
cat << EOT > /web/apps/web/.dev.vars
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
RUNNER_SERVICE_TOKEN=${RUNNER_SERVICE_TOKEN}
SITE_URL=${SITE_URL}
RUNNER_URL=http://127.0.0.1:8788
EXECUTOR_ENABLED=false
DAILY_EXECUTOR=legacy
EOT

echo "[init] 正在检查并应用本地 D1 数据库迁移..."
cd /web
pnpm --filter @heybox/web exec wrangler d1 migrations apply heybox-daily --local --persist-to /data/d1

# 3. 启动本地 Runner 服务（监听 127.0.0.1:8788）
echo "[start] 启动本地 Runner 服务..."
cd /app
if [ -f "apps/runner/dist/index.js" ]; then
  node apps/runner/dist/index.js &
elif [ -f "dist/apps/runner/index.js" ]; then
  node dist/apps/runner/index.js &
else
  pnpm --filter @heybox/runner start &
fi
RUNNER_PID=$!

# 4. 启动本地 Web 面板（监听 0.0.0.0:3000）
echo "[start] 启动本地 Web 面板 (SITE_URL=${SITE_URL})..."
cd /web/apps/web
if [ -f "dist/server/wrangler.json" ]; then
  pnpm exec wrangler dev \
    --config dist/server/wrangler.json \
    --local \
    --persist-to /data/d1 \
    --ip 0.0.0.0 \
    --port 3000 \
    --var "SITE_URL:${SITE_URL}" \
    --var "RUNNER_URL:http://127.0.0.1:8788" \
    --var "EXECUTOR_ENABLED:false" \
    --var "DAILY_EXECUTOR:legacy" &
else
  pnpm dev -- --host 0.0.0.0 --port 3000 &
fi
WEB_PID=$!

# 5. 内置定时调度器（替代宿主机 Crontab，每小时第 30 分钟触发每日任务检查）
(
  LAST_TRIGGER_HOUR=""
  while true; do
    CURRENT_MIN=$(date +%M)
    CURRENT_HOUR=$(date +%Y%m%d%H)
    if [ "$CURRENT_MIN" = "30" ] && [ "$LAST_TRIGGER_HOUR" != "$CURRENT_HOUR" ]; then
      if curl -fsS http://127.0.0.1:3000/cdn-cgi/handler/scheduled > /dev/null 2>&1; then
        echo "[cron] $(date '+%F %T') 已触发每小时定时任务检查"
      fi
      LAST_TRIGGER_HOUR="$CURRENT_HOUR"
    fi
    sleep 20
  done
) &
CRON_PID=$!

cleanup() {
  echo "[stop] 正在停止容器内服务..."
  kill "$CRON_PID" "$WEB_PID" "$RUNNER_PID" 2>/dev/null || true
  wait
}
trap cleanup SIGTERM SIGINT

# 进程守护：任一核心服务异常退出则退出容器，交由 Docker 重启策略自动拉起
while true; do
  if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
    echo "[error] Runner 进程已异常退出"
    exit 1
  fi
  if ! kill -0 "$WEB_PID" 2>/dev/null; then
    echo "[error] Web 进程已异常退出"
    exit 1
  fi
  sleep 5
done
