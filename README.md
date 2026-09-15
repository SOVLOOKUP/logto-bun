# logto-bun

基于 **Bun** 运行的 [Logto](https://github.com/logto-io/logto) Docker 镜像，自动跟随上游 release 构建发布。

## 为什么

实测（Logto core 1.43.0，Node 22 vs Bun 1.4，同一构建产物，详见仓库 `EVALUATION.md`）：

| 指标 | Node 22 | Bun 1.4 | 提升 |
|---|---|---|---|
| API 吞吐 | 3,289 req/s | 5,448 req/s | **+67%** |
| OIDC discovery 吞吐 | 2,103 req/s | 3,530 req/s | **+70%** |
| p99 延迟 | 12–16 ms | 6–10 ms | **≈ -40%** |
| 压测后 RSS | 686 MB | 460 MB | **-30%** |

## 使用

与官方镜像完全兼容，仅替换镜像名：

```bash
docker run -e DB_URL=postgresql://user:pass@host:5432/logto \
  -p 3001:3001 -p 3002:3002 \
  ghcr.io/<owner>/logto-bun:latest
```

## 全自动数据库初始化与升级（内嵌启动流程）

官方/1Panel 的写法通常是在 `entrypoint` 里手工串：

```sh
npm run cli db seed -- --swe && npm run alteration deploy latest && npm start
```

本镜像**已把这段逻辑内嵌进启动流程**，只要给 `DB_URL` 就用：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AUTO_MIGRATE` | `true` | 启动前自动执行 `db seed --swe` + `db alteration deploy latest`，然后用同一进程启动 core |
| `DB_WAIT_ATTEMPTS` | `30` | 数据库不可用时的重试次数（compose 下 DB 起得慢也不会崩） |
| `DB_WAIT_INTERVAL` | `2` | 重试间隔（秒） |

要点：

- **幂等**：`seed --swe` 在 `logto_configs` 表已存在时直接跳过（"Seeding skipped"），`alteration deploy latest` 只部署未执行的增量，因此每次重启都执行是安全的。
- **首次部署自动建库**：`db seed` 会按需创建数据库并建表，全新库直接启动即可。
- 想手动控制（如 K8s 里用 initContainer）时设 `AUTO_MIGRATE=false`，再用下面的命令独立迁移。
- 额外提供 `migrate` 子命令：`docker run --rm -e DB_URL=... <image> migrate`（只迁移后退出）。

> 说明：数据库操作**无法在镜像构建阶段完成**（构建时不存在目标数据库），所以「全自动」的正确落点就是启动流程，这也是官方 Compose/1Panel 模板的做法。

### 兼容 1Panel / 官方写法的 `npm` 垫片

本镜像不含真正的 npm（保持 Bun 运行时轻量）。为了让**沿用官方写法的编排文件零改动可用**，镜像内置了一个 `npm` 兼容垫片，只翻译官方 Logto 的几种调用：

| 调用 | 实际执行 |
|---|---|
| `npm start` / `npm run start` | 启动 core（含自动迁移） |
| `npm run cli <args...>` | `bun packages/cli/bin/logto.js <args...>`（自动去掉 `--`） |
| `npm run alteration <args...>` | `bun packages/cli/bin/logto.js db alt <args...>` |
| `npm run migrate` | 仅执行迁移 |

因此下面这份 1Panel compose 只需把 `image:` 换成 `ghcr.io/sovlookup/logto-bun:<tag>`，其余一字不改：

```yaml
services:
  logto:
    image: ghcr.io/sovlookup/logto-bun:latest     # ← 只改这里
    entrypoint:
      - sh
      - -c
      - npm run cli db seed -- --swe && npm run alteration deploy latest && npm start
    environment:
      - TRUST_PROXY_HEADER=1
      - DB_URL=postgres://user:pass@postgres:5432/logto
      - ENDPOINT=${LOGTO_ENDPOINT_URL}
      - ADMIN_ENDPOINT=${LOGTO_ADMIN_ENDPOINT_URL}
    ports:
      - 3002:3002
      - 3001:3001
    restart: always
```

其它 `npm` 调用（如 `npm install`）会明确报错，不会静默做出意外行为。更推荐的做法是**删掉 `entrypoint` 覆盖**，直接用镜像默认行为（等价效果，且能享受 DB 等待重试）。

## 环境变量配置 S3 与 Valkey 缓存

### Valkey 缓存（Redis 协议兼容，Logto 原生支持）

设置 `REDIS_URL` 即可，Logto 会把签名密钥轮换状态等缓存放入 Valkey：

```bash
-e REDIS_URL=redis://valkey:6379
# 集群模式：redis://host:6379?cluster=true&host=other-host:6379
```

### S3 存储（本镜像扩展能力）

Logto 官方把头像等上传文件的存储提供方存在数据库里（Admin Console 配置）。本镜像内置
`scripts/s3-from-env.ts` 引导脚本：**设置 S3 环境变量后，容器每次启动会幂等 upsert 到
`logto_configs` 表（tenant `default` + `admin`），环境变量即唯一事实来源**（在数据库迁移之后执行，首次部署也能正确写入）。

| 变量 | 必填 | 说明 |
|---|---|---|
| `S3_BUCKET` | ✅ | 存储桶名 |
| `S3_ACCESS_KEY_ID` | ✅ | Access Key |
| `S3_SECRET_ACCESS_KEY` | ✅ | Secret Key |
| `S3_ENDPOINT` | | MinIO/R2/OSS 等自定义端点 |
| `S3_REGION` | | 区域 |
| `S3_FORCE_PATH_STYLE` | | `true` 时启用 path-style（MinIO 必开） |
| `S3_PUBLIC_URL` | | 生成对外访问 URL |
| `S3_CONFIG_KEY` | | 默认 `storageProvider`；也可设 `experienceBlobsProvider` / `experienceZipsProvider` |
| `S3_TENANTS` | | 默认 `default,admin` |

最小示例（MinIO）：

```bash
docker run -e DB_URL=... \
  -e S3_BUCKET=logto-attachments \
  -e S3_ACCESS_KEY_ID=minioadmin -e S3_SECRET_ACCESS_KEY=minioadmin \
  -e S3_ENDPOINT=http://minio:9000 -e S3_FORCE_PATH_STYLE=true \
  ghcr.io/<owner>/logto-bun:latest
```

完整全栈示例见 `docker-compose.yml`（Logto + Postgres + Valkey + MinIO）。

## 工作原理

- `Dockerfile`：构建阶段与官方完全一致（node:22-alpine + pnpm 构建），运行阶段换成 `oven/bun:1-alpine`。
- `docker-entrypoint.sh`：启动流程 = （`AUTO_MIGRATE` 时）等 DB + `db seed --swe` + `db alteration deploy latest` → S3 环境变量同步 → 以 `packages/core` 为工作目录启动 core（与官方 `npm start` 语义一致，tinypool 的 argon2i worker 路径依赖 cwd）。
- `npm`：官方调用写法兼容垫片（非真实 npm）。
- `scripts/s3-from-env.ts`：用 Bun 内置 Postgres 客户端（零依赖）把 S3 环境变量写入 `logto_configs`。
- `.github/workflows/track-upstream.yml`：每小时检查 `logto-io/logto` 最新 release，发现新版本即记录到 `.upstream-version` 并触发构建。
- `.github/workflows/build.yml`：多架构（amd64/arm64）构建并推送 ghcr.io，tag 与上游版本一致（`v1.43.0` / `1.43.0` / `latest`），发布前跑生产级冒烟：全新库自动迁移 + 启动探活 + 重启幂等 + 1Panel 垫片路径。

## 部署到自己的账号

1. Fork / 推送本仓库到你的 GitHub 账号。
2. （可选）要推 Docker Hub：在仓库 secrets 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，并取消 `build.yml` 中对应注释。
3. 手动跑一次 `Track upstream Logto releases`（Actions 页 workflow_dispatch），或等调度自动触发。

## 风险提示

`oidc-provider` 官方仅声明支持 Node LTS（启动时有一条无害警告）。Bun 运行核心/OIDC/Admin 实测无异常，但 SAML、WebAuthn、各连接器回调等边缘链路建议灰度验证，并保留官方 Node 镜像作为回滚。
