#!/bin/zsh
# Generalized non-destructive red-team leak audit for Claude Code on macOS.
# Parameterized via env vars; redacts domestic IPv4 octets and never prints credentials.
set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
mask_ip() { /usr/bin/sed -E 's/([0-9]{1,3}\.[0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}/\1.x.x/g'; }

EGRESS_HOST="${CLAUDE_EGRESS_HOST:-127.0.0.1}"
EGRESS_PORT="${CLAUDE_EGRESS_PORT:-10810}"
EXPECTED_COUNTRY="${CLAUDE_EXPECTED_COUNTRY:-US}"
EXPECTED_TZ="${CLAUDE_EXPECTED_TZ:-America/New_York}"
WIFI_SERVICE="${CLAUDE_WIFI_SERVICE:-Wi-Fi}"
AUDIT_SAFARIER="${CLAUDE_AUDIT_SAFARIER:-auto}" # auto | 1 | 0

PROXY_URL="http://${EGRESS_HOST}:${EGRESS_PORT}"
SETTINGS="$HOME/.claude/settings.json"
EGRESS_CFG="$HOME/.local/share/claude-egress/xray.json"
SAFARIER_LOG_DIR="$HOME/Library/Application Support/Safarier/logs"

echo "================================================================"
echo " Claude Code Clean-Env Audit ($(/bin/date '+%Y-%m-%d %H:%M:%S %Z'))"
echo " Target: ${EGRESS_HOST}:${EGRESS_PORT} | Expected: ${EXPECTED_COUNTRY} / ${EXPECTED_TZ}"
echo "================================================================"

echo ""
echo "[1/6] Dedicated Isolated Egress (${EGRESS_HOST}:${EGRESS_PORT})"
if [ -f "$EGRESS_CFG" ]; then
  PERM=$(/usr/bin/stat -f '%Lp' "$EGRESS_CFG" 2>/dev/null || echo "?")
  [ "$PERM" = "600" ] && ok "xray.json exists with mode 600" || warn "xray.json mode is $PERM (recommend 600)"
else
  warn "$EGRESS_CFG not found (ignore if using a non-v2rayN dedicated proxy on ${EGRESS_PORT})"
fi

if /bin/launchctl print "gui/$(id -u)/local.claude-egress" >/dev/null 2>&1; then
  ok "LaunchAgent local.claude-egress is loaded"
else
  warn "LaunchAgent local.claude-egress not loaded (ignore if using another proxy daemon)"
fi

if /bin/launchctl print "gui/$(id -u)/local.claude-egress-watch" >/dev/null 2>&1; then
  ok "LaunchAgent local.claude-egress-watch (auto-sync) is loaded"
else
  warn "LaunchAgent local.claude-egress-watch not loaded"
fi

if /usr/bin/nc -z -w 2 "$EGRESS_HOST" "$EGRESS_PORT" 2>/dev/null; then
  ok "Dedicated egress port ${EGRESS_HOST}:${EGRESS_PORT} is OPEN"
else
  fail "Dedicated egress port ${EGRESS_HOST}:${EGRESS_PORT} is CLOSED"
fi

echo ""
echo "[2/6] Live Exit IP, Cloudflare Edge (colo) & Timezone Alignment"
TRACE=$(/usr/bin/curl -sS --max-time 8 --proxy "$PROXY_URL" https://claude.ai/cdn-cgi/trace 2>/dev/null || true)
T_IP=$(printf '%s\n' "$TRACE" | /usr/bin/awk -F= '$1=="ip"{print $2}')
T_LOC=$(printf '%s\n' "$TRACE" | /usr/bin/awk -F= '$1=="loc"{print $2}')
T_COLO=$(printf '%s\n' "$TRACE" | /usr/bin/awk -F= '$1=="colo"{print $2}')
if [ "$T_LOC" = "$EXPECTED_COUNTRY" ] && [ -n "$T_IP" ]; then
  ok "claude.ai trace: ip=${T_IP}, loc=${T_LOC}, colo=${T_COLO}"
else
  fail "claude.ai trace mismatch: ip=${T_IP:-none}, loc=${T_LOC:-none}, colo=${T_COLO:-none} (expected loc=${EXPECTED_COUNTRY})"
fi

GEO=$(/usr/bin/curl -sS --max-time 8 --proxy "$PROXY_URL" https://ipinfo.io/json 2>/dev/null || true)
G_CC=$(printf '%s' "$GEO" | /usr/bin/jq -r '.country // empty' 2>/dev/null || true)
G_TZ=$(printf '%s' "$GEO" | /usr/bin/jq -r '.timezone // empty' 2>/dev/null || true)
G_CITY=$(printf '%s' "$GEO" | /usr/bin/jq -r '.city // empty' 2>/dev/null || true)
G_ORG=$(printf '%s' "$GEO" | /usr/bin/jq -r '.org // empty' 2>/dev/null || true)
if [ "$G_CC" = "$EXPECTED_COUNTRY" ] && [ "$G_TZ" = "$EXPECTED_TZ" ]; then
  ok "ipinfo alignment: ${G_CITY}, ${G_CC} | TZ=${G_TZ} | ${G_ORG}"
else
  fail "ipinfo mismatch: country=${G_CC:-?}, tz=${G_TZ:-?} (expected ${EXPECTED_COUNTRY} / ${EXPECTED_TZ})"
fi

echo ""
echo "[3/6] CN Split-Routing Isolation (CN domains via ${EGRESS_PORT} must NOT exit directly)"
CN_OUT=$(/usr/bin/curl -sS --max-time 8 --proxy "$PROXY_URL" https://myip.ipip.net 2>&1 || true)
if [ -n "$T_IP" ] && printf '%s' "$CN_OUT" | /usr/bin/grep -qF "$T_IP"; then
  ok "myip.ipip.net matches target egress IP (${T_IP}) — zero CN split leak"
elif printf '%s' "$CN_OUT" | /usr/bin/grep -q '中国'; then
  fail "CN split-routing LEAK detected on ${EGRESS_PORT}: $(printf '%s' "$CN_OUT" | mask_ip | /usr/bin/tr -d '\r\n')"
else
  warn "myip.ipip.net check inconclusive: $(printf '%s' "$CN_OUT" | mask_ip | /usr/bin/tr -d '\r\n')"
fi

echo ""
echo "[4/6] True Direct IPv6 & System DNS Egress Checks"
LOCAL_V6=$(/sbin/ifconfig | /usr/bin/grep 'inet6 ' | /usr/bin/grep -vE 'fe80::|::1 ' || true)
[ -z "$LOCAL_V6" ] && ok "No global IPv6 address bound on local interfaces" || warn "Global IPv6 present on interface: $LOCAL_V6"

V6_OUT=$(/usr/bin/curl -6 -sS --noproxy '*' --max-time 5 https://api64.ipify.org 2>&1)
V6_RC=$?
if [ "$V6_RC" -eq 0 ] && [[ "$V6_OUT" == *:* ]]; then
  fail "Direct IPv6 leak detected (--noproxy '*'): $V6_OUT"
else
  ok "Direct IPv6 clean (--noproxy '*' -> ${V6_OUT:-none}, rc=${V6_RC})"
fi

WIFI_DNS=$(/usr/sbin/networksetup -getdnsservers "$WIFI_SERVICE" 2>/dev/null | /usr/bin/tr '\n' ' ')
if printf '%s' "$WIFI_DNS" | /usr/bin/grep -qE '1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9'; then
  ok "${WIFI_SERVICE} DNS routed into TUN: $WIFI_DNS"
else
  warn "${WIFI_SERVICE} DNS is not public (${WIFI_DNS}) — LAN router DNS may bypass TUN (run dns_tun to fix)"
fi

AKA_DNS=$(/usr/bin/dig +short +time=4 TXT whoami.ds.akahelp.net 2>&1 | /usr/bin/tr '\n' ' ')
GOOG_DNS=$(/usr/bin/dig +short +time=4 TXT o-o.myaddr.l.google.com 2>&1 | /usr/bin/tr '\n' ' ')
echo "  [INFO] Overseas DNS (akahelp): $(printf '%s' "$AKA_DNS" | mask_ip)"
echo "  [INFO] Overseas DNS (google) : $(printf '%s' "$GOOG_DNS" | mask_ip)"
if printf '%s' "$GOOG_DNS" | /usr/bin/grep -qE '2400:cb00|172\.68\.|172\.69\.|172\.70\.|162\.158\.|104\.|74\.125\.'; then
  ok "Overseas DNS resolver is remote (Cloudflare/Google DoH)"
else
  warn "Verify overseas DNS resolver IP is NOT your local domestic ISP"
fi

echo ""
echo "[5/6] Claude Code Settings & Privacy Guardrails"
if [ -f "$SETTINGS" ] && /usr/bin/jq . "$SETTINGS" >/dev/null 2>&1; then
  ok "settings.json is valid JSON"
  S_PROXY=$(/usr/bin/jq -r '.env.HTTPS_PROXY // empty' "$SETTINGS")
  S_ALL=$(/usr/bin/jq -r '.env.ALL_PROXY // empty' "$SETTINGS")
  S_TZ=$(/usr/bin/jq -r '.env.TZ // empty' "$SETTINGS")
  S_NE=$(/usr/bin/jq -r '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC // empty' "$SETTINGS")
  S_AU=$(/usr/bin/jq -r '.env.DISABLE_AUTOUPDATER // empty' "$SETTINGS")
  S_BAD_UPD=$(/usr/bin/jq -r '.env.DISABLE_UPDATES // empty' "$SETTINGS")
  S_BAD_ATTR=$(/usr/bin/jq -r '.env.CLAUDE_CODE_ATTRIBUTION_HEADER // empty' "$SETTINGS")

  [ "$S_PROXY" = "$PROXY_URL" ] && ok "settings.json HTTPS_PROXY=${S_PROXY}" || fail "settings.json HTTPS_PROXY=${S_PROXY:-unset} (expected ${PROXY_URL})"
  [ "$S_ALL" = "socks5h://${EGRESS_HOST}:${EGRESS_PORT}" ] && ok "settings.json ALL_PROXY=${S_ALL}" || warn "settings.json ALL_PROXY=${S_ALL:-unset}"
  [ "$S_TZ" = "$EXPECTED_TZ" ] && ok "settings.json TZ=${S_TZ}" || fail "settings.json TZ=${S_TZ:-unset} (expected ${EXPECTED_TZ})"
  [ -n "$S_NE" ] && [ -n "$S_AU" ] && ok "Non-essential traffic & background auto-updater disabled" || fail "Missing CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC or DISABLE_AUTOUPDATER"
  [ -z "$S_BAD_UPD" ] && ok "DISABLE_UPDATES not set (manual claude update preserved)" || fail "DISABLE_UPDATES=${S_BAD_UPD} blocks manual claude update"
  [ -z "$S_BAD_ATTR" ] && ok "CLAUDE_CODE_ATTRIBUTION_HEADER not stripped" || warn "CLAUDE_CODE_ATTRIBUTION_HEADER=${S_BAD_ATTR} (over-hardening; recommend removing)"
else
  fail "$SETTINGS missing or invalid JSON"
fi

[ -x "$HOME/.local/bin/claude-no-open" ] && ok "OAuth browser interceptor ~/.local/bin/claude-no-open is executable" || warn "Missing executable ~/.local/bin/claude-no-open"

# OPSEC self-check: ensure this clean-env skill is NOT placed where Claude Code scans it
if [ -e "$HOME/.claude/skills/claude-clean-env" ] || [ -e "$HOME/.claude/skills/claude-clean-env-macos" ] || \
   [ -e "$HOME/.agents/skills/claude-clean-env" ] || [ -e "$HOME/.agents/skills/claude-clean-env-macos" ]; then
  fail "OPSEC RISK: clean-env skill detected inside ~/.claude/skills or ~/.agents/skills (remove it!)"
else
  ok "OPSEC clean: skill is not exposed in ~/.claude/skills or ~/.agents/skills"
fi

if [ -x "$HOME/.local/bin/claude" ]; then
  VER=$("$HOME/.local/bin/claude" --version 2>/dev/null | /usr/bin/head -n 1)
  ok "Claude Code CLI installed: ${VER:-unknown}"
else
  fail "Claude Code CLI not found at ~/.local/bin/claude"
fi

echo ""
echo "[6/6] Fingerprint Browser Parity (Optional Safarier Check)"
if [ "$AUDIT_SAFARIER" = "0" ]; then
  echo "  [INFO] Skipped (CLAUDE_AUDIT_SAFARIER=0)"
elif [ -d "$SAFARIER_LOG_DIR" ]; then
  LATEST_SF_LOG=$(/bin/ls -t "$SAFARIER_LOG_DIR"/*.log 2>/dev/null | /usr/bin/head -n 1 || true)
  if [ -n "$LATEST_SF_LOG" ]; then
    SF_TZ=$(/usr/bin/grep 'processPool.timeZone =' "$LATEST_SF_LOG" | /usr/bin/tail -n 1 | /usr/bin/sed -E 's/.*processPool\.timeZone = ([^,]+).*/\1/')
    SF_WRTC=$(/usr/bin/grep 'peerConnection = ' "$LATEST_SF_LOG" | /usr/bin/tail -n 1)
    [ "$SF_TZ" = "$EXPECTED_TZ" ] && ok "Safarier timezone matches: ${SF_TZ}" || warn "Safarier timezone=${SF_TZ:-unknown} (expected ${EXPECTED_TZ})"
    printf '%s' "$SF_WRTC" | /usr/bin/grep -q 'NO' && ok "Safarier WebRTC disabled (peerConnection = NO)" || warn "Safarier WebRTC status unverified"
  else
    echo "  [INFO] No Safarier logs found yet"
  fi
else
  echo "  [INFO] Safarier not installed — manually verify your fingerprint browser timezone matches ${EXPECTED_TZ}"
fi

echo ""
echo "================================================================"
echo " Summary: PASS=${PASS} | WARN=${WARN} | FAIL=${FAIL}"
echo "================================================================"
[ "$FAIL" -eq 0 ]
