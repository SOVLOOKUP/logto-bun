#!/bin/sh
# Logto on Bun entrypoint
#
# 用法（与官方镜像兼容 + 全自动数据库升级）：
#   docker run <image>                              → 自动迁移(可关) + 启动 core
#   docker run <image> start                        → 同上
#   docker run <image> migrate                      → 只做 seed + alteration deploy 后退出
#   docker run <image> cli db alteration deploy latest   → 直接调用 Logto CLI
#   docker run <image> sh                           → 进入容器
#
# 环境变量：
#   AUTO_MIGRATE=true|false   默认 true：启动前自动执行 `db seed --swe` + `db alteration deploy latest`
#                             （seed --swe = 表已存在则跳过，alteration 为增量部署，均幂等，可安全反复重启）
#   DB_WAIT_ATTEMPTS=30       数据库不可用时的重试次数（compose 下 DB 容器可能起得慢）
#   DB_WAIT_INTERVAL=2        重试间隔秒数
set -e

cd /etc/logto

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    false|0|no|off|'') return 1 ;;
    *) return 0 ;;
  esac
}

DB_WAIT_ATTEMPTS="${DB_WAIT_ATTEMPTS:-30}"
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-2}"

# 数据库初始化 + 增量升级（幂等）
run_migrations() {
  attempt=1
  while :; do
    if bun packages/cli/bin/logto.js db seed --swe; then
      break
    fi
    if [ "$attempt" -ge "$DB_WAIT_ATTEMPTS" ]; then
      echo "entrypoint: database unreachable after $DB_WAIT_ATTEMPTS attempts, giving up" >&2
      exit 1
    fi
    echo "entrypoint: database not ready (attempt $attempt/$DB_WAIT_ATTEMPTS), retry in ${DB_WAIT_INTERVAL}s..." >&2
    attempt=$((attempt + 1))
    sleep "$DB_WAIT_INTERVAL"
  done

  echo "entrypoint: deploying database alterations (latest)..."
  bun packages/cli/bin/logto.js db alteration deploy latest
}

# S3 环境变量 → logto_configs（须在迁移之后：首次部署时表才刚建好）
sync_s3_config() {
  if [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY_ID" ] && [ -n "$S3_SECRET_ACCESS_KEY" ] && [ -n "$DB_URL" ]; then
    echo "entrypoint: syncing S3 storage provider config from env..."
    bun scripts/s3-from-env.ts
  fi
}

case "$1" in
  start|"")
    if is_truthy "${AUTO_MIGRATE:-true}"; then
      run_migrations
    fi
    sync_s3_config
    # 官方 start 语义为 `cd packages/core && npm start`：
    # core 内部用 pkg-dir 按 cwd 解析 tinypool worker（argon2i）等路径，必须在 packages/core 下启动
    cd packages/core
    exec bun build/index.js
    ;;
  migrate|db-migrate)
    run_migrations
    sync_s3_config
    echo "entrypoint: migrations done"
    ;;
  cli|logto)
    shift
    exec bun packages/cli/bin/logto.js "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
