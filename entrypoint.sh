#!/bin/sh

if [ "$CONFIG" = "default_config.yaml" ]; then
  if ! env | grep -qE '^(SRV|SUB)[0-9]'; then
    echo "No server or subscription variables (SRV*/SUB*) are defined. Exiting."
    exit 1
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
  - MATCH,DIRECT
EOF
)

mkdir -p $WORKDIR/template
TEMPLATE_PATH="$WORKDIR/template/$CONFIG"
BACKUP_PATH="$WORKDIR/template/default_config_old.yaml"

if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_PATH" ]; then
    if ! diff -q <(echo "$DEFAULT_CONFIG") "$TEMPLATE_PATH" >/dev/null; then
      mv "$TEMPLATE_PATH" "$BACKUP_PATH"
      echo "$DEFAULT_CONFIG" > "$TEMPLATE_PATH"
    fi
  else
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_PATH"
  fi
else
  if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_PATH"
  fi
fi

UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null)
if [[ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]]; then
  rm -rf "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
fi


PROVIDERS_BLOCK=""
PROVIDERS_LIST=""
####
if env | grep -qE '^(SRV)[0-9]'; then
srv_file="$WORKDIR/srv.yaml"
> "$srv_file"
env | while IFS='=' read -r name value; do
    case "$name" in
        SRV[0-9]*)
            echo "#== $name ==" >> "$srv_file"
            printf "%s\n" "$value" | while IFS= read -r line; do
                echo "$line" >> "$srv_file"
            done
            ;;
    esac
done

PROVIDERS_BLOCK="  SRV:
    type: file
    path: $srv_file
    health-check:
      enable: true
      url: $HEALTH_CHECK_URL
      interval: 300
      timeout: 5000
      lazy: true
      expected-status: 204
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - SRV
"

fi
###

while IFS='=' read -r name value; do
  case "$name" in
    SUB[0-9]*)
      PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    url: \"${value}\"
    type: http
    interval: 86400
    health-check:
      enable: true
      url: \"${HEALTH_CHECK_URL}\"
      interval: 86400
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - $(echo "$name")
"
      ;;
  esac
done <<EOF
$(env)
EOF

export PROVIDERS_BLOCK
export PROVIDERS_LIST

envsubst < "$WORKDIR/template/$CONFIG" > "$WORKDIR/$CONFIG"

CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
# print version mihomo to log
mihomo -v
exec mihomo $CMD_MIHOMO || exit 1