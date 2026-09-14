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

数据库迁移（升级时）：

```bash
docker run --rm -e DB_URL=... ghcr.io/<owner>/logto-bun:latest cli db alteration deploy
```

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
`logto_configs` 表（tenant `default` + `admin`），环境变量即唯一事实来源**。

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

- `Dockerfile`：构建阶段与官方完全一致（node:22-alpine + pnpm 构建），运行阶段换成 `oven/bun:1-alpine`，入口 `bun packages/core/build/index.js`。
- `scripts/s3-from-env.ts`：用 Bun 内置 Postgres 客户端（零依赖）把 S3 环境变量写入 `logto_configs`。
- `.github/workflows/track-upstream.yml`：每小时检查 `logto-io/logto` 最新 release，发现新版本即记录到 `.upstream-version` 并触发构建。
- `.github/workflows/build.yml`：多架构（amd64/arm64）构建并推送 ghcr.io，tag 与上游版本一致（`v1.43.0` / `1.43.0` / `latest`）。

## 部署到自己的账号

1. Fork / 推送本仓库到你的 GitHub 账号。
2. （可选）要推 Docker Hub：在仓库 secrets 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，并取消 `build.yml` 中对应注释。
3. 手动跑一次 `Track upstream Logto releases`（Actions 页 workflow_dispatch），或等调度自动触发。

## 风险提示

`oidc-provider` 官方仅声明支持 Node LTS（启动时有一条无害警告）。Bun 运行核心/OIDC/Admin 实测无异常，但 SAML、WebAuthn、各连接器回调等边缘链路建议灰度验证，并保留官方 Node 镜像作为回滚。
