#!/usr/bin/env bun
/**
 * S3-from-env bootstrap —— 在 Logto 启动前，把 S3_* 环境变量写入 logto_configs 表。
 *
 * Logto 的存储提供方（头像等上传文件）官方设计为存放在数据库 logto_configs（key=storageProvider），
 * 由 Admin Console 配置；本脚本让镜像可以用纯环境变量配置（12-factor 风格），幂等 upsert，
 * 每次启动都会把环境变量同步进库（env 为唯一事实来源）。
 *
 * 环境变量：
 *   S3_BUCKET             必填
 *   S3_ACCESS_KEY_ID      必填
 *   S3_SECRET_ACCESS_KEY  必填
 *   S3_ENDPOINT           可选（MinIO/R2 等，不填则用 AWS 默认解析）
 *   S3_REGION             可选
 *   S3_FORCE_PATH_STYLE   可选，"true"/"1" 时启用 path-style（MinIO 需要）
 *   S3_PUBLIC_URL         可选，生成对外访问 URL
 *   S3_CONFIG_KEY         可选，默认 "storageProvider"（也可设 experienceBlobsProvider 等）
 *   S3_TENANTS            可选，默认 "default,admin"
 *
 * 依赖：Bun 内置 Postgres 客户端（Bun.sql），零外部依赖。
 */

const required = ['S3_BUCKET', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY'];
const missing = required.filter((k) => !process.env[k]);
if (missing.length > 0) {
  console.error(`s3-bootstrap: missing env vars: ${missing.join(', ')}`);
  process.exit(1);
}

const dsn = process.env.DB_URL;
if (!dsn) {
  console.error('s3-bootstrap: DB_URL is not set');
  process.exit(1);
}

const value = {
  provider: 'S3Storage',
  bucket: process.env.S3_BUCKET,
  accessKeyId: process.env.S3_ACCESS_KEY_ID,
  accessSecretKey: process.env.S3_SECRET_ACCESS_KEY,
  ...(process.env.S3_ENDPOINT ? { endpoint: process.env.S3_ENDPOINT } : {}),
  ...(process.env.S3_REGION ? { region: process.env.S3_REGION } : {}),
  ...(process.env.S3_FORCE_PATH_STYLE && ['1', 'true'].includes(process.env.S3_FORCE_PATH_STYLE.toLowerCase())
    ? { forcePathStyle: true }
    : {}),
  ...(process.env.S3_PUBLIC_URL ? { publicUrl: process.env.S3_PUBLIC_URL } : {}),
};

const configKey = process.env.S3_CONFIG_KEY || 'storageProvider';
const tenants = (process.env.S3_TENANTS || 'default,admin')
  .split(',')
  .map((t) => t.trim())
  .filter(Boolean);

// Bun 内置 Postgres：new SQL(url)
// 注：Bun.sql 对 jsonb 的参数绑定会把字符串标量二次编码，
// 因此用 base64 + 服务端 convert_from(decode(...))::jsonb 保证写入的是 JSON 对象。
import { SQL } from 'bun';
const sql = new SQL(dsn);

try {
  const payload = Buffer.from(JSON.stringify(value)).toString('base64');
  for (const tenantId of tenants) {
    const result = await sql`
      INSERT INTO logto_configs (tenant_id, key, value)
      SELECT ${tenantId}, ${configKey}, convert_from(decode(${payload}, 'base64'), 'UTF8')::jsonb
      WHERE EXISTS (SELECT 1 FROM tenants WHERE id = ${tenantId})
      ON CONFLICT (tenant_id, key) DO UPDATE
      SET value = EXCLUDED.value
      RETURNING tenant_id
    `;
    if (result.length > 0) {
      console.log(`s3-bootstrap: upserted ${configKey} for tenant ${tenantId}`);
    } else {
      console.warn(`s3-bootstrap: tenant ${tenantId} not found, skipped`);
    }
  }
} finally {
  await sql.close();
}
