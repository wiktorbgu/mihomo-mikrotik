#!/bin/sh
sleep 1

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

lsmod | grep -q '^nf_tables' && NFT_CORE=1 || NFT_CORE=0

if [ "$OS" = "alpine" ]; then
  # если в системе нет модуля nftables или принудительно хотим использовать iptables
  if [ "${IPTABLES:-0}" -eq 1 ] || [ $NFT_CORE -eq 0 ]; then
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

# настроить маскарад
if [ "${IPTABLES:-0}" -eq 0 ] && [ $NFT_CORE -eq 1 ]; then
  nft add table ip nat
  nft add chain ip nat postrouting { type nat hook postrouting priority srcnat \; }
  nft add rule ip nat postrouting meta oiftype ether ip daddr != { 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255} masquerade
fi

# network
FIRST_IFACE=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2; exit}' | cut -d@ -f1)
OTHER_IFACES=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d@ -f1)
GATEWAY=$(ip route | awk -v iface="$FIRST_IFACE" '$1=="default" && $0~iface {print $3; exit}')
LOCAL_IPS=$(
  ip -4 -o addr show scope global \
  | awk '
      NR==FNR && /link\/ether/ {
          sub(/@.*/, "", $2)
          iface[$2]=1
          next
      }
      $2 in iface {
          split($4,a,"/")
          print a[1]
      }
    ' <(ip -o link show) - \
  | paste -sd, -
)

# удалить ранние main/default for ros = 7.22
ip rule | awk '
/lookup main/ && $1+0 < 32766 {gsub(":","",$1); print $1}
/lookup default/ && $1+0 < 32767 {gsub(":","",$1); print $1}
' | while read prio; do
    ip rule del priority "$prio" 2>/dev/null
done
# гарантировать системные правила
ip rule | grep -q "lookup main" || ip rule add lookup main priority 32766
ip rule | grep -q "lookup default" || ip rule add lookup default priority 32767

#
AWG_DIR="$WORKDIR/awg"
TEMPLATE_DIR="$WORKDIR/template"
USER_SH_DIR="$WORKDIR/user_sh"
mkdir -p "$AWG_DIR" "$TEMPLATE_DIR" "$USER_SH_DIR"
DEFAULT_CONFIG_FILE="/etc/mihomo_preset/template/default_config.yaml"
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# если не указано имя кастомного конфига, испольузем и актуализируем default
if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_FILE" ]; then
    if ! diff -q "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE" >/dev/null; then
      mv "$TEMPLATE_FILE" "$BACKUP_PATH"
      cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
    fi
  else
    cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
  fi
  CONFIG_FILE=$TEMPLATE_FILE
else
  if [ -f "$TEMPLATE_FILE" ]; then
    # есть заданный шаблон — используем его
    CONFIG_FILE="$TEMPLATE_FILE"
  elif [ -f "$WORKDIR/$CONFIG" ]; then
    # шаблона нет, но есть кастомный конфиг
    CONFIG_FILE="$WORKDIR/$CONFIG"
    ENVSUBST=0
  else
    # нет ни шаблона, ни кастомного конфига
    echo "ERROR: Config not found! Checked: $TEMPLATE_FILE and $WORKDIR/$CONFIG. Check container mounts/volume paths."
    exit 1
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

yaml_quote() {
  sed 's/\\/\\\\/g; s/"/\\"/g; s/.*/"&"/'
}

###
parse_awg_config() {
  local config_file="$1"
  local awg_name="${2:-$(basename "$config_file" .conf)}"

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
  # 3.0 разрешает диапазон ("22-30"), но mihomo держит persistent-keepalive в int и на диапазоне не распарсит конфиг вовсе. 
  # Берём нижнюю границу: keepalive чаще — лишний трафик, но NAT точно останется живым.
  case "$keepalive" in
    *-*)
      log "AWG $awg_name: PersistentKeepalive range '$keepalive' -> ${keepalive%%-*} (mihomo accepts a single value)" >&2
      keepalive="${keepalive%%-*}"
      ;;
  esac
  local workers=$(read_cfg "Workers")

  local jc=$(read_cfg "Jc");         local jmin=$(read_cfg "Jmin");     local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1");         local s2=$(read_cfg "S2")
  local s3=$(read_cfg "S3");         local s4=$(read_cfg "S4")
  local h1=$(read_cfg "H1");         local h2=$(read_cfg "H2");         local h3=$(read_cfg "H3");         local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1");         local i2=$(read_cfg "I2");         local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4");         local i5=$(read_cfg "I5")
  local j1=$(read_cfg "J1");         local j2=$(read_cfg "J2");         local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  # AmneziaWG 3.0. HeaderProtectionKey и ContentPaddingAddition должны совпадать с сервером, тайминги — чисто клиентские. 
  # Все значения, кроме ключа, задаются диапазоном "a-b" либо одним числом.
  local hp_key=$(read_cfg "HeaderProtectionKey")
  local content_padding=$(read_cfg "ContentPaddingAddition")
  local rekey_after=$(read_cfg "RekeyAfterTime")
  local rekey_timeout=$(read_cfg "RekeyTimeout")
  local reject_after=$(read_cfg "RejectAfterTime")
  local keepalive_timeout=$(read_cfg "KeepaliveTimeout")
  local max_handshakes=$(read_cfg "MaxHandshakeAttempts")
  # AmneziaWG 3.1 boolean options.
  local random_trailers=$(read_cfg "RandomTrailers")
  local disable_cookies=$(read_cfg "DisableCookies")
  case "$(printf '%s' "$random_trailers" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) random_trailers=true ;;
    0|false|no|off) random_trailers=false ;;
    *) random_trailers="" ;;
  esac
  case "$(printf '%s' "$disable_cookies" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) disable_cookies=true ;;
    0|false|no|off) disable_cookies=false ;;
    *) disable_cookies="" ;;
  esac
  # Ручное переопределение — на случай, когда 3.0 нужна без единого v3-параметра
  local awg_version=$(read_cfg "AwgVersion")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local ip_v4=""
  local ip_v6=""
  if [ -n "$address" ]; then
    OLDIFS=$IFS
    IFS=','
    for addr in $address; do
      addr=$(echo "$addr" | sed 's/[[:space:]]//g')
      if echo "$addr" | grep -q ':'; then
        [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
        ip_v6="${ip_v6}${addr%%/*}"
      else
        [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
        ip_v4="${ip_v4}${addr%%/*}"
      fi
    done
    IFS=$OLDIFS
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
  echo "    ip-stack:"
  echo "      mode: mips"
  echo "      congestion-controller: bbr3"
  local dns_raw=$(read_cfg "DNS")
  if [ -n "$dns_raw" ] && ! echo "$dns_raw" | grep -q '\$'; then
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

  # Версия протокола. mihomo поднимает v3-реализацию только при version: 3;
  # при любом другом значении работает legacy — она же обслуживает 1.5 и 2.0.
  local awg3=0
  for v in "$hp_key" "$content_padding" "$rekey_after" "$rekey_timeout" "$reject_after" "$keepalive_timeout" "$max_handshakes" "$random_trailers" "$disable_cookies"; do
    [ -n "$v" ] && awg3=1
  done
  case "$awg_version" in
    3|3.*) awg3=1 ;;
    "") ;;
    *) awg3=0 ;;
  esac

  if [ "$awg3" -eq 1 ]; then
    # J1-J3 и ITime были только в 1.5 и вырезаны из 3.0. 
    # UAPI ядра отвергает неизвестный ключ целиком — с ними proxy просто не поднимется.
    if [ -n "$j1$j2$j3$itime" ]; then
      log "AWG $awg_name: dropping v1.5-only J1-J3/ITime, AmneziaWG 3.0 removed them" >&2
      j1=""; j2=""; j3=""; itime=""
    fi
    # Header protection шифрует заголовки, беря S1-S4 как nonce, поэтому 
    # ядро требует каждое из них >= 12 (HeaderCipherNonceSize) и иначе падает.
    if [ -n "$hp_key" ]; then
      for v in s1 s2 s3 s4; do
        eval val=\$$v
        case "$val" in
          ''|*[!0-9]*) val=0 ;;
        esac
        if [ "$val" -lt 12 ]; then
          log "AWG $awg_name: WARNING $v=$val, HeaderProtectionKey requires >= 12 — the peer will refuse to start" >&2
        fi
      done
    fi
  fi

  local awg_params="jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  awg_params="$awg_params hp_key content_padding rekey_after rekey_timeout reject_after keepalive_timeout max_handshakes random_trailers disable_cookies"
  local has_awg_param=0
  for v in i1 i2 i3 i4 i5; do
    eval val=\$$v
    case "$val" in
      \<*\>) ;;
      *) eval "$v=" ;;
    esac
  done
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
    [ -n "$i1" ]     && printf '      i1: %s\n' "$(printf '%s' "$i1" | yaml_quote)"
    [ -n "$i2" ]     && printf '      i2: %s\n' "$(printf '%s' "$i2" | yaml_quote)"
    [ -n "$i3" ]     && printf '      i3: %s\n' "$(printf '%s' "$i3" | yaml_quote)"
    [ -n "$i4" ]     && printf '      i4: %s\n' "$(printf '%s' "$i4" | yaml_quote)"
    [ -n "$i5" ]     && printf '      i5: %s\n' "$(printf '%s' "$i5" | yaml_quote)"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
    if [ "$awg3" -eq 1 ]; then
      echo "      version: 3"
      # v3-поля в mihomo объявлены строками (значением может быть диапазон), 
      # поэтому кавычим: иначе YAML отдал бы 22-30 строкой, а 30 — числом.
      [ -n "$hp_key" ]            && printf '      header-protection-key: %s
'    "$(printf '%s' "$hp_key" | yaml_quote)"
      [ -n "$content_padding" ]   && printf '      content-padding-addition: %s
' "$(printf '%s' "$content_padding" | yaml_quote)"
      [ -n "$rekey_after" ]       && printf '      rekey-after-time: %s
'         "$(printf '%s' "$rekey_after" | yaml_quote)"
      [ -n "$rekey_timeout" ]     && printf '      rekey-timeout: %s
'            "$(printf '%s' "$rekey_timeout" | yaml_quote)"
      [ -n "$reject_after" ]      && printf '      reject-after-time: %s
'        "$(printf '%s' "$reject_after" | yaml_quote)"
      [ -n "$keepalive_timeout" ] && printf '      keepalive-timeout: %s
'        "$(printf '%s' "$keepalive_timeout" | yaml_quote)"
      [ -n "$max_handshakes" ]    && printf '      max-handshake-attempts: %s
'   "$(printf '%s' "$max_handshakes" | yaml_quote)"
      [ -n "$random_trailers" ]   && echo "      random-trailers: $random_trailers"
      [ -n "$disable_cookies" ]   && echo "      disable-cookies: $disable_cookies"
    fi
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

### VETH
if [ -n "$OTHER_IFACES" ]; then
TABLE_BASE=200
i=0
veth_file="$WORKDIR/veth.yaml"
IFACE_COUNT=$(echo "$OTHER_IFACES" | wc -w)

# если нет ни серверов ни конфигов awg ни дополнительных veth — добавляем единственный DIRECT
  if [ -z "$PROVIDERS_LIST" ] && [ "$IFACE_COUNT" -eq 1 ]; then
PROVIDERS_LIST="${PROVIDERS_LIST}    proxies:
      - DIRECT"
# либо добавляем все остальные veth как прокси
elif [ "$IFACE_COUNT" -gt 1 ]; then
echo "proxies:" > "$veth_file"
for IFACE in $OTHER_IFACES; do
  [ "$IFACE" = "$FIRST_IFACE" ] && continue
  SRC_IP=$(ip -o -4 addr show dev "$IFACE" | awk '{sub(/\/.*/,"",$4);print $4}')
  [ -z "$SRC_IP" ] && continue

  cat >> "$veth_file" <<EOF
- name: $IFACE
  type: direct
  ip-version: $IP_VERSION
  interface-name: $IFACE
EOF

  TABLE=$((TABLE_BASE + i))
  ip rule show | grep -q "from $SRC_IP lookup $TABLE" || \
    ip rule add from "$SRC_IP" table "$TABLE"
  # задать шлюзом интерфейса VETH соседний контейнер в той же подсети, если задана переменная
  # нормализуем имя интерфейса и IP для поиска переменной
  SAFE_IFACE=$(echo "$IFACE" | tr '-' '_')
  SAFE_IP=$(echo "$SRC_IP" | tr '.' '_')
  VAR_GATEWAY_IP="GATEWAY_${SAFE_IP}"
  VAR_GATEWAY_IFACE="GATEWAY_${SAFE_IFACE}"
  # сначала проверяем gateway по IP
  if printenv "$VAR_GATEWAY_IP" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IP"); \
    # потом по интерфейсу
    elif printenv "$VAR_GATEWAY_IFACE" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IFACE"); \
    # fallback
    else GATEWAY_VETH="$GATEWAY"; \
  fi
  ip route replace default via "$GATEWAY_VETH" dev "$IFACE" table "$TABLE"
  i=$((i+1))
done
add_provider "VETH" "file" "$veth_file"
fi
fi

# правила nft для настройки tproxy
nft_rules() {
  TPROXY_PORT=15123
  TPROXY_MARK=0x123
  TPROXY_TABLE=100

 # --- nftables table ---
  nft add table inet tproxy_ci

  # --- divert chain для ускорения TCP ---
  nft "add chain inet tproxy_ci divert {
    type filter hook prerouting priority mangle - 5;
    policy accept;
  }"

  # --- socket transparent (ускоряет established TCP) ---
  nft add rule inet tproxy_ci divert \
    meta l4proto tcp socket transparent 1 \
    meta mark set $TPROXY_MARK \
    accept

  # --- prerouting (mangle, но не слишком рано) ---
  nft "add chain inet tproxy_ci prerouting {
    type filter hook prerouting priority mangle;
    policy accept;
  }"

  # --- исключаем все локальные сервисы и служебные адреса ---
  if ! nft add rule inet tproxy_ci prerouting fib daddr type { local, broadcast, multicast } return 2>/dev/null; then
    # for ros < 7.22
    nft add rule inet tproxy_ci prerouting ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, $LOCAL_IPS } return
  fi

  # --- защита от MPTCP ---
  nft add rule inet tproxy_ci prerouting tcp option mptcp exists drop

  # --- TPROXY ---
  nft add rule inet tproxy_ci prerouting \
    iifname \""$FIRST_IFACE"\" \
    meta l4proto { tcp, udp } \
    meta mark set $TPROXY_MARK \
    tproxy ip to 127.0.0.1:$TPROXY_PORT \
    accept

  # --- policy routing ---
  ip rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  ip route replace local 0.0.0.0/0 dev lo table $TPROXY_TABLE proto static scope host

  # если ядро без IPv6 — просто пропускаем
  [ -f /proc/net/if_inet6 ] || return 0

  # --- TPROXY IPv6 ---
  nft add rule inet tproxy_ci prerouting \
      iifname \""$FIRST_IFACE"\" \
      meta l4proto { tcp, udp } \
      meta mark set $TPROXY_MARK \
      tproxy ip6 to [::1]:$TPROXY_PORT \
      accept

  # --- policy routing IPv6 ---
  ip -6 rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  ip -6 route replace local ::/0 dev lo table $TPROXY_TABLE
}

# если это шаблон, выполняем преднастройки
if [ "${ENVSUBST:-1}" -eq 1 ]; then
  # AUTO CONFIG tun-in
if grep -Eq '^[[:space:]]*\$TUN_IN_AUTOCONFIG' "$CONFIG_FILE"; then
  if [ "${TUN:-0}" -eq 1 ] || [ $NFT_CORE -eq 0 ]; then
  TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tun
    stack: $TUN_STACK
    auto-detect-interface: $TUN_AUTO_DETECT_INTERFACE
    auto-route: $TUN_AUTO_ROUTE
    auto-redirect: $TUN_AUTO_REDIRECT
    inet4-address:
    - $TUN_INET4_ADDRESS
    inet6-address:
    - $TUN_INET6_ADDRESS
    dns-hijack:
    - any:53
    disable-icmp-forwarding: $TUN_DISABLE_ICMP_FORWARDING
EOF
)  
else
  nft_rules
  TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tproxy
    port: $TPROXY_PORT
    udp: true
EOF
)
fi
export TUN_IN_AUTOCONFIG
fi
# конец проверки шаблона
fi

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

# если это шаблон, заполняем переменными конфиг файл
if [ "${ENVSUBST:-1}" -eq 1 ]; then
  envsubst < "$TEMPLATE_FILE" > "$WORKDIR/$CONFIG"
fi

CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
# print version mihomo to log
mihomo -v
exec mihomo $CMD_MIHOMO || exit 1