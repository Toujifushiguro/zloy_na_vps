#!/usr/bin/env python3
"""
Unified VPN manager for multiple protocols.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from vpn_protocols.amneziawg import AmneziaWGManager
from vpn_protocols.openvpn import OpenVPNManager
from vpn_protocols.outline import OutlineManager
from vpn_protocols.xray_reality import XrayRealityManager
from vpn_protocols.shared import require_root, sanitize_client_name
from vpn_protocols.telegram_bot import TelegramBotManager

TELEGRAM_PID_FILE = Path(__file__).resolve().parent / "telegram_bot.pid"
TELEGRAM_LOG_FILE = Path(__file__).resolve().parent / "telegram_bot.log"
INVENTORY_FILE = "servers.json"

LOCAL_PROTOCOL_CHOICES = ["amneziawg", "openvpn", "outline", "xray"]
LOCAL_ACTION_CHOICES = [
    "install",
    "uninstall",
    "list-clients",
    "create-client",
    "delete-client",
    "rename-client",
    "update-server",
    "update-client",
    "show-client-config-path",
]
SERVER_ACTION_CHOICES = ["list", "check"]
BACKEND_ACTION_CHOICES = ["ping", "ensure-autostart"]


@dataclass(frozen=True)
class ServerNode:
    name: str
    host: str
    port: int
    user: str
    country: str
    ssh_key_path: str
    password: str
    manager_path: str
    enabled: bool


class _C:
    BOLD = "\033[1m"
    DIM = "\033[2m"
    CYAN = "\033[96m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    RESET = "\033[0m"


def _color(text: str, code: str) -> str:
    return f"{code}{text}{_C.RESET}"


def _inventory_error(index: int, message: str) -> RuntimeError:
    return RuntimeError(f"Invalid inventory entry #{index}: {message}")


def _inventory_str(
    raw: dict[str, object],
    key: str,
    index: int,
    *,
    required: bool = True,
) -> str:
    value = raw.get(key)
    if value is None:
        if required:
            raise _inventory_error(index, f"'{key}' is required")
        return ""
    if not isinstance(value, str):
        raise _inventory_error(index, f"'{key}' must be a string")
    text = value.strip()
    if required and not text:
        raise _inventory_error(index, f"'{key}' must not be empty")
    return text


def _inventory_int(raw: dict[str, object], key: str, index: int, *, default: int) -> int:
    value = raw.get(key, default)
    if isinstance(value, bool):
        raise _inventory_error(index, f"'{key}' must be an integer")
    if isinstance(value, int):
        port = value
    elif isinstance(value, str) and value.strip().isdigit():
        port = int(value.strip())
    else:
        raise _inventory_error(index, f"'{key}' must be an integer")
    if port < 1 or port > 65535:
        raise _inventory_error(index, f"'{key}' must be in range 1..65535")
    return port


def _inventory_bool(raw: dict[str, object], key: str, index: int, *, default: bool) -> bool:
    value = raw.get(key, default)
    if isinstance(value, bool):
        return value
    raise _inventory_error(index, f"'{key}' must be boolean true/false")


def _default_manager_path(user: str) -> str:
    return f"/home/{user}/vpn-unified-manager/vpn_manager.py"


def load_inventory(inventory_path: Path) -> list[ServerNode]:
    if not inventory_path.exists():
        raise RuntimeError(f"Inventory file not found: {inventory_path}")
    try:
        payload = json.loads(inventory_path.read_text())
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in inventory '{inventory_path}': {exc}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Inventory '{inventory_path}' must be a JSON object with 'servers'.")
    raw_servers = payload.get("servers")
    if not isinstance(raw_servers, list):
        raise RuntimeError(f"Inventory '{inventory_path}' must contain array field 'servers'.")
    nodes: list[ServerNode] = []
    seen_names: set[str] = set()
    for idx, raw in enumerate(raw_servers, start=1):
        if not isinstance(raw, dict):
            raise _inventory_error(idx, "entry must be an object")
        name = _inventory_str(raw, "name", idx)
        country = _inventory_str(raw, "country", idx, required=False)
        host = _inventory_str(raw, "host", idx)
        user = _inventory_str(raw, "user", idx)
        ssh_key_raw = _inventory_str(raw, "ssh_key_path", idx, required=False)
        password = _inventory_str(raw, "password", idx, required=False)
        port = _inventory_int(raw, "port", idx, default=22)
        enabled = _inventory_bool(raw, "enabled", idx, default=True)
        manager_path = _inventory_str(raw, "manager_path", idx, required=False) or _default_manager_path(user)
        if name in seen_names:
            raise _inventory_error(idx, f"duplicate server name '{name}'")
        seen_names.add(name)
        ssh_key_path = str(Path(ssh_key_raw).expanduser()) if ssh_key_raw else ""
        if enabled and not ssh_key_path and not password:
            raise _inventory_error(idx, "set at least one auth method: ssh_key_path or password")
        if enabled and ssh_key_path and not password and not Path(ssh_key_path).exists():
            raise _inventory_error(idx, f"ssh key not found: {ssh_key_path}")
        nodes.append(
            ServerNode(
                name=name,
                host=host,
                port=port,
                user=user,
                country=country,
                ssh_key_path=ssh_key_path,
                password=password,
                manager_path=manager_path,
                enabled=enabled,
            )
        )
    return nodes


def _inventory_by_name(nodes: list[ServerNode]) -> dict[str, ServerNode]:
    return {node.name: node for node in nodes}


def _is_auth_error(text: str) -> bool:
    lowered = text.lower()
    return "permission denied" in lowered or "authentication failed" in lowered or "publickey" in lowered


def _extract_remote_error(payload: object) -> str | None:
    if not isinstance(payload, dict):
        return None
    err = payload.get("error")
    if isinstance(err, str) and err:
        return err
    return None


def run_remote_manager(
    node: ServerNode,
    protocol: str,
    action: str,
    action_args: list[str],
    timeout_seconds: int,
) -> dict[str, object]:
    remote_parts = ["sudo", "-n", "python3", node.manager_path, protocol, action, *action_args, "--json"]
    remote_cmd = " ".join(shlex.quote(part) for part in remote_parts)
    ssh_base = [
        "-p",
        str(node.port),
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"ConnectTimeout={max(1, min(timeout_seconds, 30))}",
        f"{node.user}@{node.host}",
        remote_cmd,
    ]
    if node.password:
        if shutil.which("sshpass") is None:
            return {
                "ok": False,
                "error_type": "auth_error",
                "error": "sshpass is required for password auth (install: apt-get install sshpass).",
            }
        ssh_cmd = [
            "sshpass",
            "-p",
            node.password,
            "ssh",
            "-o",
            "PreferredAuthentications=password",
            *ssh_base,
        ]
    elif node.ssh_key_path:
        ssh_cmd = [
            "ssh",
            "-i",
            node.ssh_key_path,
            "-o",
            "BatchMode=yes",
            *ssh_base,
        ]
    else:
        return {"ok": False, "error_type": "auth_error", "error": "No SSH auth configured for this node."}
    try:
        completed = subprocess.run(ssh_cmd, text=True, capture_output=True, timeout=max(1, timeout_seconds))
    except subprocess.TimeoutExpired:
        return {"ok": False, "error_type": "timeout", "error": "SSH command timed out."}
    stderr = completed.stderr.strip()
    stdout = completed.stdout.strip()
    parsed: object | None = None
    if stdout:
        try:
            parsed = json.loads(stdout)
        except json.JSONDecodeError:
            parsed = None
    if completed.returncode != 0:
        remote_error = _extract_remote_error(parsed)
        if _is_auth_error(stderr):
            return {"ok": False, "error_type": "auth_error", "error": stderr or "SSH authentication failed."}
        if remote_error:
            return {"ok": False, "error_type": "remote_error", "error": remote_error}
        details = stderr or stdout or "Remote command failed."
        return {"ok": False, "error_type": "command_fail", "error": details}
    if not isinstance(parsed, dict):
        return {"ok": False, "error_type": "invalid_json", "error": "Remote backend returned invalid JSON."}
    if parsed.get("ok") is False:
        remote_error = _extract_remote_error(parsed) or "Remote backend returned an error."
        return {"ok": False, "error_type": "remote_error", "error": remote_error}
    return {"ok": True, "result": parsed.get("result")}


def _extract_config_path(action: str, result: object) -> str | None:
    if action == "show-client-config-path":
        if isinstance(result, str):
            return result
        if isinstance(result, dict):
            path = result.get("path")
            if isinstance(path, str):
                return path
    if action == "create-client" and isinstance(result, dict):
        config = result.get("config")
        if isinstance(config, str):
            return config
    return None


def _build_action_cli_args(
    name: str | None,
    new_name: str | None,
    set_items: list[str],
    host: str | None,
    port: str | None,
    proto: str | None,
) -> list[str]:
    items: list[str] = []
    if name:
        items.extend(["--name", name])
    if new_name:
        items.extend(["--new-name", new_name])
    if host:
        items.extend(["--host", host])
    if port:
        items.extend(["--port", port])
    if proto:
        items.extend(["--proto", proto])
    for entry in set_items:
        items.extend(["--set", entry])
    return items


def _count_summary(local_result: dict[str, object] | None, nodes_result: dict[str, dict[str, object]]) -> dict[str, int]:
    total = len(nodes_result)
    ok = sum(1 for node_result in nodes_result.values() if node_result.get("ok") is True)
    if local_result is not None:
        total += 1
        if local_result.get("ok") is True:
            ok += 1
    failed = total - ok
    return {"total": total, "ok": ok, "failed": failed}


def _telegram_is_running() -> bool:
    try:
        pid = int(TELEGRAM_PID_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _telegram_stop_background() -> tuple[bool, str | None]:
    try:
        pid = int(TELEGRAM_PID_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return False, "Bot is not running."
    try:
        os.kill(pid, signal.SIGTERM)
    except PermissionError:
        return False, "No permission to stop bot."
    except ProcessLookupError:
        pass
    TELEGRAM_PID_FILE.unlink(missing_ok=True)
    return True, None


def _telegram_start_background(repo_root: Path, bot: TelegramBotManager) -> tuple[bool, str | None]:
    if _telegram_is_running():
        return False, "Bot is already running."
    status = bot.status()
    if not status["token_configured"] or not (status["allowed_user_id"] or status.get("allowed_users")):
        return False, "Set token and allowed users first."
    TELEGRAM_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    start_line = f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}] starting telegram bot\n"
    try:
        with TELEGRAM_LOG_FILE.open("ab") as log_file:
            log_file.write(start_line.encode())
            proc = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "--telegram-bot"],
                stdin=subprocess.DEVNULL,
                stdout=log_file,
                stderr=log_file,
                start_new_session=True,
                cwd=str(repo_root),
            )
        TELEGRAM_PID_FILE.parent.mkdir(parents=True, exist_ok=True)
        TELEGRAM_PID_FILE.write_text(str(proc.pid))
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    return True, None


def parse_key_values(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in values:
        if "=" not in item:
            raise ValueError(f"Invalid --set item '{item}'. Use KEY=VALUE format.")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"Invalid --set item '{item}'. Empty key.")
        result[key] = value.strip()
    return result


def get_manager(protocol: str, repo_root: Path):
    if protocol == "amneziawg":
        return AmneziaWGManager(repo_root=repo_root)
    if protocol == "openvpn":
        return OpenVPNManager(repo_root=repo_root)
    if protocol == "outline":
        return OutlineManager(repo_root=repo_root)
    if protocol == "xray":
        return XrayRealityManager(repo_root=repo_root)
    raise ValueError(f"Unsupported protocol: {protocol}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vpn-manager",
        description="Unified server-side manager for VPN protocols.",
    )
    parser.add_argument("protocol", nargs="?", help="VPN protocol or control-plane command.")
    parser.add_argument("action", nargs="?", help="Action or first command argument.")
    parser.add_argument("extra", nargs="*", help="Extra positional args for control-plane commands.")
    parser.add_argument("--name", help="Client name.")
    parser.add_argument("--new-name", help="New client name for rename-client.")
    parser.add_argument("--host", help="Remote host for OpenVPN client config.")
    parser.add_argument("--port", help="Remote port for OpenVPN client config.")
    parser.add_argument("--proto", choices=["udp", "tcp"], help="Protocol for OpenVPN client config.")
    parser.add_argument("--all", action="store_true", help="Apply operation to all enabled servers.")
    parser.add_argument(
        "--inventory",
        default=INVENTORY_FILE,
        help=f"Path to inventory JSON (default: {INVENTORY_FILE}).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Timeout in seconds for SSH remote commands.",
    )
    parser.add_argument(
        "--set",
        dest="set_items",
        action="append",
        default=[],
        help="Set key/value pair in KEY=VALUE format. Can be used multiple times.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print output as JSON when possible.",
    )
    parser.add_argument(
        "--telegram-bot",
        action="store_true",
        help="Run Telegram bot (polling mode).",
    )
    parser.add_argument("--telegram-token", help="Configure Telegram bot token.")
    parser.add_argument("--telegram-chat-id", help="Restrict Telegram bot to chat_id.")
    parser.add_argument("--telegram-allowed-user-id", help="Restrict Telegram bot to user ID (digits).")
    parser.add_argument(
        "--telegram-test-message",
        help="Send a test message via the configured Telegram bot.",
    )
    parser.add_argument(
        "--telegram-once",
        action="store_true",
        help="Process one Telegram polling cycle and exit.",
    )
    return parser


def print_result(result, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=True, indent=2))
        return
    if isinstance(result, dict) and "servers" in result and isinstance(result.get("servers"), list):
        summary = result.get("summary")
        if isinstance(summary, dict):
            print(f"servers: total={summary.get('total', 0)} enabled={summary.get('enabled', 0)}")
        for item in result["servers"]:
            if not isinstance(item, dict):
                print(item)
                continue
            enabled_mark = "enabled" if item.get("enabled") else "disabled"
            country = item.get("country") or "-"
            auth_method = item.get("auth_method") or "ssh-key"
            auth_label = f"auth={auth_method}"
            if auth_method == "ssh-key":
                auth_label = f"{auth_label} key={item.get('ssh_key_path')}"
            print(
                f"{item.get('name')} ({country}): {item.get('user')}@{item.get('host')}:{item.get('port')} "
                f"[{enabled_mark}] {auth_label} manager={item.get('manager_path')}"
            )
        return
    if isinstance(result, dict) and "nodes" in result and isinstance(result.get("nodes"), dict):
        summary = result.get("summary")
        if isinstance(summary, dict):
            print(
                f"{result.get('mode', 'remote')}: total={summary.get('total', 0)} "
                f"ok={summary.get('ok', 0)} failed={summary.get('failed', 0)}"
            )
        local = result.get("local")
        if isinstance(local, dict):
            if local.get("ok") is True:
                print(f"local: ok ({result.get('protocol')} {result.get('action')})")
            else:
                print(f"local: failed ({local.get('error_type', 'error')}) {local.get('error')}")
        nodes = result["nodes"]
        for node_name, node_result in nodes.items():
            if not isinstance(node_result, dict):
                print(f"{node_name}: {node_result}")
                continue
            if node_result.get("ok") is True:
                extra = ""
                config_path = node_result.get("config_path")
                if isinstance(config_path, str):
                    extra = f" config_path={config_path}"
                print(f"{node_name}: ok{extra}")
            else:
                print(
                    f"{node_name}: failed ({node_result.get('error_type', 'error')}) "
                    f"{node_result.get('error')}"
                )
        return
    if isinstance(result, list):
        if result:
            for item in result:
                print(item)
        else:
            print("No clients.")
    elif isinstance(result, dict):
        for key, value in result.items():
            print(f"{key}: {value}")
    else:
        print(result)


def execute_action(
    manager,
    action: str,
    name: str | None,
    new_name: str | None,
    set_items: list[str],
    host: str | None = None,
    port: str | None = None,
    proto: str | None = None,
    parser=None,
):
    if action == "install":
        return manager.install()
    if action == "uninstall":
        return manager.uninstall()
    if action == "list-clients":
        return manager.list_clients()
    if action == "create-client":
        if not name:
            if parser:
                parser.error("--name is required for create-client")
            raise ValueError("name is required for create-client")
        if port is not None and not port.isdigit():
            if parser:
                parser.error("--port must be numeric")
            raise ValueError("port must be numeric")
        if isinstance(manager, OpenVPNManager):
            return manager.create_client(
                sanitize_client_name(name),
                remote_host=host,
                remote_port=port,
                proto=proto,
            )
        return manager.create_client(sanitize_client_name(name))
    if action == "delete-client":
        if not name:
            if parser:
                parser.error("--name is required for delete-client")
            raise ValueError("name is required for delete-client")
        return manager.delete_client(sanitize_client_name(name))
    if action == "rename-client":
        if not name or not new_name:
            if parser:
                parser.error("--name and --new-name are required for rename-client")
            raise ValueError("name and new-name are required for rename-client")
        return manager.rename_client(
            sanitize_client_name(name),
            sanitize_client_name(new_name),
        )
    if action == "update-server":
        updates = parse_key_values(set_items)
        if not updates:
            if parser:
                parser.error("At least one --set KEY=VALUE is required for update-server")
            raise ValueError("At least one KEY=VALUE is required")
        return manager.update_server(updates)
    if action == "update-client":
        if not name:
            if parser:
                parser.error("--name is required for update-client")
            raise ValueError("name is required for update-client")
        updates = parse_key_values(set_items)
        if not updates:
            if parser:
                parser.error("At least one --set KEY=VALUE is required for update-client")
            raise ValueError("At least one KEY=VALUE is required")
        return manager.update_client(sanitize_client_name(name), updates)
    if action == "show-client-config-path":
        if not name:
            if parser:
                parser.error("--name is required for show-client-config-path")
            raise ValueError("name is required for show-client-config-path")
        return manager.show_client_config_path(sanitize_client_name(name))
    raise RuntimeError(f"Action is not implemented: {action}")


def _systemctl_enable_start(unit: str) -> dict[str, object]:
    if shutil.which("systemctl") is None:
        return {"unit": unit, "enabled": False, "started": False, "error": "systemctl not found"}
    enabled_proc = subprocess.run(
        ["systemctl", "enable", unit],
        text=True,
        capture_output=True,
        check=False,
    )
    started_proc = subprocess.run(
        ["systemctl", "start", unit],
        text=True,
        capture_output=True,
        check=False,
    )
    return {
        "unit": unit,
        "enabled": enabled_proc.returncode == 0,
        "started": started_proc.returncode == 0,
        "error": (started_proc.stderr or enabled_proc.stderr or "").strip(),
    }


def _ensure_autostart_services(repo_root: Path) -> dict[str, object]:
    services: list[dict[str, object]] = []
    if Path("/etc/amnezia/amneziawg/awg0.conf").exists():
        services.append(_systemctl_enable_start("awg-quick@awg0"))
    if Path("/etc/openvpn/server/server.conf").exists():
        services.append(_systemctl_enable_start("openvpn-server@server"))
    if Path("/etc/openvpn/server/server-tcp.conf").exists():
        services.append(_systemctl_enable_start("openvpn-server@server-tcp"))
    if Path("/etc/systemd/system/openvpn-nat.service").exists():
        services.append(_systemctl_enable_start("openvpn-nat.service"))
    if Path("/etc/outline-ss-server/config.yml").exists() or Path("/etc/systemd/system/outline-ss-server.service").exists():
        services.append(_systemctl_enable_start("outline-ss-server"))
    if Path("/usr/local/etc/xray/config.json").exists() or Path("/etc/xray").exists():
        services.append(_systemctl_enable_start("xray"))

    telegram_status: str = "skipped"
    try:
        bot = TelegramBotManager(repo_root=repo_root)
        started, start_err = _telegram_start_background(repo_root, bot)
        if started or start_err == "Bot is already running.":
            telegram_status = "ok"
        elif start_err == "Set token and allowed users first.":
            telegram_status = "not-configured"
        else:
            telegram_status = f"failed: {start_err or 'unknown error'}"
    except Exception as exc:  # noqa: BLE001
        telegram_status = f"failed: {exc}"

    successful = sum(1 for item in services if item.get("enabled") and item.get("started"))
    return {
        "services_checked": len(services),
        "services_ok": successful,
        "services": services,
        "telegram": telegram_status,
    }


def execute_backend_action(action: str, repo_root: Path) -> dict[str, object]:
    if action == "ping":
        return {
            "status": "ok",
            "host": socket.gethostname(),
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
    if action == "ensure-autostart":
        return _ensure_autostart_services(repo_root=repo_root)
    raise RuntimeError(f"Backend action is not implemented: {action}")


def list_servers(nodes: list[ServerNode]) -> dict[str, object]:
    servers: list[dict[str, object]] = []
    for node in nodes:
        auth_method = "password" if node.password else "ssh-key"
        servers.append(
            {
                "name": node.name,
                "country": node.country,
                "host": node.host,
                "port": node.port,
                "user": node.user,
                "ssh_key_path": node.ssh_key_path,
                "auth_method": auth_method,
                "manager_path": node.manager_path,
                "enabled": node.enabled,
            }
        )
    return {"servers": servers, "summary": {"total": len(servers), "enabled": sum(1 for node in nodes if node.enabled)}}


def check_servers(
    nodes: list[ServerNode],
    server_name: str | None,
    all_enabled: bool,
    timeout_seconds: int,
    parser: argparse.ArgumentParser,
) -> dict[str, object]:
    if all_enabled and server_name:
        parser.error("Use either --name or --all for 'servers check'.")
    if not all_enabled and not server_name:
        parser.error("Use --name <server> or --all for 'servers check'.")
    inventory_map = _inventory_by_name(nodes)
    selected: list[ServerNode]
    if all_enabled:
        selected = [node for node in nodes if node.enabled]
        if not selected:
            raise RuntimeError("No enabled servers in inventory.")
    else:
        if server_name not in inventory_map:
            raise RuntimeError(f"Server '{server_name}' not found in inventory.")
        selected = [inventory_map[server_name]]
    node_results: dict[str, dict[str, object]] = {}
    for node in selected:
        ping_result = run_remote_manager(
            node=node,
            protocol="backend",
            action="ping",
            action_args=[],
            timeout_seconds=timeout_seconds,
        )
        node_results[node.name] = ping_result
    summary = _count_summary(local_result=None, nodes_result=node_results)
    return {"mode": "servers-check", "nodes": node_results, "summary": summary}


def orchestrate_remote(
    repo_root: Path,
    parser: argparse.ArgumentParser,
    mode: str,
    nodes: list[ServerNode],
    server_name: str | None,
    protocol: str,
    action: str,
    name: str | None,
    new_name: str | None,
    set_items: list[str],
    host: str | None,
    port: str | None,
    proto: str | None,
    timeout_seconds: int,
) -> dict[str, object]:
    is_backend = protocol == "backend"
    if is_backend:
        if action not in BACKEND_ACTION_CHOICES:
            parser.error(f"Unsupported backend action for remote mode: {action}")
        include_local = mode == "remote-all"
    else:
        if protocol not in LOCAL_PROTOCOL_CHOICES:
            parser.error(f"Unsupported protocol for remote mode: {protocol}")
        if action not in LOCAL_ACTION_CHOICES:
            parser.error(f"Unsupported action for remote mode: {action}")
        include_local = action in {"install", "uninstall"}
    inventory_map = _inventory_by_name(nodes)
    selected_nodes: list[ServerNode]
    if mode == "remote":
        if not server_name:
            parser.error("remote requires <server> argument")
        if server_name not in inventory_map:
            raise RuntimeError(f"Server '{server_name}' not found in inventory.")
        selected_nodes = [inventory_map[server_name]]
    else:
        selected_nodes = [node for node in nodes if node.enabled]
        if not selected_nodes and not include_local:
            raise RuntimeError("No enabled servers in inventory.")
    if is_backend:
        action_args: list[str] = []
    else:
        action_args = _build_action_cli_args(name, new_name, set_items, host, port, proto)
    local_result: dict[str, object] | None = None
    if include_local:
        try:
            if is_backend:
                local_payload = execute_backend_action(action, repo_root=repo_root)
            else:
                manager = get_manager(protocol, repo_root=repo_root)
                local_payload = execute_action(
                    manager,
                    action,
                    name,
                    new_name,
                    set_items,
                    host=host,
                    port=port,
                    proto=proto,
                    parser=parser,
                )
            local_result = {"ok": True, "result": local_payload}
        except Exception as exc:  # noqa: BLE001
            local_result = {"ok": False, "error_type": "local_error", "error": str(exc)}
    node_results: dict[str, dict[str, object]] = {}
    for node in selected_nodes:
        result = run_remote_manager(
            node=node,
            protocol=protocol,
            action=action,
            action_args=action_args,
            timeout_seconds=timeout_seconds,
        )
        if result.get("ok") is True:
            config_path = _extract_config_path(action, result.get("result"))
            if config_path:
                result["config_path"] = config_path
        node_results[node.name] = result
    summary = _count_summary(local_result=local_result, nodes_result=node_results)
    return {
        "mode": mode,
        "protocol": protocol,
        "action": action,
        "local": local_result,
        "nodes": node_results,
        "summary": summary,
    }


def interactive_menu(repo_root: Path) -> int:
    print(f"\n{_color('  Unified VPN Manager', _C.BOLD)}")
    print(f"  {_color('─' * 34, _C.DIM)}")
    print(f"  {_color('Run as root: sudo python3 vpn_manager.py', _C.DIM)}")
    print(f"  {_color('Telegram bot: sudo python3 vpn_manager.py --telegram-bot', _C.DIM)}")
    while True:
        print(f"\n{_color('Select section:', _C.BOLD)}")
        print(f"  {_color('1', _C.CYAN)}) AmneziaWG")
        print(f"  {_color('2', _C.CYAN)}) OpenVPN")
        print(f"  {_color('3', _C.CYAN)}) Outline")
        print(f"  {_color('4', _C.CYAN)}) Xray Reality")
        print(f"  {_color('5', _C.CYAN)}) Telegram bot")
        print(f"  {_color('0', _C.CYAN)}) Exit")
        protocol_choice = input("  > ").strip()
        if protocol_choice == "0":
            return 0
        if protocol_choice == "5":
            telegram_menu(repo_root=repo_root)
            continue
        if protocol_choice not in {"1", "2", "3", "4", "5"}:
            print("Invalid choice.")
            continue
        protocol_map = {
            "1": "amneziawg",
            "2": "openvpn",
            "3": "outline",
            "4": "xray",
        }
        protocol = protocol_map[protocol_choice]
        manager = get_manager(protocol, repo_root=repo_root)

        while True:
            print(f"\n{_color(f'Protocol: {protocol}', _C.BOLD)}")
            for idx, action_name in enumerate(LOCAL_ACTION_CHOICES, start=1):
                print(f"  {_color(str(idx), _C.CYAN)}) {action_name}")
            print(f"  {_color('0', _C.CYAN)}) Back")
            action_choice = input("  > ").strip()
            if action_choice == "0":
                break
            if not action_choice.isdigit() or int(action_choice) < 1 or int(action_choice) > len(LOCAL_ACTION_CHOICES):
                print(_color("Invalid choice.", _C.RED))
                continue
            action = LOCAL_ACTION_CHOICES[int(action_choice) - 1]

            name = None
            new_name = None
            set_items: list[str] = []
            host = None
            port = None
            proto = None

            if action in {"create-client", "delete-client", "show-client-config-path", "update-client", "rename-client"}:
                name = input("Client name: ").strip()
            if action == "rename-client":
                new_name = input("New client name: ").strip()
            if action == "create-client" and protocol == "openvpn":
                host = input("Remote host (optional): ").strip() or None
                port = input("Remote port (optional): ").strip() or None
                proto = input("Protocol udp/tcp (optional): ").strip() or None
            if action in {"update-server", "update-client"}:
                print("Enter KEY=VALUE pairs, one per line. Empty line to finish:")
                while True:
                    pair = input("  set> ").strip()
                    if not pair:
                        break
                    set_items.append(pair)

            try:
                result = execute_action(
                    manager,
                    action,
                    name,
                    new_name,
                    set_items,
                    host=host,
                    port=port,
                    proto=proto,
                    parser=None,
                )
                print_result(result, as_json=False)
            except Exception as exc:  # noqa: BLE001
                print(f"Error: {exc}")


def telegram_menu(repo_root: Path) -> None:
    bot = TelegramBotManager(repo_root=repo_root)
    while True:
        running = _telegram_is_running()
        allowed_list = bot.status().get("allowed_users", [])
        print(f"\n  {_color('TelegramApp', _C.BOLD)}")
        print(f"  {_color('─' * 29, _C.DIM)}")
        print(f"  {_color('1', _C.CYAN)}. Set bot token" + (_color(" [set]", _C.GREEN) if bot.status().get("token_configured") else ""))
        print(f"  {_color('2', _C.CYAN)}. Set allowed user ID" + (_color(" [set]", _C.GREEN) if bot.status().get('allowed_user_id') else ""))
        print(f"  {_color('3', _C.CYAN)}. AddUser" + (f" [{len(allowed_list)}]" if allowed_list else ""))
        print(f"  {_color('4', _C.CYAN)}. Send test message")
        print(
            f"  {_color('5', _C.CYAN)}. Run bot (manage configs via Telegram)"
            + (_color(" [running]", _C.GREEN) if running else "")
        )
        if running:
            print(f"  {_color('6', _C.CYAN)}. Stop bot")
        print(f"  {_color('0', _C.CYAN)}. Back")
        print()
        choice = input("  > ").strip()
        if choice == "0":
            return
        if choice == "1":
            token = input("  Bot token (leave empty to keep): ").strip()
            if token:
                try:
                    bot.configure(token, None, None)
                    print(_color("  Token saved.", _C.GREEN))
                except Exception as exc:  # noqa: BLE001
                    print(_color(f"  Error: {exc}", _C.RED))
            else:
                print(_color("  Token not changed.", _C.DIM))
        elif choice == "2":
            allowed_uid = input("  Allowed user ID (digits, empty to keep): ").strip()
            try:
                status = bot.configure(None, None, allowed_uid or None)
                print(
                    f"  Saved. allowed_user_id: {status['allowed_user_id'] or '(not set)'}; "
                    f"allowed_users: {', '.join(status.get('allowed_users') or []) or '(empty)'}"
                )
            except Exception as exc:  # noqa: BLE001
                print(_color(f"  Error: {exc}", _C.RED))
        elif choice == "3":
            _manage_allowed_users(bot)
        elif choice == "4":
            text = input("  Message text: ").strip() or "Ping from VPN manager"
            try:
                bot.send_test_message(text)
                print(_color("  Sent.", _C.GREEN))
            except Exception as exc:  # noqa: BLE001
                print(_color(f"  Error: {exc}", _C.RED))
        elif choice == "5":
            ok, err = _telegram_start_background(repo_root, bot)
            if ok:
                print(_color("  Bot started. Works in background; you can exit the menu.", _C.GREEN))
            else:
                print(_color(f"  Error: {err}", _C.RED))
        elif choice == "6" and running:
            ok, err = _telegram_stop_background()
            if ok:
                print(_color("  Bot stopped.", _C.GREEN))
            else:
                print(_color(f"  Error: {err}", _C.RED))
        else:
            print(_color("  Invalid choice.", _C.RED))


def _manage_allowed_users(bot: TelegramBotManager) -> None:
    status = bot.status()
    users = status.get("allowed_users", []) or []
    protected = status.get("allowed_user_id") or ""
    if users:
        print(f"Allowed users: {', '.join(users)}")
    else:
        print("Allowed users: (empty)")
    print("Enter ID to add, or prefix '-' to remove. Empty to cancel.")
    uid = input("  user> ").strip()
    if not uid:
        return
    try:
        if uid.startswith("-"):
            target = uid.lstrip("-")
            if protected and target == protected:
                print(_color("Cannot remove primary allowed user ID.", _C.RED))
            else:
                bot.remove_allowed_user(target)
                print(_color("User removed.", _C.GREEN))
        else:
            bot.add_allowed_user(uid)
            print(_color("User added.", _C.GREEN))
    except Exception as exc:  # noqa: BLE001
        print(_color(f"Error: {exc}", _C.RED))


def _resolve_inventory_path(repo_root: Path, raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    return path


def _has_failed_nodes(result: object) -> bool:
    if not isinstance(result, dict):
        return False
    summary = result.get("summary")
    if not isinstance(summary, dict):
        return False
    failed = summary.get("failed")
    return isinstance(failed, int) and failed > 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    require_root()
    repo_root = Path(__file__).resolve().parent
    if args.timeout < 1:
        parser.error("--timeout must be >= 1")

    if args.telegram_bot or args.telegram_token or args.telegram_chat_id or args.telegram_test_message:
        bot = TelegramBotManager(repo_root=repo_root)
        if args.telegram_token or args.telegram_chat_id or args.telegram_allowed_user_id:
            bot.configure(args.telegram_token, args.telegram_chat_id, args.telegram_allowed_user_id)
        if args.telegram_test_message:
            try:
                bot.send_test_message(args.telegram_test_message)
                print("Message sent.")
            except Exception as exc:  # noqa: BLE001
                print(f"Error: {exc}", file=sys.stderr)
                return 1
            return 0
        if args.telegram_bot:
            try:
                bot.run_polling(once=args.telegram_once)
            except KeyboardInterrupt:
                print("Telegram bot stopped.")
            except Exception as exc:  # noqa: BLE001
                print(f"Error: {exc}", file=sys.stderr)
                return 1
            return 0

    if not args.protocol and not args.action:
        return interactive_menu(repo_root=repo_root)
    try:
        result: object
        if args.protocol == "backend":
            if not args.action:
                parser.error("backend requires an action")
            if args.action not in BACKEND_ACTION_CHOICES:
                parser.error(f"Unsupported backend action: {args.action}")
            if args.extra:
                parser.error("backend does not accept extra positional arguments")
            result = execute_backend_action(args.action, repo_root=repo_root)
            print_result(result, as_json=args.json)
            return 0

        if args.protocol == "servers":
            inventory_path = _resolve_inventory_path(repo_root, args.inventory)
            nodes = load_inventory(inventory_path)
            if not args.action:
                parser.error("servers requires an action: list or check")
            if args.action not in SERVER_ACTION_CHOICES:
                parser.error(f"Unsupported servers action: {args.action}")
            if args.extra:
                parser.error("servers command does not accept extra positional arguments")
            if args.action == "list":
                result = list_servers(nodes)
            else:
                result = check_servers(
                    nodes=nodes,
                    server_name=args.name,
                    all_enabled=args.all,
                    timeout_seconds=args.timeout,
                    parser=parser,
                )
            print_result(result, as_json=args.json)
            return 1 if _has_failed_nodes(result) else 0

        if args.protocol == "remote":
            inventory_path = _resolve_inventory_path(repo_root, args.inventory)
            nodes = load_inventory(inventory_path)
            server_name = args.action
            if not server_name:
                parser.error("remote requires: remote <server> <protocol> <action>")
            if len(args.extra) < 2:
                parser.error("remote requires: remote <server> <protocol> <action>")
            if len(args.extra) > 2:
                parser.error("remote accepts only: remote <server> <protocol> <action>")
            result = orchestrate_remote(
                repo_root=repo_root,
                parser=parser,
                mode="remote",
                nodes=nodes,
                server_name=server_name,
                protocol=args.extra[0],
                action=args.extra[1],
                name=args.name,
                new_name=args.new_name,
                set_items=args.set_items,
                host=args.host,
                port=args.port,
                proto=args.proto,
                timeout_seconds=args.timeout,
            )
            print_result(result, as_json=args.json)
            return 1 if _has_failed_nodes(result) else 0

        if args.protocol == "remote-all":
            inventory_path = _resolve_inventory_path(repo_root, args.inventory)
            nodes = load_inventory(inventory_path)
            if not args.action:
                parser.error("remote-all requires: remote-all <protocol> <action>")
            if not args.extra:
                parser.error("remote-all requires: remote-all <protocol> <action>")
            if len(args.extra) > 1:
                parser.error("remote-all accepts only: remote-all <protocol> <action>")
            result = orchestrate_remote(
                repo_root=repo_root,
                parser=parser,
                mode="remote-all",
                nodes=nodes,
                server_name=None,
                protocol=args.action,
                action=args.extra[0],
                name=args.name,
                new_name=args.new_name,
                set_items=args.set_items,
                host=args.host,
                port=args.port,
                proto=args.proto,
                timeout_seconds=args.timeout,
            )
            print_result(result, as_json=args.json)
            return 1 if _has_failed_nodes(result) else 0

        if not args.action:
            parser.error("Action is required for local protocol commands.")
        if args.extra:
            parser.error("Unexpected extra positional arguments for local protocol command.")
        if args.protocol not in LOCAL_PROTOCOL_CHOICES:
            parser.error(f"Unsupported protocol: {args.protocol}")
        if args.action not in LOCAL_ACTION_CHOICES:
            parser.error(f"Unsupported action: {args.action}")
        manager = get_manager(args.protocol, repo_root=repo_root)
        result = execute_action(
            manager,
            args.action,
            args.name,
            args.new_name,
            args.set_items,
            host=args.host,
            port=args.port,
            proto=args.proto,
            parser=parser,
        )
    except Exception as exc:  # noqa: BLE001
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=True))
        else:
            print(f"Error: {exc}", file=sys.stderr)
        return 1

    print_result(result, as_json=args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
