# Logto on Bun — 生产替换评测报告

测试时间：2026-09-14 ｜ Logto 版本：master `7d54310`（core 1.43.0）｜ 运行时：Node v22.23.2 vs Bun 1.4.2
环境：32 核 / 48GB 容器，PostgreSQL 15（本机），同一构建产物 `packages/core/build/index.js`，`NODE_ENV=production`。

## 一、兼容性结论：✅ 可直接运行

同一份 pnpm 构建产物，仅把启动命令从 `node build/index.js` 换成 `bun build/index.js`，Logto core **零修改启动成功**：

- Core app (`:3001`) 与 Admin app (`:3002`) 均正常监听
- OIDC discovery `/oidc/.well-known/openid-configuration` 返回完整正确的配置
- Experience API 语义正确（无 session 时返回标准 `session.not_found` OIDC 错误）
- Swagger 文档、Admin Console 302 跳转正常
- 压测约 **19 万次请求，0 错误**，日志中无任何 error/unhandled

唯一提示：`oidc-provider` 打印 `Unsupported runtime` 警告（它硬编码校验 Node LTS），仅为警告，不影响功能。

## 二、性能实测数据

| 指标 | Node 22 | Bun 1.4 | 差异 |
|---|---|---|---|
| 冷启动到可服务 | 1581–1583 ms | 1073–1587 ms | 持平 ~ 略快（启动瓶颈在模块初始化而非运行时） |
| 空闲 RSS（fresh, 30s） | 242 MB | 263 MB | Bun 略高 +9% |
| `/api/status` 吞吐 (20并发) | 3,289 req/s | **5,448–5,500 req/s** | **+67%** |
| `/api/status` p50 / p99 | 5.8 / 12.3 ms | **3.5 / 6.5 ms** | 延迟 **-40% / -47%** |
| OIDC discovery 吞吐 | 2,103 req/s | **3,530–3,599 req/s** | **+70%** |
| OIDC discovery p50 / p99 | 9.2 / 15.7 ms | **5.2 / 9.8 ms** | 延迟 **-43% / -38%** |
| 压测后 RSS | 686 MB | **460–490 MB** | **-29% ~ -33%** |

## 三、结论与建议

**提升可观，值得替换。** 核心收益：

1. **吞吐 +67~70%，p99 延迟近乎减半** —— 对认证服务（高并发 token/jwks/discovery 请求）价值直接。
2. **高负载下内存 -30%**（686MB→470MB 量级）—— Bun 的 GC 压力明显更小；容器内存限额可下调，密度提升。
3. 空闲内存两者相当（±10%），启动时间相当。

**风险提示（生产前须知）：**

- `oidc-provider` 官方仅声明支持 Node LTS。虽实测功能正常，但属于"非官方支持运行时"，极端边缘情况（如特定 crypto/subtle 行为、worker_threads 细节）需自行兜底。Logto 的密码散列走 tinypool worker（argon2i），建议生产灰度时重点验证登录/注册全链路。
- Bun 对 Node API 的兼容已非常成熟（1.4.x），但 Logto 依赖链很长（koa / slonik / samlify / node-forge / aws-sdk 等），本次验证了核心服务与 OIDC 端点，**未覆盖**：SAML、社交连接器回调、MFA/WebAuthn、邮件/SMS 发送。建议灰度期保留 Node 镜像回滚方案。
- 本测试使用同一构建产物仅替换运行时；镜像构建仍用 Node 工具链（pnpm/tsup/vite 构建期在 Bun 下未验证，也无必要）。

## 四、交付物

- `Dockerfile.bun` —— 基于官方 Dockerfile 修改，运行阶段换成 `oven/bun:1-alpine`
- `.github/workflows/build-bun-image.yml` —— 监听 logto 官方 release，自动构建并推送 Bun 版镜像
- 见 `pipeline/` 目录（可独立作为仓库 `logto-bun` 推送 GitHub）
