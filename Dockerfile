# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM alpine AS prebuild

WORKDIR /src
COPY patches/ /tmp/

ARG MIHOMO_VERSION

# инструменты для сборки
RUN apk add --no-cache git go bash curl jq gzip tar unzip ca-certificates make upx

# Используем переданную версию или автоматически определяем последний stable-релиз
RUN BUILDTIME=$(date -u '+%a %b %d %H:%M:%S UTC %Y') && \
    if [ -n "$MIHOMO_VERSION" ]; then \
        TAG="$MIHOMO_VERSION"; \
    else \
        JSON="$(curl -fsSL --retry 3 --retry-delay 2 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)" && \
        TAG="$(echo "$JSON" | jq -er .tag_name)"; \
    fi && \
    test -n "$TAG" && \
    git clone --depth=1 --branch "$TAG" --single-branch https://github.com/MetaCubeX/mihomo.git /src && \
    echo "Updating version.go with TAG=${TAG} and BUILDTIME=${BUILDTIME}" && \
    sed -i "s|Version\s*=.*|Version = \"${TAG}\"|" constant/version.go && \
    sed -i "s|BuildTime\s*=.*|BuildTime = \"${BUILDTIME}\"|" constant/version.go

RUN set -eux; \
    PATCH=/tmp/mihomo-skip-invalid-proxies.patch; \
    git apply --check "$PATCH"; \
    git apply "$PATCH"; \
    grep -Fq 'skip invalid proxy' adapter/provider/provider.go; \
    grep -Fq 'usable proxy (skipped' adapter/provider/provider.go; \
    git diff --check; \
    echo "Invalid proxy skip patch applied and verified"

RUN set -eux; \
    PATCH=/tmp/mihomo-happ-v2raytun-subscription-support.patch; \
    git apply --check "$PATCH"; \
    git apply "$PATCH"; \
    grep -Fq 'hpwnrFallback' component/resource/vehicle.go; \
    grep -Fq 'Fallback(error)' component/resource/fetcher.go; \
    git diff --check; \
    echo "HPWNR patch applied and verified"

# origin https://github.com/MetaCubeX/mihomo/pull/3326.patch
RUN set -eux; \
    PATCH=/tmp/mihomo-reality-x25519mlkem768-clienthello.patch; \
    git apply --check "$PATCH"; \
    git apply "$PATCH"; \
    grep -Fq 'BuildAddedX25519MLKEM768HandshakeState' component/tls/utls.go; \
    echo "Reality X25519MLKEM768 patch applied and verified"

RUN set -eu; \
    sed -i \
        -e 's/hello\.SessionId\[0\] = 1/hello.SessionId[0] = 26/' \
        -e 's/hello\.SessionId\[1\] = 8/hello.SessionId[1] = 3/' \
        -e 's/hello\.SessionId\[2\] = 2/hello.SessionId[2] = 27/' \
        component/tls/reality.go; \
    grep -Fq 'hello.SessionId[0] = 26' component/tls/reality.go; \
    grep -Fq 'hello.SessionId[1] = 3' component/tls/reality.go; \
    grep -Fq 'hello.SessionId[2] = 27' component/tls/reality.go; \
    echo "Reality minClientVer patch applied and verified"
  

FROM --platform=$BUILDPLATFORM prebuild AS build
ARG TARGETPLATFORM \
    TARGETARCH \
    TARGETOS \
    TARGETVARIANT

# сборка mihomo с исправлениями
ARG WITH_GVISOR=0

WORKDIR /src

ENV GOCACHE=/var/cache/go-build \
    GOMODCACHE=/go/pkg/mod \
    GOTMPDIR=/var/tmp/go-tmp \
    GOFLAGS="-modcacherw"

# Сборка mihomo для целевой архитектуры
RUN --mount=type=cache,id=mihomo-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=mihomo-go-build,target=/var/cache/go-build \
    mkdir -p "$GOTMPDIR" && \
    echo "Building for $TARGETARCH $TARGETVARIANT" && \
    BUILD_TAGS="" && \
    if [ "$WITH_GVISOR" = "1" ]; then BUILD_TAGS="with_gvisor"; fi && \
    echo "Build tags: $BUILD_TAGS" && \
    if [ "$TARGETARCH" = "arm" ]; then \
        export GOARCH=arm; \
        if [ "$TARGETVARIANT" = "v5" ]; then export GOARM=5; \
        elif [ "$TARGETVARIANT" = "v7" ]; then export GOARM=7; fi; \
    else \
        export GOARCH=$TARGETARCH; \
    fi && \
    export GOOS=$TARGETOS && CGO_ENABLED=0 go build -v -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /src/mihomo .

WORKDIR /tmp

#make work structure
RUN mkdir -p build/usr/bin build/etc && \
    mv /src/mihomo build/usr/bin/mihomo

COPY entrypoint.sh build/
COPY mihomo-fs build/

RUN set -eux; \
    case "$TARGETARCH-$TARGETVARIANT" in \
        amd64-*) HPWNR_ASSET="hpwnr-linux-x86_64" ;; \
        arm64-*) HPWNR_ASSET="hpwnr-linux-arm64" ;; \
        arm-v7) HPWNR_ASSET="hpwnr-linux-armv7" ;; \
        arm-v5) HPWNR_ASSET="hpwnr-linux-armv5" ;; \
        *) HPWNR_ASSET="" ;; \
    esac; \
    if [ -n "$HPWNR_ASSET" ]; then \
        curl -fL --retry 3 "https://github.com/wiktorbgu/hpwnr/releases/latest/download/$HPWNR_ASSET" -o /tmp/build/usr/bin/hpwnr; \
        chmod 0755 /tmp/build/usr/bin/hpwnr; \
    fi

ARG UPX=0

# Сжимаем готовые ELF-бинарники UPX, кроме armv5
RUN set -eux; \
    UPX_ENABLED="$UPX"; \
    unset UPX; \
    if [ "$UPX_ENABLED" = "1" ] && { [ "$TARGETARCH" != "arm" ] || [ "$TARGETVARIANT" != "v5" ]; }; then \
        for BIN in /tmp/build/usr/bin/mihomo /tmp/build/usr/bin/hpwnr; do \
            if [ -f "$BIN" ]; then \
                echo "=== Before UPX: $BIN ==="; \
                ls -lh "$BIN"; \
                upx --best --no-lzma "$BIN"; \
                upx -t "$BIN"; \
                echo "=== After UPX: $BIN ==="; \
                ls -lh "$BIN"; \
            fi; \
        done; \
    else \
        echo "UPX compression disabled (UPX=$UPX_ENABLED)"; \
    fi

# Базовые образы для каждой архитектуры
FROM --platform=linux/amd64 wiktorbgu/alpine-mikrotik:ip-nf-tables AS linux-amd64
FROM --platform=linux/arm/v7 wiktorbgu/alpine-mikrotik:ip-nf-tables AS linux-armv7
FROM --platform=linux/arm64 wiktorbgu/alpine-mikrotik:ip-nf-tables AS linux-arm64
FROM --platform=linux/arm/v5 debian:trixie-slim AS linux-armv5

# FINAL IMAGE
FROM ${TARGETOS}-${TARGETARCH}${TARGETVARIANT}
ARG TARGETPLATFORM \
    TARGETARCH \
    TARGETOS \
    TARGETVARIANT

COPY --from=build /tmp/build/ /

# DISABLE_NFTABLES нужна именно для михомо
ENV DISABLE_NFTABLES=1 \
    CONFIG="default_config.yaml" \
    WORKDIR="/etc/mihomo" \
    HEALTH_CHECK_ENABLE="true" \
    HEALTH_CHECK_URL="https://www.gstatic.com/generate_204" \
    HEALTH_CHECK_INTERVAL=300 \
    HEALTH_CHECK_TIMEOUT=5000 \
    HEALTH_CHECK_LAZY="true" \
    HEALTH_CHECK_EXPECTED_STATUS=204 \
    TOLERANCE=10 \
    MIXED_PORT=1080 \
    UI_PORT=9090 \
    EXTERNAL_CONTROLLER_ADDRESS="0.0.0.0" \
    TUN_STACK="mips" \
    TUN_INET4_ADDRESS="198.19.0.1/30" \
    TUN_INET6_ADDRESS="fdfe:dcba:9876::1/126" \
    TUN_AUTO_REDIRECT="true" \
    TUN_AUTO_DETECT_INTERFACE="true" \
    TUN_AUTO_ROUTE="true" \
    TUN_DISABLE_ICMP_FORWARDING="true" \
    EXTERNAL_UI_PATH="ui" \
    IPV6="true" \
    IP_VERSION="dual" \
    PROVIDER_INTERVAL=3600 \
    DNS_ENABLE="true" \
    DNS_USE_SYSTEM_HOSTS="true" \
    DNS_CACHE_ALGORITHM="arc" \
    DNS_PREFER_H3="false" \
    DNS_LISTEN="0.0.0.0:53" \
    DNS_ENHANCED_MODE="fake-ip" \
    DNS_FAKE_IP_RANGE="198.18.0.0/15" \
    DNS_FAKE_IP_TTL=1 \
    DNS_BOOTSTRAP="system" \
    DNS="system" \
    DNS_DEFAULT_NAMESERVER="\$DNS_BOOTSTRAP" \
    DNS_NAMESERVER="\$DNS" \
    DNS_PROXY_SERVER_NAMESERVER="\$DNS" \
    DNS_RESPECT_RULES="true" \
    DNS_FAKE_IP_FILTER_MODE="blacklist" \
    TCP_CONCURRENT="true" \
    KEEP_ALIVE_IDLE=60 \
    KEEP_ALIVE_INTERVAL=30 \
    FIND_PROCESS_MODE="off" \
    STORE_SELECTED="true" \
    UNIFIED_DELAY="true" \
    LOADBALANCE_STRATEGY="consistent-hashing"

RUN case "$TARGETPLATFORM" in \
        "linux/arm/v5") \
            apt update && \
            apt install -y bash iptables tzdata gettext-base iputils-ping traceroute procps ca-certificates kmod tini iproute2 && \
            apt autoremove -y && \
            apt clean -y && \
            rm -rf /var/cache/apt/archives /var/lib/apt/lists/* && \
            sed -i '1s|^#!/bin/sh|#!/bin/bash|' /entrypoint.sh && \
            # IPv4
            rm /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
            ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
            ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
            ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
            # IPv6
            rm /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore && \
            ln -s /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
            ln -s /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
            ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore;; \
        linux/arm/v7) \
            apk add --no-cache envsubst ca-certificates && \
            rm -vrf /var/cache/apk/* ;; \
        linux/amd64 | linux/arm64) \
            apk add --no-cache envsubst ca-certificates && \
            rm -vrf /var/cache/apk/* ;; \
        *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]