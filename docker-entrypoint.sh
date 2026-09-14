#!/bin/sh
# Logto on Bun entrypoint —— 兼容官方镜像用法：
#   docker run <image>                      → 启动 core（等价官方 CMD ["start"]）
#   docker run <image> cli db alteration deploy ...  → 执行 Logto CLI
#   docker run <image> start                → 显式启动 core
set -e

cd /etc/logto

case "$1" in
  start|"")
    exec bun packages/core/build/index.js
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
