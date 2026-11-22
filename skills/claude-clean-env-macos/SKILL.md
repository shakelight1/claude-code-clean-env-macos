---
name: claude-clean-env-macos
description: >-
  General-purpose macOS skill to configure, audit, troubleshoot, and calibrate an isolated,
  leak-resistant environment for Claude Code CLI: dedicated single-node xray egress
  (127.0.0.1:10810) with zero-touch v2rayN DB auto-sync, Fail-Closed launch guard,
  macOS Wi-Fi DNS TUN hijack, target-city IANA timezone & en_US locale alignment,
  OAuth system-browser interception for fingerprint-browser parity, and post-update
  binary privacy calibration. Use whenever a macOS user needs to set up, audit, repair,
  switch nodes for, or upgrade a clean Claude Code CLI environment.
---

# Claude Code 纯净环境配置与审计技能（macOS 通用版）

本 Skill 用于在 **macOS (`zsh`)** 上为 **Claude Code CLI** 搭建、巡检、修复和升级一套**网络隔离、防 IP/DNS/IPv6 泄漏、关闭非必要遥测、与独立指纹浏览器对齐**的纯净运行环境。

> **OPSEC 隔离红线**：本 Skill 仅允许存放在独立于 Claude Code 的本地 AI 助手目录（如 `~/.gemini/config/skills/claude-clean-env-macos/`），**严禁**复制或软链至 `~/.claude/skills/` 或 `~/.agents/skills/`，避免被 Claude Code 扫描进上下文发送至服务端。

---

## 核心架构与红线

1. **三端严格对齐**：`https://claude.ai/cdn-cgi/trace` 实测机房（`colo`）= 独立/指纹浏览器环境 = Claude Code CLI 终端作用域（同一出口 IP、同一 IANA 时区、统一 `en_US.UTF-8`）。
2. **独立单节点出口（避免规则分流泄漏与中途切节点）**：
   - Claude Code 及其派生子进程走独立 `LaunchAgent`（`local.claude-egress`）监听的 **`127.0.0.1:10810`**，仅包含目标节点单一出站、**零国内直连规则**。
   - 若本机使用 v2rayN（`xray` + `sing-box` TUN），复用同路径 `xray` 二进制可天然命中 `sing-box` 的 `process_path -> direct` 规则，不产生套娃代理；并配合 `local.claude-egress-watch`（`WatchPaths` 监听 `guiNDB.db`）实现订阅刷新后的**零手动自动幂等同步**。
   - 若本机使用其他代理软件（Clash/Mihomo/Surge/Sing-box 等），只需为其配置一个“无国内分流直连、锁定目标节点”的独立本地入站端口，并将 `CLAUDE_EGRESS_PORT` 指向该端口即可。
3. **Fail-Closed 熔断**：启动 `claude` 前必须核验专用端口存活 + 实时出口国家与目标 IANA 时区完全匹配（允许自动自愈同步重试一次）；不通过则直接拒绝启动，绝不回落直连。
4. **系统 DNS 防泄漏**：macOS Wi-Fi 默认 DHCP DNS 通常指向路由器内网 IP（如 `192.168.x.1`），会绕过 TUN 导致海外域名查询直发国内运营商。将 Wi-Fi DNS 设为 `1.1.1.1 8.8.8.8` 引入 TUN 劫持后，海外走远程 DoH、国内 `geosite-cn` 仍走国内直连 DNS；提供 `dns_tun` / `dns_auto` 一键切换以兼容裸连和公共认证 Wi-Fi。
5. **OAuth 登录隔离**：通过 `BROWSER="$HOME/.local/bin/claude-no-open"` 拦截 macOS `/usr/bin/open`，阻止唤起系统默认 Safari/Chrome，将授权链接复制到剪贴板，在隔离/指纹浏览器中完成授权。
6. **隐私加固反误区原则**：
   - **禁止**设置 `DISABLE_UPDATES=1`（会锁死手动 `claude update`）；只保留 `DISABLE_AUTOUPDATER=1`。
   - **禁止**设置 `CLAUDE_CODE_ATTRIBUTION_HEADER=0`（去掉标准 `x-anthropic-billing-header` 不增加隐私反而让请求特征异常）。
   - **警惕 Falsy-Value Trap**：`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`、`DISABLE_TELEMETRY`、`DISABLE_ERROR_REPORTING` 在源码中采用非空判断，设 `"0"` 或 `"false"` 同样会生效；不需要时应直接删键。
   - **不要依赖本方案加固 Claude Desktop（Electron 桌面端）**：Electron 外壳不读 `~/.zshrc`，会继承系统代理、系统时区与中文字体指纹；推荐 **终端 / VS Code 集成终端 + 独立指纹浏览器** 组合。
   - 严禁在输出、日志、文档或提交记录中暴露用户的节点 UUID、密码、订阅链接、真实公网 IP 或 Cookie。

---

## 首次部署流程（在全新的 macOS 机器上）

### 第 1 步：只读探测本机环境与目标节点
在修改任何配置前，先向用户确认：
- 目标代理软件（v2rayN 或其他本地混合代理端口）与目标节点备注名（例如 `CLAUDE_EGRESS_NODE_REMARKS="US-Residential"`）；
- 是否需要对齐到独立指纹浏览器，以及是否接受将 Wi-Fi DNS 切至 `1.1.1.1 8.8.8.8`（提供 `dns_auto` 一键回滚）。

随后经目标节点实测真实出口机房与时区（不要轻信单一 MaxMind 站点对广播 IP 回退的 `America/Chicago`）：
```zsh
P="http://127.0.0.1:<PROXY_PORT>"
curl -sS --max-time 10 --proxy "$P" https://claude.ai/cdn-cgi/trace | grep -E '^(ip|loc|colo)='
curl -sS --max-time 10 --proxy "$P" https://ipinfo.io/json | jq '{ip,country,region,city,timezone,org}'
curl -sS --max-time 10 --proxy "$P" http://ip-api.com/json/ | jq '{query,countryCode,regionName,city,timezone,as}'
```
以 `colo` 物理机房代码 + `ipinfo.io` / `ip-api.com` / `ipwho.is` 交叉一致的结果作为 `CLAUDE_EXPECTED_COUNTRY` 与 `CLAUDE_EXPECTED_TZ`。

### 第 2 步：安装脚本与独立出口守护（以 v2rayN 为例）
1. 安装可执行脚本到 `~/.local/bin/`：
   - 复制 [scripts/claude-egress-sync.py](./scripts/claude-egress-sync.py) → `~/.local/bin/claude-egress-sync` (`chmod +x`)
   - 复制 [scripts/claude-no-open.sh](./scripts/claude-no-open.sh) → `~/.local/bin/claude-no-open` (`chmod +x`)
2. 渲染并加载两个 `LaunchAgent`（将模板中的 `__HOME__` 替换为 `$HOME`，`__NODE_REMARKS__` 替换为用户的目标节点名）：
   - [references/templates/local.claude-egress.plist.template](./references/templates/local.claude-egress.plist.template) → `~/Library/LaunchAgents/local.claude-egress.plist`
   - [references/templates/local.claude-egress-watch.plist.template](./references/templates/local.claude-egress-watch.plist.template) → `~/Library/LaunchAgents/local.claude-egress-watch.plist`
3. 首次同步并启动守护进程：
   ```zsh
   CLAUDE_EGRESS_NODE_REMARKS="<NODE_REMARKS>" ~/.local/bin/claude-egress-sync
   UID_NUM=$(id -u)
   launchctl bootstrap "gui/${UID_NUM}" ~/Library/LaunchAgents/local.claude-egress.plist
   launchctl bootstrap "gui/${UID_NUM}" ~/Library/LaunchAgents/local.claude-egress-watch.plist
   ```
   > 提示：若 `~/.config` 归属 `root`，不要强行改权限，脚本默认将配置安全存放在归属本人的 `~/.local/share/claude-egress/xray.json`（目录 `700`、文件 `600`）。

### 第 3 步：配置 Shell、安装 Claude Code 原生稳定版并反向校准
1. 参考 [references/templates/zshrc.snippet.zsh](./references/templates/zshrc.snippet.zsh) 写入或合并 `~/.zshrc`，按第 1 步实测结果填写 `CLAUDE_EGRESS_NODE_REMARKS`、`CLAUDE_EXPECTED_COUNTRY`、`CLAUDE_EXPECTED_TZ`。
2. 如用户同意修复系统 DNS，执行 `networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8`（并确认海外解析器走远程 DoH、国内站点仍走直连 DNS）。
3. 经专用出口安装官方原生稳定版 CLI（无需 Homebrew/Node）：
   ```zsh
   HTTP_PROXY=http://127.0.0.1:10810 HTTPS_PROXY=http://127.0.0.1:10810 \
     curl -fsSL https://claude.ai/install.sh | bash -s stable
   ```
4. 按 [references/architecture.md](./references/architecture.md) 中的二进制审计命令检查已安装版本的实际字段，再参考 [references/templates/settings.json.example](./references/templates/settings.json.example) 校准并写入 `~/.claude/settings.json`。

### 第 4 步：全链路红蓝验收
执行本 Skill 附带的审计脚本（所有预期参数均通过环境变量传入）：
```zsh
CLAUDE_EGRESS_HOST="127.0.0.1" \
CLAUDE_EGRESS_PORT="10810" \
CLAUDE_EXPECTED_COUNTRY="US" \
CLAUDE_EXPECTED_TZ="America/New_York" \
  ./scripts/audit_env.sh
```
补充验证项：
- `claude doctor` 输出 `Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)` 且 `No installation issues found.`；
- `claude auth status` 输出 `"analyticsDisabled": true`；
- `claude update` 可正常联网检查更新；
- 模拟错误时区（`CLAUDE_EXPECTED_TZ="UTC" claude --version`）必须触发熔断返回非 0 退出码；
- 如需最高级别确认，按 [references/architecture.md](./references/architecture.md) 跑一次绕过 wrapper（`env -i`）的抓包 + `lsof` 采样，确认仅连 Anthropic 域名且 0 直连非回环 socket。

---

## 日常运维与故障处置速查

| 场景 | 处置方式 |
| :--- | :--- |
| **一键体检 / 怀疑泄漏** | 运行 `./scripts/audit_env.sh`（传入你的 `CLAUDE_EXPECTED_COUNTRY` 与 `CLAUDE_EXPECTED_TZ`）或终端 `proxy_check`。 |
| **订阅更新后节点更换凭据** | 默认由 `local.claude-egress-watch` 后台自动监听 `guiNDB.db` 无感同步；异常时查看 `~/.local/share/claude-egress/sync.err.log` 并手动跑 `claude-egress-sync`。 |
| **更换目标节点或城市** | 先测 `claude.ai/cdn-cgi/trace` (`colo`) + 多地理库确认新时区 → 更新 `CLAUDE_EGRESS_NODE_REMARKS`、`CLAUDE_EXPECTED_TZ`、`settings.json` `env.TZ` 与 `local.claude-egress-watch.plist` → 重新同步并跑 `audit_env.sh`。 |
| **升级 Claude Code (`claude update`)** | 升级后用 [references/architecture.md](./references/architecture.md) 的扫描脚本审计新版本二进制，检查是否新增遥测/上传开关或变更 `BROWSER` 逻辑，校准 `settings.json` 并运行 `claude doctor`。 |
| **临时关代理裸连 / 连认证 Wi-Fi** | 执行 `dns_auto` 恢复 DHCP；恢复代理后执行 `dns_tun` 并复检 `audit_env.sh`。 |
| **OAuth 账号登录** | 运行 `claude auth login`，将自动复制的链接粘贴至独立/指纹浏览器授权；并在网页端 `claude.ai/settings/data-privacy-controls` 关闭模型训练。 |
