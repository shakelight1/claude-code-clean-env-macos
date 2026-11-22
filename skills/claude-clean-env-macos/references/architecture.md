# 架构原理、二进制隐私校准与避坑清单（macOS 通用参考）

## 1. 为什么要做独立单节点出口（`10810`）而不是共用规则分流口（`10808`）？

1. **阻断国内分流暴露真实 IP**：日常代理软件的默认端口通常启用 `geosite:cn` / `geoip:cn` 直连。当 Claude Code 调用 Bash 工具或 `WebFetch` 访问国内镜像或服务时，请求会以本机真实宽带 IP 出网；若命令输出回显了本机 IP，该 IP 甚至会随对话上下文上传至服务端。独立单节点出口无任何直连规则，所有流量均从目标节点出网。
2. **防止会话中途切节点污染**：仅在启动时检查代理节点无法防护会话运行期间在 GUI 切节点。独立 `xray` 守护进程与 GUI 选中的节点完全解耦，日常随便切换节点也不会影响正在运行的 Claude Code。
3. **不产生二次套娃代理**：在 v2rayN（`xray` + `sing-box` TUN）架构下，复用同一路径的 `xray` 二进制可命中 `sing-box` 的 `process_path -> direct` 防回环规则，直连目标节点服务器，不经当前 GUI 激活节点转发。
4. **零手动无感同步**：`local.claude-egress-watch` 使用 macOS `LaunchAgent` `WatchPaths` 监听 `v2rayN/guiConfigs/guiNDB.db`，直接按备注名只读读取目标节点并做 SHA-256 幂等比对；只有节点凭据真正变动时才经 `xray run -test` 检验并热重载，绝不打断运行中的会话。

---

## 2. 系统 DNS 泄漏原理与 TUN 劫持修复

- **泄漏原因**：macOS Wi-Fi 通过 DHCP 拿到的 DNS 通常是路由器内网地址（如 `192.168.x.1`）。因为内网网段直连物理网卡 `en0`，UDP/53 查询绕过 TUN 虚拟网卡，被路由器直接发往本地运营商 DNS。
- **修复方式**：`networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8` 将 DNS 数据包引入 TUN，由 `sing-box` 的 `hijack-dns` 接管：海外域名走代理端远程 DoH，国内 `geosite-cn` 仍走国内直连 DNS，不影响日常国内访问速度。
- **回滚兼容**：关闭代理裸连或接入需要网页认证（Captive Portal）的公共 Wi-Fi 时，执行 `dns_auto`（`networksetup -setdnsservers Wi-Fi Empty`）一键恢复 DHCP；恢复代理后执行 `dns_tun`。

---

## 3. Claude Code 2.1.x 二进制隐私审计基线

### 推荐 `settings.json` 顶层字段
- `"autoUpdatesChannel": "stable"` — 锁定稳定发布通道
- `"skipWebFetchPreflight": true` — 禁用 `WebFetch` 前向 `api.anthropic.com` 发送目标主机名的预检
- `"autoUploadSessions": false` — 禁止本地会话自动镜像上传至 `claude.ai`
- `"remoteControlAtStartup": false` — 禁止启动时自动开启 Remote Control 桥接
- `"feedbackSurveyRate": 0` — 会话质量调研弹出概率归零
- `"feedbackDrafts": "off"` — 完全禁用模型自动起草反馈的 `SendFeedback` 工具
- `"attribution": { "commit": "", "pr": "", "sessionUrl": false }` — 替代已废弃的 `includeCoAuthoredBy`，隐藏 Git Commit/PR 及会话链接标记

### 推荐 `env` 环境变量
- 隐私防追踪：
  - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"`
  - `DISABLE_TELEMETRY="1"`
  - `DISABLE_ERROR_REPORTING="1"`
  - `DISABLE_AUTOUPDATER="1"`（仅关后台自动更新，保留手动 `claude update`）
  - `DISABLE_FEEDBACK_COMMAND="1"` / `DISABLE_BUG_COMMAND="1"`
  - `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY="1"`
  - `CLAUDE_CODE_DISABLE_FEATURE_FLAGS="1"` / `DISABLE_GROWTHBOOK="1"`
  - `CLAUDE_CODE_DISABLE_VITALS_EMITTER="1"`
  - `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL="1"`
  - `CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION="1"`
  - `DO_NOT_TRACK="1"`
- 代理与时区：
  - `HTTP_PROXY` / `HTTPS_PROXY` / `http_proxy` / `https_proxy` / `CLAUDE_CODE_HTTP_PROXY` / `CLAUDE_CODE_HTTPS_PROXY` = `"http://127.0.0.1:10810"`
  - `ALL_PROXY` / `all_proxy` = `"socks5h://127.0.0.1:10810"`
  - `CLAUDE_CODE_PROXY_RESOLVES_HOSTS="1"`
  - `NO_PROXY` / `no_proxy` = `"localhost,127.0.0.1,::1"`
  - `TZ="<TARGET_IANA_TIMEZONE>"`（例如 `America/New_York`）、`LANG="en_US.UTF-8"`、`LC_ALL="en_US.UTF-8"`

---

## 4. 红蓝对抗避坑对照表

| 常见错误 | 实际后果 | 正确做法 |
| :--- | :--- | :--- |
| 设置 `DISABLE_UPDATES="1"` | 源码直接拦截 `claude update` 并退出 | 删除，仅保留 `DISABLE_AUTOUPDATER="1"` |
| 设置 `CLAUDE_CODE_ATTRIBUTION_HEADER="0"` | 去掉标准计费版本头 `x-anthropic-billing-header`，不增隐私反让请求形态异常 | 删除 |
| 对 `DISABLE_*` 设 `"0"` 或 `"false"` | 多个开关采用 raw truthy 判真（非空即真），写 `"0"` 反而启用禁用 | 不需要时直接删除键名 |
| 用未加 `--noproxy '*'` 的 `curl -6` 测 IPv6 | 请求走了 `ALL_PROXY`，测试结果失真 | 必须使用 `curl -6 --noproxy '*'` |
| 用 `whoami.akamai.net` 测海外 DNS 泄漏 | `akamai.net` 常命中 `geosite-cn` 走国内 DNS 产生误报 | 使用 `whoami.ds.akahelp.net` 与 `o-o.myaddr.l.google.com` |
| 盲信单一 MaxMind 站点返回 `America/Chicago` | 广播 IP 缺少城市信息时回退美国几何中心默认时区 | 以 `claude.ai/cdn-cgi/trace` 的 `colo` + `ipinfo`/`ip-api`/`ipwho.is` 交叉为准 |
| 把本 Skill 放入 `~/.claude/skills` 或 `~/.agents/skills` | Claude Code 会把 Skill 名称/描述读进上下文发给服务端 | 仅放在独立的本地 AI 助手目录（如 `~/.gemini/config/skills/`） |
| 依赖本方案保护 Claude Desktop（Electron 桌面端） | 桌面端外壳不读 `~/.zshrc`，走系统代理、系统时区与本机中文字体指纹 | 推荐 **终端 / VS Code 集成终端 + 独立指纹浏览器** 组合 |

---

## 5. Claude Code 升级后的快速二进制审计脚本

升级到新版本后，直接扫描已安装的原生二进制，确认是否有新增遥测/上传/反馈开关以及 `BROWSER` 拦截机制是否依然有效：

```zsh
python3 - <<'PY'
import os, re
bin_path = os.path.realpath(os.path.expanduser("~/.local/bin/claude"))
print("Binary:", bin_path)
data = open(bin_path, "rb").read()
js = data[max(0, len(data) - 120_000_000):]
for label, pat in [
    ("DISABLE_*", rb'DISABLE_[A-Z0-9_]{3,60}'),
    ("CLAUDE_CODE_DISABLE_*", rb'CLAUDE_CODE_DISABLE_[A-Z0-9_]{3,60}'),
]:
    hits = sorted(set(m.decode() for m in re.findall(pat, data)))
    print(f"\n=== {label} ({len(hits)}) ===")
    for h in hits:
        if any(k in h for k in ("TELEM","ERROR","UPDATE","FEEDBACK","SURVEY","GROWTH","FEATURE","VITALS","SYNC","UPLOAD","REMOTE","TRACK","ATTRIB","MARKET","NONESS","REPORT","CLOUD")):
            print(" ", h)
print("\n=== BROWSER handler present ===", js.find(b'i.BROWSER') != -1)
PY
```

## 6. 绕过 Wrapper 的抓包复测思路（最高级别验收）

如需验证即使绕过 `~/.zshrc` 的 `claude()` 封装（仅靠 `~/.claude/settings.json`）也无直连或遥测泄漏：
1. 在本地临时起一个最小 HTTP CONNECT 转发日志代理（监听 `127.0.0.1:18081` → 转发至 `127.0.0.1:10810`，记录所有 `CONNECT host:port`）；
2. 在临时 `CLAUDE_CONFIG_DIR` 拷贝 `settings.json` 并将代理指向 `18081`；
3. 使用 `env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=xterm-256color CLAUDE_CONFIG_DIR=<tmp> script -q /dev/null ~/.local/bin/claude` 运行 12 秒，期间每 0.3 秒对进程树采样 `lsof -nP -a -p <pid> -i` 过滤非回环地址；
4. 合格标准：代理日志仅见 `api.anthropic.com:443` / `platform.claude.com:443`，**0 个直连非回环 socket**，**0 个第三方遥测域名**。
