#!/bin/sh
# Logto on Bun entrypoint —— 兼容官方镜像用法：
#   docker run <image>                      → 启动 core（等价官方 CMD ["start"]）
#   docker run <image> cli db alteration deploy ...  → 执行 Logto CLI
#   docker run <image> start                → 显式启动 core
set -e

cd /etc/logto

# S3-from-env：设置 S3_BUCKET 等环境变量时，启动前把存储提供方配置写入数据库（幂等 upsert）
if [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY_ID" ] && [ -n "$S3_SECRET_ACCESS_KEY" ] && [ -n "$DB_URL" ]; then
  echo "S3 env vars detected, syncing storageProvider config to database..."
  bun scripts/s3-from-env.ts
fi

case "$1" in
  start|"")
    # 官方镜像 start 语义为 `cd packages/core && npm start`：
    # core 内部用 pkg-dir 按 cwd 解析 tinypool worker（argon2i）等路径，必须在 packages/core 下启动
    cd packages/core
    exec bun build/index.js
    ;;
  cli|logto)
    shift
    exec bun packages/cli/bin/logto.js "$@"
    ;;
  *)
    # 透传任意命令（如 sh、npm run 之外的操作）
    exec "$@"
    ;;
esac
