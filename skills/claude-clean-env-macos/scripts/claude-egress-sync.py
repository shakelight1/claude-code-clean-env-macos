#!/usr/bin/env python3
"""
Zero-touch idempotent sync for Claude Code's isolated single-node xray egress (macOS + v2rayN).
Reads the target profile directly from v2rayN's SQLite DB (read-only) by node remarks,
independent of whichever node v2rayN currently has active in its GUI.
Only rewrites xray.json and reloads local.claude-egress when the node config actually changes.

Usage:
  CLAUDE_EGRESS_NODE_REMARKS="US-Residential" ./claude-egress-sync.py [--quiet] [--force]
  ./claude-egress-sync.py --remarks "US-Residential" [--port 10810] [--quiet] [--force]
"""
import argparse
import fcntl
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import quote

HOME = os.path.expanduser("~")
V2RAYN_DB = os.environ.get(
    "V2RAYN_DB_PATH",
    os.path.join(HOME, "Library/Application Support/v2rayN/guiConfigs/guiNDB.db"),
)
XRAY_BIN = os.environ.get(
    "V2RAYN_XRAY_BIN",
    os.path.join(HOME, "Library/Application Support/v2rayN/bin/xray/xray"),
)
OUT_DIR = os.environ.get(
    "CLAUDE_EGRESS_DIR",
    os.path.join(HOME, ".local/share/claude-egress"),
)
OUT_CFG = os.path.join(OUT_DIR, "xray.json")
LOCK_FILE = os.path.join(OUT_DIR, ".sync.lock")
PLIST_LABEL = os.environ.get("CLAUDE_EGRESS_PLIST_LABEL", "local.claude-egress")
PLIST_PATH = os.path.join(HOME, "Library/LaunchAgents", f"{PLIST_LABEL}.plist")
DEFAULT_HOST = os.environ.get("CLAUDE_EGRESS_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("CLAUDE_EGRESS_PORT", "10810"))
BOOTSTRAP_DNS = os.environ.get("CLAUDE_EGRESS_BOOTSTRAP_DNS", "119.29.29.29")


def port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return True
    except OSError:
        return False


def fetch_profile(db_path: str, remarks: str) -> dict:
    uri = f"file:{quote(db_path)}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            """
            SELECT ConfigType, Address, Port, Password, Id, Security, Flow,
                   Network, HeaderType, RequestHost, Path, StreamSecurity,
                   AllowInsecure, Sni, Alpn, Fingerprint, PublicKey, ShortId, SpiderX
            FROM ProfileItem
            WHERE Remarks = ?
            ORDER BY rowid DESC
            LIMIT 1
            """,
            (remarks,),
        ).fetchone()
        if row is None:
            raise RuntimeError(f"Profile '{remarks}' not found in v2rayN DB")
        return dict(row)
    finally:
        conn.close()


def build_proxy_outbound(p: dict, remarks: str) -> tuple[dict, str]:
    cfg_type = p.get("ConfigType")
    addr = (p.get("Address") or "").strip()
    port = int(p.get("Port") or 0)
    if not addr or port <= 0:
        raise RuntimeError(f"Invalid server address/port for '{remarks}'")

    # v2rayN ConfigType: 5 = VLESS
    if cfg_type != 5:
        raise RuntimeError(
            f"Unsupported ConfigType={cfg_type} for '{remarks}' (currently supports 5/VLESS)"
        )

    uuid = (p.get("Password") or p.get("Id") or "").strip()
    if not uuid:
        raise RuntimeError(f"Missing VLESS UUID for '{remarks}'")

    encryption = (p.get("Security") or "").strip() or "none"
    vless_settings = {
        "address": addr,
        "port": port,
        "email": "user@example.com",
        "id": uuid,
        "encryption": encryption,
    }
    flow = (p.get("Flow") or "").strip()
    if flow:
        vless_settings["flow"] = flow

    net = (p.get("Network") or "raw").strip().lower()
    if net == "tcp":
        net = "raw"
    sec = (p.get("StreamSecurity") or "").strip().lower() or "none"
    stream: dict = {"network": net, "security": sec}

    sni = (p.get("Sni") or addr).strip()
    fp = (p.get("Fingerprint") or "").strip()
    alpn_raw = (p.get("Alpn") or "").strip()
    alpn = [x.strip() for x in alpn_raw.split(",") if x.strip()] if alpn_raw else []

    if sec == "tls":
        tls_cfg: dict = {"serverName": sni}
        if alpn:
            tls_cfg["alpn"] = alpn
        if fp:
            tls_cfg["fingerprint"] = fp
        if str(p.get("AllowInsecure") or "").lower() in ("true", "1", "yes"):
            tls_cfg["allowInsecure"] = True
        stream["tlsSettings"] = tls_cfg
    elif sec == "reality":
        reality_cfg: dict = {
            "serverName": sni,
            "publicKey": (p.get("PublicKey") or "").strip(),
            "shortId": (p.get("ShortId") or "").strip(),
        }
        if fp:
            reality_cfg["fingerprint"] = fp
        if (p.get("SpiderX") or "").strip():
            reality_cfg["spiderX"] = p["SpiderX"].strip()
        stream["realitySettings"] = reality_cfg

    if net == "ws":
        ws_cfg: dict = {"path": (p.get("Path") or "/").strip() or "/"}
        if (p.get("RequestHost") or "").strip():
            ws_cfg["host"] = p["RequestHost"].strip()
        stream["wsSettings"] = ws_cfg
    elif net == "grpc":
        grpc_cfg: dict = {"serviceName": (p.get("Path") or "").strip()}
        if (p.get("HeaderType") or "").strip() == "multi":
            grpc_cfg["multiMode"] = True
        stream["grpcSettings"] = grpc_cfg
    elif net == "httpupgrade":
        hu_cfg: dict = {"path": (p.get("Path") or "/").strip() or "/"}
        if (p.get("RequestHost") or "").strip():
            hu_cfg["host"] = p["RequestHost"].strip()
        stream["httpupgradeSettings"] = hu_cfg

    outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": vless_settings,
        "streamSettings": stream,
        "mux": {"enabled": False, "concurrency": -1},
    }
    return outbound, addr


def build_xray_config(outbound: dict, server_addr: str, listen_host: str, listen_port: int) -> dict:
    is_ip = False
    for fam in (socket.AF_INET, socket.AF_INET6):
        try:
            socket.inet_pton(fam, server_addr)
            is_ip = True
            break
        except OSError:
            pass

    cfg: dict = {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "claude-mixed",
                "listen": listen_host,
                "port": listen_port,
                "protocol": "mixed",
                "settings": {"auth": "noauth", "udp": True, "allowTransparent": False},
            }
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "inboundTag": ["claude-mixed"],
                    "port": "443",
                    "network": "udp",
                    "outboundTag": "block",
                },
                {
                    "type": "field",
                    "inboundTag": ["claude-mixed"],
                    "outboundTag": "proxy",
                },
            ],
        },
        "outbounds": [
            outbound,
            {"tag": "block", "protocol": "blackhole"},
            {"tag": "direct", "protocol": "freedom"},
        ],
    }

    if not is_ip:
        cfg["dns"] = {
            "servers": [
                {
                    "address": BOOTSTRAP_DNS,
                    "domains": [f"full:{server_addr}"],
                    "skipFallback": True,
                    "tag": "server-dns",
                }
            ],
            "disableFallback": True,
            "disableFallbackIfMatch": True,
            "tag": "dns-module",
        }
        cfg["routing"]["rules"].insert(
            0,
            {
                "type": "field",
                "inboundTag": ["server-dns"],
                "domain": [f"full:{server_addr}"],
                "outboundTag": "direct",
            },
        )

    return cfg


def reload_launch_agent(quiet: bool) -> None:
    uid = os.getuid()
    target = f"gui/{uid}/{PLIST_LABEL}"
    check = subprocess.run(
        ["/bin/launchctl", "print", target],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if check.returncode == 0:
        subprocess.run(["/bin/launchctl", "kickstart", "-k", target], check=True)
        if not quiet:
            print(f"[claude-egress-sync] Reloaded {PLIST_LABEL}")
    elif os.path.exists(PLIST_PATH):
        subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{uid}", PLIST_PATH], check=True)
        if not quiet:
            print(f"[claude-egress-sync] Bootstrapped {PLIST_LABEL}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Auto-sync Claude dedicated single-node xray egress from v2rayN DB"
    )
    parser.add_argument(
        "--remarks",
        default=os.environ.get("CLAUDE_EGRESS_NODE_REMARKS", ""),
        help="Exact Remarks of the target node in v2rayN (or set CLAUDE_EGRESS_NODE_REMARKS)",
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help="Listen host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Listen port (default: 10810)")
    parser.add_argument("--quiet", action="store_true", help="Suppress output when unchanged")
    parser.add_argument("--force", action="store_true", help="Force rewrite and reload")
    args = parser.parse_args()

    if not args.remarks:
        print(
            "[claude-egress-sync] ERROR: Target node remarks required. "
            "Pass --remarks '<NODE_NAME>' or export CLAUDE_EGRESS_NODE_REMARKS.",
            file=sys.stderr,
        )
        return 1

    os.umask(0o077)
    os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
    os.chmod(OUT_DIR, 0o700)

    if not os.path.exists(V2RAYN_DB):
        print(f"[claude-egress-sync] ERROR: v2rayN DB not found: {V2RAYN_DB}", file=sys.stderr)
        return 1
    if not os.access(XRAY_BIN, os.X_OK):
        print(f"[claude-egress-sync] ERROR: xray binary not found: {XRAY_BIN}", file=sys.stderr)
        return 1

    with open(LOCK_FILE, "w") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)

        profile = fetch_profile(V2RAYN_DB, args.remarks)
        outbound, server_addr = build_proxy_outbound(profile, args.remarks)
        new_cfg = build_xray_config(outbound, server_addr, args.host, args.port)
        new_bytes = (json.dumps(new_cfg, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        new_hash = hashlib.sha256(new_bytes).hexdigest()

        old_hash = None
        if os.path.exists(OUT_CFG):
            with open(OUT_CFG, "rb") as f:
                old_hash = hashlib.sha256(f.read()).hexdigest()

        if not args.force and old_hash == new_hash:
            if not port_open(args.host, args.port):
                reload_launch_agent(args.quiet)
            elif not args.quiet:
                print(
                    f"[claude-egress-sync] Up to date ({args.remarks} -> "
                    f"{server_addr}:{profile['Port']}); no restart needed."
                )
            return 0

        fd, tmp_path = tempfile.mkstemp(prefix=".xray.tmp.", suffix=".json", dir=OUT_DIR)
        try:
            with os.fdopen(fd, "wb") as tf:
                tf.write(new_bytes)
            os.chmod(tmp_path, 0o600)

            test = subprocess.run(
                [XRAY_BIN, "run", "-test", "-c", tmp_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if test.returncode != 0:
                print(
                    f"[claude-egress-sync] ERROR: xray config test failed:\n{test.stdout}",
                    file=sys.stderr,
                )
                return 1

            os.replace(tmp_path, OUT_CFG)
            os.chmod(OUT_CFG, 0o600)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

        if not args.quiet:
            print(
                f"[claude-egress-sync] Synced '{args.remarks}' "
                f"({server_addr}:{profile['Port']}) -> {OUT_CFG} (mode 600)"
            )
        reload_launch_agent(args.quiet)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"[claude-egress-sync] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
