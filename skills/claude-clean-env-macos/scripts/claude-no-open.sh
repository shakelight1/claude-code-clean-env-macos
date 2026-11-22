#!/bin/zsh
# Intercepts OAuth/browser URL opens from Claude Code on macOS so system Safari/Chrome is never launched.
# Copies the URL to the macOS clipboard and prints it to stderr for pasting into an isolated/fingerprint browser.
URL="$1"
if [ -n "$URL" ]; then
  printf '%s' "$URL" | /usr/bin/pbcopy 2>/dev/null || true
  printf '\n[Claude 安全拦截] 已阻止自动唤起系统默认浏览器。\n' >&2
  printf '[Claude 安全拦截] 授权链接已复制到剪贴板，请粘贴至独立/指纹浏览器中打开：\n%s\n\n' "$URL" >&2
fi
exit 0
