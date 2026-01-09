#!/bin/sh
sleep 1

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

if [ "$OS" = "alpine" ]; then
  # если в системе нет модуля nftables
  if ! lsmod | grep -q nf_tables; then
      # удалить nftables если есть
      apk info -e nftables >/dev/null 2>&1 && apk del nftables >/dev/null 2>&1
      # установить iptables если отсутствуют
      apk info -e iptables >/dev/null 2>&1 || apk add iptables
      # установить iptables-legacy если отсутствует и исправить символьные ссылки
      if ! apk info -e iptables-legacy >/dev/null 2>&1; then
        apk add iptables-legacy
        # IPv4
        rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
        ln -s /usr/sbin/iptables-legacy         /usr/sbin/iptables
        ln -s /usr/sbin/iptables-legacy-save    /usr/sbin/iptables-save
        ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
        # IPv6
        rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore
        ln -s /usr/sbin/ip6tables-legacy         /usr/sbin/ip6tables
        ln -s /usr/sbin/ip6tables-legacy-save    /usr/sbin/ip6tables-save
        ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore
      fi
  # если в системе есть модуль nftables
  else
      export DISABLE_NFTABLES=0
      # удалить iptables и legacy если есть
      if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
        apk del iptables iptables-legacy >/dev/null 2>&1
      fi
      # установить nftables если отсутствует
      apk info -e nftables >/dev/null 2>&1 || apk add nftables
  fi
fi

DEFAULT_CONFIG=$(cat << 'EOF'
external-controller: $EXTERNAL_CONTROLLER_ADDRESS:$UI_PORT
external-ui: $EXTERNAL_UI_PATH
external-ui-url: $EXTERNAL_UI_URL
secret: $UI_SECRET
unified-delay: true
log-level: $LOG_LEVEL
ipv6: $IPV6

dns:
  enable: $DNS_ENABLE
  use-system-hosts: $DNS_USE_SYSTEM_HOSTS
  nameserver:
  - system

proxy-providers:
$PROVIDERS_BLOCK

proxy-groups:
  - name: SELECTOR
    type: select
    use:
$PROVIDERS_LIST
  - name: QUIC
    type: select
    proxies:
      - PASS
      - REJECT

listeners:
  - name: mixed-in
    type: mixed
    port: $MIXED_PORT
  - name: tun-in
    type: tun
    stack: $TUN_STACK
    auto-detect-interface: $TUN_AUTO_DETECT_INTERFACE
    auto-route: $TUN_AUTO_ROUTE
    auto-redirect: $TUN_AUTO_REDIRECT
    inet4-address:
    - $TUN_INET4_ADDRESS

rules:
  - AND,((NETWORK,udp),(DST-PORT,443)),QUIC
  - IN-NAME,tun-in,SELECTOR
  - IN-NAME,mixed-in,SELECTOR
  - MATCH,GLOBAL
EOF
)

AWG_DIR="$WORKDIR/awg"
TEMPLATE_DIR="$WORKDIR/template"
USER_SH_DIR="$WORKDIR/user_sh"
mkdir -p $TEMPLATE_DIR
mkdir -p $AWG_DIR
mkdir -p $USER_SH_DIR
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# завершаем работу если не используется кастомный конфиг или для дефолта не задан хотя бы один необходимый параметр
if [ "$CONFIG" = "default_config.yaml" ]; then
  has_env_vars=$(env | grep -qE '^(SRV|SUB)[0-9]' && echo 1 || echo 0)
  has_conf_files=$(find "$AWG_DIR" -type f -name '*.conf' 2>/dev/null | grep -q . && echo 1 || echo 0)
  if [ "$has_env_vars" -eq 0 ] && [ "$has_conf_files" -eq 0 ]; then
    echo "No server/subscription variables (SRV*/SUB*) and no *.conf files wireguard/amneziawg in $AWG_DIR. Exiting."
    exit 1
  fi
fi

# если не указано имя кастомного конфига, испольузем и актуализируем default
if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_FILE" ]; then
    if ! diff -q <(echo "$DEFAULT_CONFIG") "$TEMPLATE_FILE" >/dev/null; then
      mv "$TEMPLATE_FILE" "$BACKUP_PATH"
      echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
    fi
  else
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
  fi
else
  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
  fi
fi

# смена веб панели при замене ссылки на её загрузку
UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null)
if [[ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]]; then
  rm -rf "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
fi

# генерируем hwid для серверов и подписок с ограничениями по устройствам
HWID_STORE="$WORKDIR/.hwid"
if [ ! -f "$HWID_STORE" ]; then
  cat /proc/sys/kernel/random/uuid | tr -d '-' > "$HWID_STORE"
fi
HWID="${HWID:-$(cat "$HWID_STORE")}"

###
parse_awg_config() {
  local config_file="$1"
  local awg_name=$(basename "$config_file" .conf)

read_cfg() {
  local key="$1"
  grep -iE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*" "$config_file" 2>/dev/null | \
    tail -n1 | \
    sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*//I' | \
    tr -d '\r\n' | \
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

  local private_key=$(read_cfg "PrivateKey")
  local address=$(read_cfg "Address")
  local dns=$(read_cfg "DNS")
  local mtu=$(read_cfg "MTU")
  local keepalive=$(read_cfg "PersistentKeepalive")
  local workers=$(read_cfg "Workers")

  local jc=$(read_cfg "Jc");         local jmin=$(read_cfg "Jmin");     local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1");         local s2=$(read_cfg "S2")
  local s3=$(read_cfg "S3");         local s4=$(read_cfg "S4")
  local h1=$(read_cfg "H1");         local h2=$(read_cfg "H2");         local h3=$(read_cfg "H3");         local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1");         local i2=$(read_cfg "I2");         local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4");         local i5=$(read_cfg "I5")
  local j1=$(read_cfg "J1");         local j2=$(read_cfg "J2");         local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local ip_v4=""
  local ip_v6=""
  if [ -n "$address" ]; then
    while IFS= read -r addr; do
      addr=$(echo "$addr" | sed 's/[[:space:]]//g')
      if echo "$addr" | grep -q ':'; then
        [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
        ip_v6="${ip_v6}${addr}"
      else
        [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
        ip_v4="${ip_v4}${addr}"
      fi
    done < <(echo "$address" | tr ',' '\n')
  fi

  local server=""
  local port=""
  if [ -n "$endpoint" ]; then
    endpoint=$(echo "$endpoint" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if echo "$endpoint" | grep -q '\['; then
      server=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\1@')
      port=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\2@')
    else
      server=$(echo "$endpoint" | cut -d':' -f1)
      port=$(echo "$endpoint" | cut -d':' -f2-)
    fi
  fi

  local allowed_ips_raw=$(read_cfg "AllowedIPs")
  if [ -n "$allowed_ips_raw" ]; then
    allowed_ips_yaml=$(echo "$allowed_ips_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]*([0-9a-fA-F\.:\/-]+)[[:space:]]*$/\1/' | \
      grep -v '^$' | grep -E '^[0-9a-fA-F\.:]+/[0-9]+$' | \
      sed 's/.*/"&"/' | paste -sd, -)
    [ -z "$allowed_ips_yaml" ] && allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  else
    allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  fi

  echo "  - name: \"$awg_name\""
  echo "    type: wireguard"
  [ -n "$private_key" ] && echo "    private-key: $private_key"
  [ -n "$server" ] && echo "    server: $server"
  [ -n "$port" ] && echo "    port: $port"
  [ -n "$ip_v4" ] && echo "    ip: $ip_v4"
  [ -n "$ip_v6" ] && echo "    ipv6: $ip_v6"
  [ -n "$public_key" ] && echo "    public-key: $public_key"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"
  [ -n "$keepalive" ] && echo "    persistent-keepalive: $keepalive"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  local dialer_proxy_raw=$(read_cfg "DialerProxy")
  if [ -n "$dialer_proxy_raw" ]; then
    local dialer_proxy_clean=$(echo "$dialer_proxy_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$dialer_proxy_clean" ]; then
      echo "    dialer-proxy: \"$dialer_proxy_clean\""
    fi
  fi
  [ -n "$workers" ] && echo "    workers: $workers"

  local reserved_raw=$(read_cfg "Reserved")
  if [ -n "$reserved_raw" ]; then
    local reserved_clean=$(echo "$reserved_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$reserved_clean" ]; then
      if echo "$reserved_clean" | grep -q ','; then
        echo "    reserved: [$reserved_clean]"
      else
        echo "    reserved: \"$reserved_clean\""
      fi
    fi
  fi

  echo "    allowed-ips: [$allowed_ips_yaml]"
  echo "    udp: true"
  local dns_raw=$(read_cfg "DNS")
  if [ -n "$dns_raw" ]; then
    local dns_list=$(echo "$dns_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | \
      grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
    echo "    dns: [$dns_list]"
  fi
  local remote_resolve_raw=$(read_cfg "RemoteDnsResolve")
  if [ -n "$remote_resolve_raw" ]; then
    case "$(echo "$remote_resolve_raw" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on)
        echo "    remote-dns-resolve: true"
        ;;
      0|false|no|off)
        echo "    remote-dns-resolve: false"
        ;;
    esac
  fi

  local awg_params="jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  local has_awg_param=0
  for v in $awg_params; do
    eval val=\$$v
    [ -n "$val" ] && has_awg_param=1
  done

  if [ "$has_awg_param" -eq 1 ]; then
    echo "    amnezia-wg-option:"
    [ -n "$jc" ]     && echo "      jc: $jc"
    [ -n "$jmin" ]   && echo "      jmin: $jmin"
    [ -n "$jmax" ]   && echo "      jmax: $jmax"
    [ -n "$s1" ]     && echo "      s1: $s1"
    [ -n "$s2" ]     && echo "      s2: $s2"
    [ -n "$s3" ]     && echo "      s3: $s3"
    [ -n "$s4" ]     && echo "      s4: $s4"
    [ -n "$h1" ]     && echo "      h1: $h1"
    [ -n "$h2" ]     && echo "      h2: $h2"
    [ -n "$h3" ]     && echo "      h3: $h3"
    [ -n "$h4" ]     && echo "      h4: $h4"
    [ -n "$i1" ]     && echo "      i1: $i1"
    [ -n "$i2" ]     && echo "      i2: $i2"
    [ -n "$i3" ]     && echo "      i3: $i3"
    [ -n "$i4" ]     && echo "      i4: $i4"
    [ -n "$i5" ]     && echo "      i5: $i5"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
  fi
  echo ""
}

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""

add_provider() {
    local name="$1"
    local type="$2"        # file / http
    local source="$3"      # path / url
    local add_header="${4:-false}"

    local header=""
    local interval_block=""
    local source_key="path"

    # какой ключ использовать
    [[ "$type" == "http" ]] && source_key="url"

    # header только для SUB*
    if [[ "$add_header" == "true" && "$name" != "AWG" && "$name" != "SRV" ]]; then
        header="
    header:
      x-hwid:
      - $HWID"
    fi

    # interval только для http
    if [[ "$type" == "http" ]]; then
        interval_block="    interval: ${PROVIDER_INTERVAL}"$'\n'
    fi

    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: ${type}
    ${source_key}: \"${source}\"
${interval_block}    health-check:
      enable: ${HEALTH_CHECK_ENABLE}
      url: ${HEALTH_CHECK_URL}
      interval: ${HEALTH_CHECK_INTERVAL}
      timeout: ${HEALTH_CHECK_TIMEOUT}
      lazy: ${HEALTH_CHECK_LAZY}
      expected-status: ${HEALTH_CHECK_EXPECTED_STATUS}${header}
"

    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}"$'\n'
}


### SRV
srv_file="$WORKDIR/srv.yaml"
if env | grep -qE '^SRV[0-9]'; then
    > "$srv_file"
    while IFS='=' read -r name value; do
        case "$name" in
            SRV[0-9]*)
                echo "#== $name ==" >> "$srv_file"
                printf "%s\n" "$value" >> "$srv_file"
                ;;
        esac
    done <<EOF
$(env)
EOF
    add_provider "SRV" "file" "$srv_file"
fi

### AWG
awg_file="$WORKDIR/awg.yaml"
if find "$AWG_DIR" -name "*.conf" -print -quit 2>/dev/null | grep -q .; then
    echo "proxies:" > "$awg_file"
    find "$AWG_DIR" -name "*.conf" | while read -r conf; do
        parse_awg_config "$conf"
    done >> "$awg_file"
    add_provider "AWG" "file" "$awg_file"
fi

### SUB
while IFS='=' read -r name value; do
    case "$name" in
        SUB[0-9]*)
            add_provider "$name" "http" "$value" true
            ;;
    esac
done <<EOF
$(env)
EOF

# пользовательские sh-скрипты подключаются (source) и выполняются в текущем shell-процессе с общим окружением
for script in "$USER_SH_DIR"/*.sh; do
  [ -f "$script" ] || continue
  echo "Running user scripts: $script"
  . "$script"
done

# экспортируем переменные заданные текущим скриптом для использования в шаблонах конфигурации mihomo
export PROVIDERS_BLOCK
export PROVIDERS_LIST
export HWID

envsubst < "$TEMPLATE_DIR/$CONFIG" > "$WORKDIR/$CONFIG"

CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
# print version mihomo to log
mihomo -v
exec mihomo $CMD_MIHOMO || exit 1