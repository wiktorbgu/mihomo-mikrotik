FROM --platform=$BUILDPLATFORM alpine AS build
ARG TARGETPLATFORM \
    TARGETARCH \
    TARGETOS \
    TARGETVARIANT \
    WITH_GVISOR=1

# сборка mihomo с исправлениями загрузки битых ссылок в публичных подписках
WORKDIR /src

# инструменты для сборки
RUN apk add --no-cache git go bash curl jq gzip tar unzip ca-certificates make

ENV GOCACHE=/var/cache/go-build \
    GOTMPDIR=/var/tmp/go-tmp \
    GOFLAGS="-modcacherw"
RUN mkdir -p /var/cache/go-build /var/tmp/go-tmp

# Переключаемся на нужный тэг
RUN JSON="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)" && \
    TAG="$(echo "$JSON" | jq -r .tag_name)" && \
    git clone --depth=1 --branch "$TAG" --single-branch https://github.com/MetaCubeX/mihomo.git /src && \
    git switch --detach "$TAG" && \
    BUILDTIME=$(date -u '+%a %b %d %H:%M:%S UTC %Y') && \
    echo "Updating version.go with TAG=${TAG} and BUILDTIME=${BUILDTIME}" && \
    sed -i "s|Version\s*=.*|Version = \"${TAG}\"|" constant/version.go && \
    sed -i "s|BuildTime\s*=.*|BuildTime = \"${BUILDTIME}\"|" constant/version.go

RUN sed -i '/^import (/a\    "github.com/metacubex/mihomo/log"' \
    adapter/provider/provider.go && \
    sed -i 's@return nil, fmt.Errorf("proxy %d error: %w", idx, err)@name, _ := mapping["name"].(string)\n                log.Warnln("[Provider %s] skip invalid proxy (idx=%d, name=%q): %v", pdName, idx, name, err)\n                continue@g' \
    adapter/provider/provider.go

RUN sed -i \
    -e 's/hello\.SessionId\[0\] = 1/hello.SessionId[0] = 26/' \
    -e 's/hello\.SessionId\[1\] = 8/hello.SessionId[1] = 3/' \
    -e 's/hello\.SessionId\[2\] = 2/hello.SessionId[2] = 27/' \
    component/tls/reality.go && \
    grep -Fq 'hello.SessionId[0] = 26' component/tls/reality.go && \
    grep -Fq 'hello.SessionId[1] = 3' component/tls/reality.go && \
    grep -Fq 'hello.SessionId[2] = 27' component/tls/reality.go || \
    { echo "patch did not apply: reality minClientVer (component/tls/reality.go)" >&2; exit 1; }
  
# Сборка mihomo для целевой архитектуры
RUN echo "Building for $TARGETARCH $TARGETVARIANT" && \
    BUILD_TAGS="" && [ "$WITH_GVISOR" = "1" ] && BUILD_TAGS="with_gvisor" && \
    echo "Build tags: $BUILD_TAGS" && \
    if [ "$TARGETARCH" = "arm" ]; then \
        export GOARCH=arm; \
        if [ "$TARGETVARIANT" = "v5" ]; then export GOARM=5; \
        elif [ "$TARGETVARIANT" = "v7" ]; then export GOARM=7; fi; \
    else \
        export GOARCH=$TARGETARCH; \
    fi && \
    export GOOS=$TARGETOS && CGO_ENABLED=0 go build -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /src/mihomo .

WORKDIR /tmp

#make work structure
RUN mkdir -p build/usr/bin build/etc && \
    mv /src/mihomo build/usr/bin/mihomo && \
    chmod -R +x .

COPY entrypoint.sh build/
COPY mihomo-fs build/

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
    MIXED_PORT=1080 \
    UI_PORT=9090 \
    EXTERNAL_CONTROLLER_ADDRESS="0.0.0.0" \
    TUN_STACK="system" \
    TUN_INET4_ADDRESS="198.19.0.1/30" \
    TUN_AUTO_REDIRECT="true" \
    TUN_AUTO_DETECT_INTERFACE="true" \
    TUN_AUTO_ROUTE="true" \
    TUN_DISABLE_ICMP_FORWARDING="true" \
    EXTERNAL_UI_PATH="ui" \
    IPV6="true" \
    PROVIDER_INTERVAL=3600 \
    DNS_ENABLE="true" \
    DNS_USE_SYSTEM_HOSTS="true" \
    DNS_CACHE_ALGORITHM="arc" \
    DNS_PREFER_H3="false" \
    DNS_LISTEN="0.0.0.0:53" \
    DNS_ENHANCED_MODE="fake-ip" \
    DNS_FAKE_IP_RANGE="198.18.0.0/15" \
    DNS_FAKE_IP_TTL=1 \
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