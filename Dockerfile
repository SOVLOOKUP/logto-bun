# syntax=docker/dockerfile:1.7

# Logto on Bun —— 与官方镜像相同的构建流程，仅运行阶段换成 Bun。
# 构建参数 LOGTO_VERSION 为上游 tag（如 v1.43.0），由 GitHub Actions 自动传入。

###### [STAGE] Build (与官方一致：Node + pnpm) ######
FROM node:22-alpine AS builder
WORKDIR /etc/logto
ENV CI=true
ENV PUPPETEER_SKIP_DOWNLOAD=true

RUN npm add --location=global pnpm@^10.0.0
RUN apk add --no-cache python3 make g++ rsync git

ARG logto_version
ENV LOGTO_VERSION=${logto_version}
RUN git clone --depth 1 --branch ${LOGTO_VERSION} https://github.com/logto-io/logto.git /tmp/logto-src \
  && cp -a /tmp/logto-src/. /etc/logto/ \
  && rm -rf /tmp/logto-src

### Install dependencies and build ###
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store pnpm i

ARG dev_features_enabled
ENV DEV_FEATURES_ENABLED=${dev_features_enabled}
ARG applicationinsights_connection_string
ENV APPLICATIONINSIGHTS_CONNECTION_STRING=${applicationinsights_connection_string}
ARG logto_oss_survey_endpoint=
ENV LOGTO_OSS_SURVEY_ENDPOINT=${logto_oss_survey_endpoint}

RUN pnpm -r build

### Add official connectors ###
ARG additional_connector_args
ENV ADDITIONAL_CONNECTOR_ARGS=${additional_connector_args}
RUN pnpm cli connector link $ADDITIONAL_CONNECTOR_ARGS -p .

### Prune dependencies for production ###
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
  rm -rf node_modules packages/**/node_modules && NODE_ENV=production pnpm i

### Clean up ###
RUN rm -rf .scripts pnpm-*.yaml packages/cloud

###### [STAGE] Seal (运行阶段：Bun) ######
FROM oven/bun:1-alpine AS app
WORKDIR /etc/logto
ARG logto_oss_survey_endpoint=
ARG private_key_rotation_grace_period=0
ENV LOGTO_OSS_SURVEY_ENDPOINT=${logto_oss_survey_endpoint}
ENV PRIVATE_KEY_ROTATION_GRACE_PERIOD=${private_key_rotation_grace_period}
ENV NODE_ENV=production

COPY --from=builder /etc/logto .
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY npm /usr/local/bin/npm
COPY scripts/s3-from-env.ts /etc/logto/scripts/s3-from-env.ts
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/npm \
  && mkdir -p /etc/logto/packages/cli/alteration-scripts \
  && chmod g+w /etc/logto/packages/cli/alteration-scripts

# 启动时自动执行数据库 seed + alteration deploy（可用 AUTO_MIGRATE=false 关闭）
ENV AUTO_MIGRATE=true

EXPOSE 3001
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["start"]
