# === PATH & Locale ===
export PATH="$HOME/.local/bin:$PATH"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# === Customize these for your own node & exit region ===
export V2RAYN_PROXY_HOST="127.0.0.1"
export V2RAYN_PROXY_PORT="10808"
export V2RAYN_CONFIG_DIR="$HOME/Library/Application Support/v2rayN/guiConfigs"

export CLAUDE_EGRESS_HOST="127.0.0.1"
export CLAUDE_EGRESS_PORT="10810"
export CLAUDE_EGRESS_NODE_REMARKS="US-Residential"   # Replace with exact node Remarks in v2rayN
export CLAUDE_EXPECTED_COUNTRY="US"                  # ISO country code matching your node
export CLAUDE_EXPECTED_TZ="America/New_York"         # IANA timezone matching your node's real city
export CLAUDE_WIFI_SERVICE="Wi-Fi"

proxy_on() {
  export HTTP_PROXY="http://${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT}"
  export HTTPS_PROXY="http://${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT}"
  export http_proxy="$HTTP_PROXY"
  export https_proxy="$HTTPS_PROXY"
  export ALL_PROXY="socks5h://${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT}"
  export all_proxy="$ALL_PROXY"
  export NO_PROXY="localhost,127.0.0.1,::1"
  export no_proxy="$NO_PROXY"
}

proxy_off() {
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
}

dns_tun() {
  /usr/sbin/networksetup -setdnsservers "$CLAUDE_WIFI_SERVICE" 1.1.1.1 8.8.8.8 && \
    echo "${CLAUDE_WIFI_SERVICE} DNS -> 1.1.1.1 8.8.8.8 (routed through TUN)"
}

dns_auto() {
  /usr/sbin/networksetup -setdnsservers "$CLAUDE_WIFI_SERVICE" Empty && \
    echo "${CLAUDE_WIFI_SERVICE} DNS -> Automatic (DHCP)"
}

_v2rayn_active_node_remarks() {
  local cfg="$V2RAYN_CONFIG_DIR/guiNConfig.json"
  local db="$V2RAYN_CONFIG_DIR/guiNDB.db"
  [ -f "$cfg" ] && [ -f "$db" ] || return 1
  local idx
  idx=$(/usr/bin/jq -r '.IndexId // empty' "$cfg" 2>/dev/null)
  [ -n "$idx" ] || return 1
  /usr/bin/sqlite3 -readonly -batch -noheader -list "$db" \
    "SELECT Remarks FROM ProfileItem WHERE IndexId='${idx}' LIMIT 1;" 2>/dev/null | /usr/bin/tr -d '\r\n'
}

_claude_egress_geo() {
  local proxy_url="http://${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT}"
  local raw country tz ip city org
  raw=$(/usr/bin/curl -sS --max-time 6 --proxy "$proxy_url" https://ipinfo.io/json 2>/dev/null || true)
  country=$(printf '%s' "$raw" | /usr/bin/jq -r '.country // empty' 2>/dev/null || true)
  tz=$(printf '%s' "$raw" | /usr/bin/jq -r '.timezone // empty' 2>/dev/null || true)
  ip=$(printf '%s' "$raw" | /usr/bin/jq -r '.ip // empty' 2>/dev/null || true)
  city=$(printf '%s' "$raw" | /usr/bin/jq -r '.city // empty' 2>/dev/null || true)
  org=$(printf '%s' "$raw" | /usr/bin/jq -r '.org // empty' 2>/dev/null || true)

  if [ -z "$country" ] || [ -z "$tz" ]; then
    raw=$(/usr/bin/curl -sS --max-time 6 --proxy "$proxy_url" http://ip-api.com/json/ 2>/dev/null || true)
    country=$(printf '%s' "$raw" | /usr/bin/jq -r '.countryCode // empty' 2>/dev/null || true)
    tz=$(printf '%s' "$raw" | /usr/bin/jq -r '.timezone // empty' 2>/dev/null || true)
    ip=$(printf '%s' "$raw" | /usr/bin/jq -r '.query // empty' 2>/dev/null || true)
    city=$(printf '%s' "$raw" | /usr/bin/jq -r '.city // empty' 2>/dev/null || true)
    org=$(printf '%s' "$raw" | /usr/bin/jq -r '.as // empty' 2>/dev/null || true)
  fi

  [ -n "$country" ] && [ -n "$tz" ] || return 1
  printf '%s|%s|%s|%s|%s\n' "$ip" "$country" "$tz" "$city" "$org"
}

proxy_check() {
  echo "=== 1. Daily Proxy (${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT}) ==="
  if /usr/bin/nc -z -w 2 "$V2RAYN_PROXY_HOST" "$V2RAYN_PROXY_PORT" 2>/dev/null; then
    echo "Daily Port   : ${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT} (OPEN)"
  else
    echo "Daily Port   : ${V2RAYN_PROXY_HOST}:${V2RAYN_PROXY_PORT} (CLOSED)"
  fi
  echo "v2rayN Node  : $(_v2rayn_active_node_remarks || echo UNKNOWN)"
  echo "Shell Proxy  : HTTP=${HTTP_PROXY:-<unset>} | ALL=${ALL_PROXY:-<unset>}"

  echo ""
  echo "=== 2. Claude Dedicated Egress (${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT}) ==="
  if /usr/bin/nc -z -w 2 "$CLAUDE_EGRESS_HOST" "$CLAUDE_EGRESS_PORT" 2>/dev/null; then
    echo "Claude Port  : ${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT} (OPEN)"
    local geo
    if geo=$(_claude_egress_geo); then
      local ip country tz city org
      IFS='|' read -r ip country tz city org <<< "$geo"
      echo "Exit IP      : $ip ($city, $country | $org)"
      echo "Exit TZ      : $tz (Expected: $CLAUDE_EXPECTED_TZ | now: $(TZ="$CLAUDE_EXPECTED_TZ" /bin/date '+%Y-%m-%d %H:%M:%S %Z%z'))"
    else
      echo "Exit Check   : FAILED"
    fi
    echo -n "CN Isolation : "
    /usr/bin/curl -sS --max-time 8 --proxy "http://${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT}" https://myip.ipip.net 2>&1 || true
  else
    echo "Claude Port  : ${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT} (CLOSED!)"
  fi

  echo ""
  echo "=== 3. True Direct IPv6 Leak Check (--noproxy '*') ==="
  local local_v6
  local_v6=$(/sbin/ifconfig | /usr/bin/grep 'inet6 ' | /usr/bin/grep -vE 'fe80::|::1 ' || true)
  echo "Global IPv6  : ${local_v6:-none}"
  local v6_out v6_rc
  v6_out=$(/usr/bin/curl -6 -sS --noproxy '*' --max-time 5 https://api64.ipify.org 2>&1)
  v6_rc=$?
  if [ "$v6_rc" -eq 0 ] && [[ "$v6_out" == *:* ]]; then
    echo "IPv6 Status  : WARNING - direct IPv6 exposed: $v6_out"
  else
    echo "IPv6 Status  : Clean (direct -6 response: ${v6_out:-none}, rc=$v6_rc)"
  fi

  echo ""
  echo "=== 4. System DNS Egress Check ==="
  echo "Wi-Fi DNS    : $(/usr/sbin/networksetup -getdnsservers "$CLAUDE_WIFI_SERVICE" 2>/dev/null | /usr/bin/tr '\n' ' ')"
  echo "Akahelp DNS  : $(/usr/bin/dig +short +time=4 TXT whoami.ds.akahelp.net 2>&1 | /usr/bin/tr '\n' ' ')"
  echo "Google DNS   : $(/usr/bin/dig +short +time=4 TXT o-o.myaddr.l.google.com 2>&1 | /usr/bin/tr '\n' ' ')"
}

proxy_on

# === Claude Code Privacy & Anti-Tracking Env Vars (calibrated for 2.1.x) ===
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
export DISABLE_TELEMETRY="1"
export DISABLE_ERROR_REPORTING="1"
export DISABLE_AUTOUPDATER="1"
export DISABLE_FEEDBACK_COMMAND="1"
export DISABLE_BUG_COMMAND="1"
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY="1"
export CLAUDE_CODE_DISABLE_FEATURE_FLAGS="1"
export DISABLE_GROWTHBOOK="1"
export CLAUDE_CODE_DISABLE_VITALS_EMITTER="1"
export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL="1"
export CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION="1"
export DO_NOT_TRACK="1"

# === Claude Code Fail-Closed Wrapper (auto-healing dedicated egress) ===
claude() {
  local did_heal=0

  if ! /usr/bin/nc -z -w 1 "$CLAUDE_EGRESS_HOST" "$CLAUDE_EGRESS_PORT" 2>/dev/null; then
    if [ "$CLAUDE_EGRESS_PORT" = "10810" ] && [ -x "$HOME/.local/bin/claude-egress-sync" ]; then
      "$HOME/.local/bin/claude-egress-sync" --quiet 2>/dev/null || true
      /bin/sleep 1
      did_heal=1
    fi
  fi
  if ! /usr/bin/nc -z -w 1 "$CLAUDE_EGRESS_HOST" "$CLAUDE_EGRESS_PORT" 2>/dev/null; then
    printf '[Claude Fail-Closed] Dedicated egress %s:%s is not listening.\n' "$CLAUDE_EGRESS_HOST" "$CLAUDE_EGRESS_PORT" >&2
    return 1
  fi

  local geo
  if ! geo=$(_claude_egress_geo); then
    if [ "$did_heal" -eq 0 ] && [ "$CLAUDE_EGRESS_PORT" = "10810" ] && [ -x "$HOME/.local/bin/claude-egress-sync" ]; then
      "$HOME/.local/bin/claude-egress-sync" --quiet 2>/dev/null || true
      /bin/sleep 1
      geo=$(_claude_egress_geo) || true
    fi
  fi
  if [ -z "$geo" ]; then
    printf '[Claude Fail-Closed] Unable to verify live exit IP/timezone via %s:%s.\n' "$CLAUDE_EGRESS_HOST" "$CLAUDE_EGRESS_PORT" >&2
    return 1
  fi

  local ip country tz city org
  IFS='|' read -r ip country tz city org <<< "$geo"
  if [ "$country" != "$CLAUDE_EXPECTED_COUNTRY" ] || [ "$tz" != "$CLAUDE_EXPECTED_TZ" ]; then
    printf '[Claude Fail-Closed] Exit mismatch: %s (%s, %s, TZ=%s); expected %s / TZ=%s.\n' \
      "$ip" "$city" "$country" "$tz" "$CLAUDE_EXPECTED_COUNTRY" "$CLAUDE_EXPECTED_TZ" >&2
    return 1
  fi

  local claude_http="http://${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT}"
  local claude_socks="socks5h://${CLAUDE_EGRESS_HOST}:${CLAUDE_EGRESS_PORT}"
  HTTP_PROXY="$claude_http" \
  HTTPS_PROXY="$claude_http" \
  http_proxy="$claude_http" \
  https_proxy="$claude_http" \
  CLAUDE_CODE_HTTP_PROXY="$claude_http" \
  CLAUDE_CODE_HTTPS_PROXY="$claude_http" \
  ALL_PROXY="$claude_socks" \
  all_proxy="$claude_socks" \
  CLAUDE_CODE_PROXY_RESOLVES_HOSTS="1" \
  NO_PROXY="localhost,127.0.0.1,::1" \
  no_proxy="localhost,127.0.0.1,::1" \
  TZ="$CLAUDE_EXPECTED_TZ" \
  LANG="en_US.UTF-8" \
  LC_ALL="en_US.UTF-8" \
  BROWSER="$HOME/.local/bin/claude-no-open" \
  command claude "$@"
}
