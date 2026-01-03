# Базовые образы для каждой архитектуры
FROM --platform=linux/amd64 alpine AS build-linux-amd64
FROM --platform=linux/arm/v7 alpine AS build-linux-armv7
FROM --platform=linux/arm64 alpine AS build-linux-arm64
FROM --platform=linux/arm/v5 debian:trixie-slim AS build-linux-armv5

# Переименовываем базовый образ в зависимости от TARGETPLATFORM
FROM build-${TARGETOS}-${TARGETARCH}${TARGETVARIANT} AS build

ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETOS
ARG TARGETVARIANT

WORKDIR /tmp

RUN echo "Building for platform: $TARGETARCH" && \
    case "$TARGETPLATFORM" in \
        "linux/arm/v5") \
            apt update && apt install -y curl jq tar ca-certificates ;; \
        linux/amd64 | linux/arm64 | linux/arm/v7) \
            apk add --no-cache curl jq tar ca-certificates ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac

# Get latest release from GitHub, download the files and save them with new names
RUN case "$TARGETPLATFORM" in \
        linux/arm/v5)     ASSET_NAME="mihomo-linux-armv5-v.*.gz";; \
        linux/arm/v7)     ASSET_NAME="mihomo-linux-armv7-v.*.gz";; \
        linux/arm64)      ASSET_NAME="mihomo-linux-arm64-v.*.gz";; \
        linux/amd64)      ASSET_NAME="mihomo-linux-amd64-compatible-v.*.gz";; \
        *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    RELEASE_URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | \
      jq -r --arg regex "$ASSET_NAME" \
      '.assets[] | select(.name | test($regex)) | .browser_download_url') && \
    curl -L "$RELEASE_URL" -o mihomo.gz

#make work structure
RUN gunzip -c ./*.gz > "mihomo" && \
    mkdir -p build/usr/bin && \
    mkdir -p build/etc/mihomo/template && \
    mv mihomo build/usr/bin/mihomo && \
    chmod -R +x .

COPY entrypoint.sh build/

# Базовые образы для каждой архитектуры
FROM --platform=linux/amd64 alpine:latest AS linux-amd64
FROM --platform=linux/arm/v7 alpine:latest AS linux-armv7
FROM --platform=linux/arm64 alpine:latest AS linux-arm64
FROM --platform=linux/arm/v5 debian:trixie-slim AS linux-armv5

# FINAL IMAGE
FROM ${TARGETOS}-${TARGETARCH}${TARGETVARIANT}
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETOS
ARG TARGETVARIANT

COPY --from=build /tmp/build/ /

ENV DISABLE_NFTABLES=1
ENV CONFIG="default_config.yaml"
ENV WORKDIR="/etc/mihomo"
ENV HEALTH_CHECK_URL="https://www.gstatic.com/generate_204"
ENV MIXED_PORT=1080
ENV UI_PORT=9090
ENV EXTERNAL_CONTROLLER_ADDRESS="0.0.0.0"
ENV TUN_STACK="system"
ENV TUN_INET4_ADDRESS="198.19.0.1/30"
ENV TUN_AUTO_REDIRECT="true"
ENV TUN_AUTO_DETECT_INTERFACE="true"
ENV TUN_AUTO_ROUTE="true"
ENV EXTERNAL_UI_PATH="ui"
ENV DNS_ENABLE="true"
ENV DNS_USE_SYSTEM_HOSTS="true"
ENV IPV6="true"

RUN case "$TARGETPLATFORM" in \
        linux/arm/v7) \
            apk add --no-cache iptables iptables-legacy && \
            # IPv4
            rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
            ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
            ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
            ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
            # IPv6
            rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore && \
            ln -s /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
            ln -s /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
            ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore && \
            rm -vrf /var/log/apk.log ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" ;; \
    esac

RUN case "$TARGETPLATFORM" in \
        linux/arm64 | linux/amd64) \
            apk add --no-cache nftables && \
             rm -vrf /var/log/apk.log ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" ;; \
    esac

RUN case "$TARGETPLATFORM" in \
        "linux/arm/v5") \
            apt update && \
            apt install -y bash iptables tzdata gettext iputils-ping traceroute procps ca-certificates tini && \
            apt autoremove -y && \
            apt clean -y && \
            rm -rf /var/cache/apt/archives /var/lib/apt/lists/* && \
            sed -i '1s|^#!/bin/sh|#!/bin/bash|' /entrypoint.sh;; \
        linux/arm/v7) \
            apk add --no-cache tzdata envsubst ca-certificates tini && \
            rm -vrf /var/cache/apk/* ;; \
        linux/amd64 | linux/arm64) \
            apk add --no-cache tzdata envsubst ca-certificates tini && \
            rm -vrf /var/cache/apk/* ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]