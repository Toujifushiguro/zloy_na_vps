from __future__ import annotations

import json
import secrets
import threading
import time
import urllib.parse
import urllib.request
import sys
import subprocess
import tempfile
import html
import ipaddress
import shlex
from pathlib import Path
from typing import Any, Callable
import textwrap
import shutil

from .amneziawg import AmneziaWGManager
from .openvpn import OpenVPNManager
from .outline import OutlineManager
from .xray_reality import XrayRealityManager
from .shared import require_root, sanitize_client_name, write_text

CONFIG_PATH = Path(__file__).resolve().parent.parent / "telegram_bot.json"
SERVERS_PATH = Path(__file__).resolve().parent.parent / "servers.json"
SERVER_SETUP_LOG_PATH = Path(__file__).resolve().parent.parent / "server_setup.log"


def _load_config(config_path: Path) -> dict[str, str]:
    if not config_path.exists():
        return {}
    try:
        content = config_path.read_text().strip()
        data = json.loads(content) if content else {}
        if isinstance(data, dict):
            return data
        return {}
    except json.JSONDecodeError:
        return {}


def _save_config(config_path: Path, data: dict[str, str]) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    write_text(config_path, json.dumps(data, ensure_ascii=True, indent=2), mode=0o600)


def _load_servers(servers_path: Path) -> dict[str, object]:
    if not servers_path.exists():
        return {"servers": []}
    try:
        content = servers_path.read_text().strip()
        data = json.loads(content) if content else {"servers": []}
    except json.JSONDecodeError:
        return {"servers": []}
    if not isinstance(data, dict):
        return {"servers": []}
    servers = data.get("servers")
    if not isinstance(servers, list):
        data["servers"] = []
    return data


def _save_servers(servers_path: Path, data: dict[str, object]) -> None:
    if "servers" not in data or not isinstance(data.get("servers"), list):
        data["servers"] = []
    servers_path.parent.mkdir(parents=True, exist_ok=True)
    write_text(servers_path, json.dumps(data, ensure_ascii=True, indent=2), mode=0o600)


class TelegramBotManager:
    def __init__(self, repo_root: Path, config_path: Path = CONFIG_PATH):
        self.repo_root = repo_root
        self.config_path = config_path
        self._pending: dict[str, dict[str, str]] = {}
        self._last_menu_message: dict[str, int] = {}

    def _servers_path(self) -> Path:
        return self.repo_root / "servers.json"

    def _append_server_setup_log(self, server_name: str, lines: list[str]) -> None:
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        payload = [f"[{timestamp}] server={server_name}"] + lines + [""]
        SERVER_SETUP_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with SERVER_SETUP_LOG_PATH.open("a", encoding="utf-8") as logf:
            logf.write("\n".join(payload) + "\n")

    def _inventory_servers(self) -> list[dict[str, object]]:
        data = _load_servers(self._servers_path())
        raw = data.get("servers")
        if not isinstance(raw, list):
            return []
        servers: list[dict[str, object]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", "")).strip()
            if not name:
                continue
            country = str(item.get("country", "")).strip() or "-"
            host = str(item.get("host", "")).strip() or "-"
            enabled = bool(item.get("enabled", False))
            servers.append(
                {
                    "name": name,
                    "country": country,
                    "host": host,
                    "enabled": enabled,
                    "user": str(item.get("user", "")).strip() or "root",
                }
            )
        return servers

    def _find_inventory_server_raw(self, safe_name: str) -> dict[str, object] | None:
        data = _load_servers(self._servers_path())
        raw = data.get("servers")
        if not isinstance(raw, list):
            return None
        for item in raw:
            if not isinstance(item, dict):
                continue
            raw_name = str(item.get("name", "")).strip()
            if not raw_name:
                continue
            try:
                if sanitize_client_name(raw_name) == safe_name:
                    return item
            except Exception:
                continue
        return None

    def _find_inventory_server(self, safe_name: str) -> dict[str, object] | None:
        for item in self._inventory_servers():
            raw_name = str(item.get("name", "")).strip()
            if not raw_name:
                continue
            try:
                if sanitize_client_name(raw_name) == safe_name:
                    return item
            except Exception:
                continue
        return None

    def _inventory_summary(self) -> str:
        servers = self._inventory_servers()
        if not servers:
            return "No servers yet."
        lines: list[str] = []
        for item in servers:
            name = str(item.get("name", "")).strip() or "unknown"
            country = str(item.get("country", "")).strip() or "-"
            host = str(item.get("host", "")).strip() or "-"
            enabled = bool(item.get("enabled", False))
            mark = "ON" if enabled else "OFF"
            lines.append(f"- {name} ({country}) {host} [{mark}]")
        return "\n".join(lines) if lines else "No servers yet."

    def _remove_inventory_server(self, safe_name: str) -> bool:
        data = _load_servers(self._servers_path())
        raw = data.get("servers")
        if not isinstance(raw, list):
            return False
        kept: list[dict[str, object]] = []
        removed = False
        for item in raw:
            if not isinstance(item, dict):
                continue
            raw_name = str(item.get("name", "")).strip()
            if not raw_name:
                kept.append(item)
                continue
            try:
                item_safe = sanitize_client_name(raw_name)
            except Exception:
                kept.append(item)
                continue
            if item_safe == safe_name:
                removed = True
                continue
            kept.append(item)
        if removed:
            data["servers"] = kept
            _save_servers(self._servers_path(), data)
        return removed

    def _update_inventory_server(self, safe_name: str, updates: dict[str, object]) -> bool:
        data = _load_servers(self._servers_path())
        raw = data.get("servers")
        if not isinstance(raw, list):
            return False
        updated = False
        for item in raw:
            if not isinstance(item, dict):
                continue
            raw_name = str(item.get("name", "")).strip()
            if not raw_name:
                continue
            try:
                item_safe = sanitize_client_name(raw_name)
            except Exception:
                continue
            if item_safe != safe_name:
                continue
            item.update(updates)
            updated = True
            break
        if updated:
            _save_servers(self._servers_path(), data)
        return updated

    def _upsert_inventory_server(self, name: str, country: str, host: str, password: str) -> None:
        data = _load_servers(self._servers_path())
        servers_value = data.get("servers")
        servers: list[dict[str, object]] = []
        if isinstance(servers_value, list):
            for item in servers_value:
                if isinstance(item, dict):
                    servers.append(item)
        manager_path = "/root/vpn-unified-manager/vpn_manager.py"
        new_entry: dict[str, object] = {
            "name": name,
            "country": country,
            "host": host,
            "port": 22,
            "user": "root",
            "password": password,
            "ssh_key_path": "",
            "controller_ssh_key_path": "/etc/vpn-unified-manager/keys/controller_ed25519",
            "manager_path": manager_path,
            "enabled": True,
        }
        replaced = False
        for idx, item in enumerate(servers):
            existing_name = str(item.get("name", "")).strip().lower()
            if existing_name == name.lower():
                servers[idx] = new_entry
                replaced = True
                break
        if not replaced:
            servers.append(new_entry)
        data["servers"] = servers
        _save_servers(self._servers_path(), data)

    def _run_local_command(self, cmd: list[str], timeout_seconds: int) -> tuple[bool, str]:
        try:
            proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            return False, f"timeout after {timeout_seconds}s"
        if proc.returncode != 0:
            details = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
            if len(details) > 400:
                details = details[:400] + "..."
            return False, details
        out = proc.stdout.strip() or "ok"
        if len(out) > 400:
            out = out[:400] + "..."
        return True, out

    def _cleanup_known_host_entries(self, host: str, port: int) -> tuple[bool, str]:
        known_hosts_paths: list[Path] = [Path("/root/.ssh/known_hosts")]
        home_root = Path("/home")
        if home_root.exists():
            for child in home_root.iterdir():
                known_hosts_paths.append(child / ".ssh" / "known_hosts")
        removed_any = False
        messages: list[str] = []
        for kh_path in known_hosts_paths:
            if not kh_path.exists():
                continue
            for key in [host, f"[{host}]:{port}"]:
                ok, details = self._run_local_command(
                    ["ssh-keygen", "-R", key, "-f", str(kh_path)],
                    timeout_seconds=10,
                )
                if ok:
                    removed_any = True
                    messages.append(f"{kh_path.name}:{key}:removed")
                else:
                    lowered = details.lower()
                    if "not found" in lowered:
                        messages.append(f"{kh_path.name}:{key}:not-found")
                    else:
                        messages.append(f"{kh_path.name}:{key}:warn:{details}")
        if removed_any:
            return True, "; ".join(messages) or "known_hosts cleaned"
        return False, "; ".join(messages) or "no matching known_hosts entries"

    def _run_remote_with_hostkey_retry(self, cmd: list[str], timeout_seconds: int, host: str, port: int) -> tuple[bool, str]:
        ok, details = self._run_local_command(cmd, timeout_seconds=timeout_seconds)
        if ok:
            return True, details
        lowered = details.lower()
        hostkey_error = (
            "remote host identification has changed" in lowered
            or "host key verification failed" in lowered
            or "offending" in lowered
        )
        if not hostkey_error:
            return False, details
        cleaned, clean_details = self._cleanup_known_host_entries(host, port)
        if not cleaned:
            return False, f"{details}; known_hosts cleanup failed: {clean_details}"
        ok2, details2 = self._run_local_command(cmd, timeout_seconds=timeout_seconds)
        if ok2:
            return True, f"{details2} (retried after known_hosts cleanup)"
        return False, f"{details2} (retried after known_hosts cleanup: {clean_details})"

    def _looks_like_auth_error(self, details: str) -> bool:
        lowered = details.lower()
        return "permission denied" in lowered or "authentication failed" in lowered or "publickey,password" in lowered

    def _looks_like_package_lock_error(self, details: str) -> bool:
        lowered = details.lower()
        markers = [
            "unable to acquire the dpkg frontend lock",
            "could not get lock /var/lib/dpkg/lock-frontend",
            "could not get lock /var/lib/dpkg/lock",
            "could not get lock /var/lib/apt/lists/lock",
            "is another process using it",
            "resource temporarily unavailable",
        ]
        return any(marker in lowered for marker in markers)

    def _looks_like_unmet_dependencies_error(self, details: str) -> bool:
        lowered = details.lower()
        markers = [
            "unmet dependencies",
            "fix-broken install",
            "you might want to run 'apt --fix-broken install'",
            "depends:",
        ]
        return any(marker in lowered for marker in markers)

    def _looks_like_transient_transport_error(self, details: str) -> bool:
        lowered = details.lower()
        markers = [
            "connection refused",
            "connection timed out",
            "operation timed out",
            "connection reset by peer",
            "connection closed by remote host",
            "connection closed",
            "no route to host",
            "network is unreachable",
            "kex_exchange_identification",
            "ssh_exchange_identification",
            "broken pipe",
        ]
        return any(marker in lowered for marker in markers)

    def _looks_like_transient_install_error(self, details: str) -> bool:
        lowered = details.lower()
        if self._looks_like_package_lock_error(details):
            return True
        if self._looks_like_unmet_dependencies_error(details):
            return True
        if self._looks_like_transient_transport_error(details):
            return True
        return "timeout after" in lowered or "temporarily unavailable" in lowered

    def _remote_protocol_installed(
        self,
        ssh_prefix: list[str],
        host: str,
        port: int,
        protocol: str,
    ) -> tuple[bool, bool, str]:
        check_cmd = (
            "sudo -n python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import shutil\n"
            f"proto = {protocol!r}\n"
            "installed = False\n"
            "if proto == 'amneziawg':\n"
            "    installed = bool(shutil.which('awg')) and Path('/etc/amnezia/amneziawg/awg0.conf').exists()\n"
            "elif proto == 'openvpn':\n"
            "    installed = bool(shutil.which('openvpn')) and Path('/etc/openvpn/server/server.conf').exists()\n"
            "elif proto == 'outline':\n"
            "    installed = Path('/usr/local/bin/outline-ss-server').exists() and (Path('/etc/outline-ss-server/config.json').exists() or Path('/etc/outline-ss-server/config.yml').exists())\n"
            "elif proto == 'xray':\n"
            "    installed = Path('/usr/local/bin/xray').exists() and Path('/usr/local/etc/xray/config.json').exists()\n"
            "print('yes' if installed else 'no')\n"
            "PY"
        )
        ok, details = self._run_remote_with_hostkey_retry(
            [*ssh_prefix, check_cmd],
            timeout_seconds=45,
            host=host,
            port=port,
        )
        if not ok:
            return False, False, details
        return True, details.strip().endswith("yes"), details

    def _cleanup_remote_install_processes(
        self,
        ssh_prefix: list[str],
        host: str,
        port: int,
        manager_path: str,
        protocol: str,
    ) -> tuple[bool, str]:
        cleanup_cmd = (
            "sudo -n sh -c "
            + shlex.quote(
                f"pids=$(pgrep -f {shlex.quote(manager_path + ' ' + protocol + ' install')} 2>/dev/null || true); "
                "[ -n \"$pids\" ] && kill $pids 2>/dev/null || true; "
                "pids=$(pgrep -x apt-get 2>/dev/null || true); [ -n \"$pids\" ] && kill $pids 2>/dev/null || true; "
                "pids=$(pgrep -x dpkg 2>/dev/null || true); [ -n \"$pids\" ] && kill $pids 2>/dev/null || true; "
                "dpkg --configure -a >/dev/null 2>&1 || true"
            )
        )
        return self._run_remote_with_hostkey_retry(
            [*ssh_prefix, cleanup_cmd],
            timeout_seconds=60,
            host=host,
            port=port,
        )

    def _repair_remote_package_state(self, ssh_prefix: list[str], host: str, port: int) -> tuple[bool, str]:
        repair_cmd = (
            "sudo -n sh -c "
            + shlex.quote(
                "if command -v apt-get >/dev/null 2>&1; then "
                "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -f install -y >/dev/null 2>&1 || true; "
                "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 --fix-broken install -y >/dev/null 2>&1 || true; "
                "fi; "
                "if command -v apt >/dev/null 2>&1; then "
                "DEBIAN_FRONTEND=noninteractive apt -y --fix-broken install >/dev/null 2>&1 || true; "
                "fi; "
                "dpkg --configure -a >/dev/null 2>&1 || true"
            )
        )
        return self._run_remote_with_hostkey_retry(
            [*ssh_prefix, repair_cmd],
            timeout_seconds=240,
            host=host,
            port=port,
        )

    def _transport_from_values(
        self,
        host: str,
        user: str,
        port: int,
        password: str,
        ssh_key_path: str,
    ) -> tuple[list[str], list[str], str | None]:
        item: dict[str, object] = {
            "host": host,
            "user": user,
            "port": port,
            "password": password,
            "ssh_key_path": ssh_key_path,
        }
        return self._prepare_remote_transport(item)

    def _load_local_bootstrap_profile(self) -> tuple[bool, dict[str, object] | None, str]:
        path = Path("/etc/vpn-unified-manager/bootstrap.json")
        if not path.exists():
            return False, None, f"profile not found: {path}"
        try:
            data = json.loads(path.read_text())
        except Exception as exc:  # noqa: BLE001
            return False, None, f"invalid profile json: {exc}"
        if not isinstance(data, dict):
            return False, None, "bootstrap profile must be JSON object"
        required = ["new_user", "ssh_port"]
        for key in required:
            value = data.get(key)
            if not isinstance(value, str) or not value.strip():
                return False, None, f"profile field '{key}' is required"
        keys_value = data.get("ssh_public_keys")
        has_keys_list = isinstance(keys_value, list) and any(isinstance(item, str) and item.strip() for item in keys_value)
        has_single_key = isinstance(data.get("ssh_public_key"), str) and str(data.get("ssh_public_key")).strip() != ""
        if not has_keys_list and not has_single_key:
            return False, None, "profile must contain ssh_public_key or ssh_public_keys"
        return True, data, ""

    def _ensure_controller_keypair(self) -> tuple[bool, str, str, str]:
        key_dir = Path("/etc/vpn-unified-manager/keys")
        private_path = key_dir / "controller_ed25519"
        public_path = key_dir / "controller_ed25519.pub"
        key_dir.mkdir(parents=True, exist_ok=True)
        if not private_path.exists() or not public_path.exists():
            ok, details = self._run_local_command(
                ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(private_path), "-C", "vpn-unified-manager-controller"],
                timeout_seconds=12,
            )
            if not ok:
                return False, "", "", details
        try:
            private_path.chmod(0o600)
            public_path.chmod(0o644)
            pub_text = public_path.read_text().strip()
        except Exception as exc:  # noqa: BLE001
            return False, "", "", str(exc)
        if not pub_text:
            return False, "", "", "controller public key is empty"
        return True, str(private_path), pub_text, ""

    def _match_private_key_for_public_key(self, public_key: str) -> str | None:
        parts = public_key.strip().split()
        if len(parts) < 2:
            return None
        target = f"{parts[0]} {parts[1]}"
        candidate_dirs: list[Path] = [Path("/root/.ssh"), Path("/etc/vpn-unified-manager/keys")]
        home_root = Path("/home")
        if home_root.exists():
            for child in home_root.iterdir():
                candidate_dirs.append(child / ".ssh")
        for folder in candidate_dirs:
            if not folder.exists():
                continue
            for key_path in folder.glob("*"):
                if key_path.suffix == ".pub" or not key_path.is_file():
                    continue
                ok, details = self._run_local_command(["ssh-keygen", "-y", "-f", str(key_path)], timeout_seconds=8)
                if not ok:
                    continue
                generated = details.strip().split()
                if len(generated) < 2:
                    continue
                current = f"{generated[0]} {generated[1]}"
                if current == target:
                    return str(key_path)
        return None

    def _ensure_sshpass_installed(self) -> tuple[bool, str]:
        if shutil.which("sshpass") is not None:
            return True, "already installed"
        if shutil.which("apt-get") is not None:
            ok, details = self._run_local_command(["apt-get", "update", "-qq"], timeout_seconds=120)
            if not ok:
                return False, f"apt update failed: {details}"
            ok, details = self._run_local_command(
                ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "sshpass"],
                timeout_seconds=180,
            )
            if not ok:
                return False, f"apt install failed: {details}"
            return True, details
        if shutil.which("dnf") is not None:
            return self._run_local_command(["dnf", "install", "-y", "sshpass"], timeout_seconds=180)
        if shutil.which("yum") is not None:
            return self._run_local_command(["yum", "install", "-y", "sshpass"], timeout_seconds=180)
        if shutil.which("apk") is not None:
            return self._run_local_command(["apk", "add", "--no-cache", "sshpass"], timeout_seconds=120)
        if shutil.which("pacman") is not None:
            return self._run_local_command(["pacman", "-Sy", "--noconfirm", "sshpass"], timeout_seconds=180)
        if shutil.which("zypper") is not None:
            return self._run_local_command(["zypper", "install", "-y", "sshpass"], timeout_seconds=180)
        return False, "cannot auto-install sshpass: unsupported package manager"

    def _prepare_remote_transport(self, item: dict[str, object]) -> tuple[list[str], list[str], str | None]:
        host = str(item.get("host", "")).strip()
        user = str(item.get("user", "")).strip() or "root"
        raw_port = item.get("port", 22)
        port = 22
        if isinstance(raw_port, int):
            port = raw_port
        elif isinstance(raw_port, str) and raw_port.strip().isdigit():
            port = int(raw_port.strip())
        password = str(item.get("password", "")).strip()
        ssh_key_path = str(item.get("ssh_key_path", "")).strip()
        controller_ssh_key_path = str(item.get("controller_ssh_key_path", "")).strip()
        if not ssh_key_path and controller_ssh_key_path:
            ssh_key_path = controller_ssh_key_path
        common = ["-p", str(port), "-o", "StrictHostKeyChecking=accept-new", f"{user}@{host}"]
        if password:
            if shutil.which("sshpass") is None:
                return [], [], "sshpass is required for password auth (install: apt-get install sshpass)."
            ssh_prefix = ["sshpass", "-p", password, "ssh", "-o", "PreferredAuthentications=password", *common]
            scp_prefix = [
                "sshpass",
                "-p",
                password,
                "scp",
                "-P",
                str(port),
                "-o",
                "StrictHostKeyChecking=accept-new",
            ]
            return ssh_prefix, scp_prefix, None
        if ssh_key_path:
            expanded = str(Path(ssh_key_path).expanduser())
            if not Path(expanded).exists():
                return [], [], f"SSH key not found: {expanded}"
            ssh_prefix = ["ssh", "-i", expanded, "-o", "BatchMode=yes", *common]
            scp_prefix = ["scp", "-i", expanded, "-P", str(port), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
            return ssh_prefix, scp_prefix, None
        return [], [], "No auth method configured (set password or ssh_key_path)."

    def _setup_server_now(self, safe_name: str) -> tuple[bool, list[str]]:
        item = self._find_inventory_server_raw(safe_name)
        if not item:
            return False, ["server not found in inventory"]
        name = str(item.get("name", "")).strip() or safe_name
        host = str(item.get("host", "")).strip()
        user = str(item.get("user", "")).strip() or "root"
        manager_path = str(item.get("manager_path", "")).strip() or f"/home/{user}/vpn-unified-manager/vpn_manager.py"
        raw_port = item.get("port", 22)
        setup_port = 22
        if isinstance(raw_port, int):
            setup_port = raw_port
        elif isinstance(raw_port, str) and raw_port.strip().isdigit():
            setup_port = int(raw_port.strip())
        if not host:
            return False, ["host is empty"]
        bundle_path = self.repo_root / "vpn-unified-manager-bundle.sh"
        if not bundle_path.exists():
            return False, [f"bundle not found: {bundle_path}"]
        logs: list[str] = [f"setup start: {name} ({host})"]
        controller_private = ""
        controller_public = ""
        ensure_key_ok, controller_private_val, controller_public_val, controller_error = self._ensure_controller_keypair()
        if ensure_key_ok:
            controller_private = controller_private_val
            controller_public = controller_public_val
            logs.append(f"controller key ready: {controller_private}")
        else:
            logs.append(f"controller key prepare failed: {controller_error}")
        profile_ok, profile_data, profile_error = self._load_local_bootstrap_profile()
        if not profile_ok or not profile_data:
            logs.append(f"bootstrap profile load: failed ({profile_error})")
            return False, logs
        logs.append("bootstrap profile load: ok (/etc/vpn-unified-manager/bootstrap.json)")
        profile_new_user = str(profile_data.get("new_user", "")).strip()
        profile_port_raw = str(profile_data.get("ssh_port", "")).strip()
        if not profile_port_raw.isdigit():
            logs.append("bootstrap profile invalid: ssh_port must be numeric")
            return False, logs
        profile_port = int(profile_port_raw)
        profile_keys_raw = profile_data.get("ssh_public_keys")
        profile_keys: list[str] = []
        if isinstance(profile_keys_raw, list):
            for entry in profile_keys_raw:
                if isinstance(entry, str) and entry.strip():
                    profile_keys.append(entry.strip())
        profile_pubkey = str(profile_data.get("ssh_public_key", "")).strip()
        if profile_pubkey:
            profile_keys.insert(0, profile_pubkey)
        if controller_public:
            profile_keys.append(controller_public)
        seen_keys: set[str] = set()
        unique_profile_keys: list[str] = []
        for key in profile_keys:
            if key in seen_keys:
                continue
            seen_keys.add(key)
            unique_profile_keys.append(key)
        profile_keys = unique_profile_keys
        profile_pubkey = profile_keys[0] if profile_keys else ""
        if not profile_pubkey:
            logs.append("bootstrap profile invalid: no ssh public keys")
            return False, logs
        disable_root = bool(profile_data.get("disable_root_login", True))
        disable_password = bool(profile_data.get("disable_password_auth", True))
        controller_key_value = controller_public or str(profile_data.get("controller_ssh_public_key", "")).strip()
        matched_private_key = self._match_private_key_for_public_key(profile_pubkey) if profile_pubkey else None
        if matched_private_key:
            logs.append(f"profile key match: found private key {matched_private_key}")
        else:
            logs.append("profile key match: not found on main server")
            if controller_public and controller_private:
                matched_private_key = controller_private
                controller_key_value = controller_public
                logs.append("bootstrap will use controller public key for remote access")
            else:
                if disable_root or disable_password:
                    logs.append("hardening fallback: keep root/password auth enabled (no local private key match)")
                    disable_root = False
                    disable_password = False
        if str(item.get("password", "")).strip() and shutil.which("sshpass") is None:
            logs.append("sshpass not found, trying auto-install...")
            install_ok, install_details = self._ensure_sshpass_installed()
            logs.append(f"install sshpass: {'ok' if install_ok else 'failed'} ({install_details})")
            if not install_ok:
                return False, logs
        active_user = user
        active_port = setup_port
        active_password = str(item.get("password", "")).strip()
        active_key_path = str(item.get("ssh_key_path", "")).strip()
        ssh_prefix, scp_prefix, transport_error = self._transport_from_values(
            host=host,
            user=active_user,
            port=active_port,
            password=active_password,
            ssh_key_path=active_key_path,
        )
        if transport_error:
            logs.append(f"transport prepare failed: {transport_error}")
            return False, logs
        remote_bundle_path = "/root/vpn-unified-manager-bundle.sh"
        remote_repo_path = "/root/vpn-unified-manager"
        deploy_cmd = f"sh {shlex.quote(remote_bundle_path)} --dir {shlex.quote(remote_repo_path)} --no-bootstrap"
        copy_attempts_total = 6
        ok = False
        details = ""
        auth_fallback_allowed = not (bool(active_password) and not active_key_path)
        fallback_disabled_logged = False
        for copy_attempt in range(1, copy_attempts_total + 1):
            scp_cmd = [*scp_prefix, str(bundle_path), f"{active_user}@{host}:{remote_bundle_path}"]
            ok, details = self._run_remote_with_hostkey_retry(
                scp_cmd,
                timeout_seconds=180,
                host=host,
                port=active_port,
            )
            primary_copy_error = details
            if (not ok) and self._looks_like_auth_error(details) and matched_private_key and auth_fallback_allowed:
                fallback_user = profile_new_user
                fallback_port = profile_port
                fallback_password = ""
                fallback_key_path = matched_private_key
                logs.append(
                    f"primary transport auth failed; trying fallback transport {fallback_user}@{host}:{fallback_port} via key"
                )
                ssh_prefix_fb, scp_prefix_fb, transport_error_fb = self._transport_from_values(
                    host=host,
                    user=fallback_user,
                    port=fallback_port,
                    password=fallback_password,
                    ssh_key_path=fallback_key_path,
                )
                if transport_error_fb:
                    logs.append(f"fallback transport prepare failed: {transport_error_fb}")
                else:
                    active_user = fallback_user
                    active_port = fallback_port
                    active_password = fallback_password
                    active_key_path = fallback_key_path
                    ssh_prefix = ssh_prefix_fb
                    scp_prefix = scp_prefix_fb
                    remote_bundle_path = f"/tmp/vpn-unified-manager-bundle-{active_user}.sh"
                    remote_repo_path = f"/home/{active_user}/vpn-unified-manager"
                    deploy_cmd = (
                        f"sudo -n sh {shlex.quote(remote_bundle_path)} --dir {shlex.quote(remote_repo_path)} --no-bootstrap"
                    )
                    scp_cmd = [*scp_prefix, str(bundle_path), f"{active_user}@{host}:{remote_bundle_path}"]
                    ok, details = self._run_remote_with_hostkey_retry(
                        scp_cmd,
                        timeout_seconds=180,
                        host=host,
                        port=active_port,
                    )
                    if not ok:
                        details = f"primary failed: {primary_copy_error}; fallback failed: {details}"
            elif (not ok) and self._looks_like_auth_error(details) and matched_private_key and not auth_fallback_allowed:
                if not fallback_disabled_logged:
                    logs.append("primary transport auth failed in password mode; fallback disabled")
                    fallback_disabled_logged = True
            if ok:
                break
            transient_transport = self._looks_like_transient_transport_error(details)
            if (not transient_transport) or copy_attempt >= copy_attempts_total:
                break
            wait_seconds = min(45, 5 * copy_attempt)
            logs.append(
                f"copy bundle: transient transport failure "
                f"(attempt {copy_attempt}/{copy_attempts_total}), retry in {wait_seconds}s"
            )
            time.sleep(wait_seconds)
        logs.append(f"copy bundle: {'ok' if ok else 'failed'} ({details})")
        if not ok:
            return False, logs

        ok, details = self._run_remote_with_hostkey_retry(
            [*ssh_prefix, deploy_cmd],
            timeout_seconds=420,
            host=host,
            port=active_port,
        )
        logs.append(f"deploy bundle: {'ok' if ok else 'failed'} ({details})")
        if not ok:
            return False, logs

        effective_bootstrap = {
            "version": 1,
            "new_user": profile_new_user,
            "ssh_port": str(profile_port),
            "ssh_public_key": profile_pubkey,
            "controller_ssh_public_key": controller_key_value,
            "ssh_public_keys": profile_keys,
            "telegram_token": str(profile_data.get("telegram_token", "")).strip(),
            "telegram_allowed_user_id": str(profile_data.get("telegram_allowed_user_id", "")).strip(),
            "disable_root_login": disable_root,
            "disable_password_auth": disable_password,
        }
        local_profile_path = Path(tempfile.gettempdir()) / f"vum-bootstrap-{secrets.token_hex(6)}.json"
        remote_profile_path = f"/tmp/vum-bootstrap-{secrets.token_hex(6)}.json"
        local_profile_path.write_text(json.dumps(effective_bootstrap, ensure_ascii=True, indent=2))
        try:
            ok, details = self._run_remote_with_hostkey_retry(
                [*scp_prefix, str(local_profile_path), f"{active_user}@{host}:{remote_profile_path}"],
                timeout_seconds=120,
                host=host,
                port=active_port,
            )
            logs.append(f"copy bootstrap profile: {'ok' if ok else 'failed'} ({details})")
            if not ok:
                return False, logs
        finally:
            local_profile_path.unlink(missing_ok=True)

        apply_bootstrap_cmd = (
            "sudo -n python3 - <<'PY'\n"
            "import json\n"
            "import os\n"
            "import pwd\n"
            "import shutil\n"
            "import subprocess\n"
            "from pathlib import Path\n"
            "\n"
            f"profile_path = Path({remote_profile_path!r})\n"
            "profile = json.loads(profile_path.read_text())\n"
            "new_user = str(profile.get('new_user', '')).strip()\n"
            "ssh_port = str(profile.get('ssh_port', '')).strip()\n"
            "ssh_public_key = str(profile.get('ssh_public_key', '')).strip()\n"
            "keys_raw = profile.get('ssh_public_keys', [])\n"
            "ssh_public_keys = []\n"
            "if isinstance(keys_raw, list):\n"
            "    for entry in keys_raw:\n"
            "        if isinstance(entry, str) and entry.strip():\n"
            "            ssh_public_keys.append(entry.strip())\n"
            "if ssh_public_key:\n"
            "    ssh_public_keys.insert(0, ssh_public_key)\n"
            "seen = set()\n"
            "normalized_keys = []\n"
            "for key in ssh_public_keys:\n"
            "    if key in seen:\n"
            "        continue\n"
            "    seen.add(key)\n"
            "    normalized_keys.append(key)\n"
            "ssh_public_keys = normalized_keys\n"
            "disable_root = bool(profile.get('disable_root_login', True))\n"
            "disable_password = bool(profile.get('disable_password_auth', True))\n"
            "if not new_user or not ssh_port.isdigit() or not ssh_public_keys:\n"
            "    raise SystemExit('invalid bootstrap profile fields')\n"
            "\n"
            "def run(cmd: list[str], check: bool = True) -> None:\n"
            "    subprocess.run(cmd, check=check, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            "\n"
            "if subprocess.run(['id', new_user], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:\n"
            "    run(['useradd', '-m', '-s', '/bin/bash', new_user])\n"
            "if subprocess.run(['getent', 'group', 'sudo'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:\n"
            "    run(['usermod', '-aG', 'sudo', new_user], check=False)\n"
            "\n"
            "sudoers_dir = Path('/etc/sudoers.d')\n"
            "sudoers_dir.mkdir(parents=True, exist_ok=True)\n"
            "sudoers_file = sudoers_dir / new_user\n"
            "sudoers_file.write_text(f'{new_user} ALL=(ALL) NOPASSWD:ALL\\n')\n"
            "sudoers_file.chmod(0o440)\n"
            "\n"
            "user_home = Path(pwd.getpwnam(new_user).pw_dir)\n"
            "ssh_dir = user_home / '.ssh'\n"
            "ssh_dir.mkdir(parents=True, exist_ok=True)\n"
            "auth_keys = ssh_dir / 'authorized_keys'\n"
            "existing_lines = auth_keys.read_text().splitlines() if auth_keys.exists() else []\n"
            "with auth_keys.open('a') as fh:\n"
            "    for key in ssh_public_keys:\n"
            "        if key not in existing_lines:\n"
            "            fh.write(key + '\\n')\n"
            "            existing_lines.append(key)\n"
            "uid = pwd.getpwnam(new_user).pw_uid\n"
            "gid = pwd.getpwnam(new_user).pw_gid\n"
            "for p in [ssh_dir, auth_keys]:\n"
            "    os.chown(str(p), uid, gid)\n"
            "ssh_dir.chmod(0o700)\n"
            "auth_keys.chmod(0o600)\n"
            "\n"
            "dropin_dir = Path('/etc/ssh/sshd_config.d')\n"
            "dropin_dir.mkdir(parents=True, exist_ok=True)\n"
            "dropin = dropin_dir / '00-setup-server.conf'\n"
            "dropin.write_text(\n"
            "    f'Port {ssh_port}\\n'\n"
            "    f\"PermitRootLogin {'no' if disable_root else 'yes'}\\n\"\n"
            "    f\"PasswordAuthentication {'no' if disable_password else 'yes'}\\n\"\n"
            "    'PubkeyAuthentication yes\\n'\n"
            ")\n"
            "dropin.chmod(0o644)\n"
            "\n"
            "profile_dir = Path('/etc/vpn-unified-manager')\n"
            "profile_dir.mkdir(parents=True, exist_ok=True)\n"
            "(profile_dir / 'bootstrap.json').write_text(json.dumps(profile, ensure_ascii=True, indent=2) + '\\n')\n"
            "(profile_dir / 'vpn-profile.json').write_text(json.dumps({'version': 1, 'default_protocol': '', 'active_protocols': [], 'server_updates': {}}, ensure_ascii=True, indent=2) + '\\n')\n"
            "(profile_dir / 'bootstrap.json').chmod(0o600)\n"
            "(profile_dir / 'vpn-profile.json').chmod(0o600)\n"
            "\n"
            "if shutil.which('systemctl') is not None:\n"
            "    run(['systemctl', 'stop', 'ssh.socket'], check=False)\n"
            "    run(['systemctl', 'stop', 'sshd.socket'], check=False)\n"
            "    run(['systemctl', 'disable', 'ssh.socket'], check=False)\n"
            "    run(['systemctl', 'disable', 'sshd.socket'], check=False)\n"
            "    run(['systemctl', 'enable', 'ssh'], check=False)\n"
            "    run(['systemctl', 'enable', 'sshd'], check=False)\n"
            "    run(['systemctl', 'restart', 'ssh'], check=False)\n"
            "    run(['systemctl', 'restart', 'sshd'], check=False)\n"
            "else:\n"
            "    run(['service', 'ssh', 'restart'], check=False)\n"
            "    run(['service', 'sshd', 'restart'], check=False)\n"
            "\n"
            "print(json.dumps({'ok': True, 'new_user': new_user, 'ssh_port': ssh_port, 'disable_root_login': disable_root, 'disable_password_auth': disable_password}, ensure_ascii=True))\n"
            "profile_path.unlink(missing_ok=True)\n"
            "PY"
        )
        ok, details = self._run_remote_with_hostkey_retry(
            [*ssh_prefix, apply_bootstrap_cmd],
            timeout_seconds=300,
            host=host,
            port=active_port,
        )
        logs.append(f"apply bootstrap profile: {'ok' if ok else 'failed'} ({details})")
        if not ok:
            return False, logs

        updates: dict[str, object] = {
            "port": profile_port,
            "manager_path": f"{remote_repo_path}/vpn_manager.py",
        }
        if matched_private_key and (disable_root or disable_password):
            preferred_key_path = controller_private or matched_private_key
            updates.update(
                {
                    "user": profile_new_user,
                    "password": "",
                    "ssh_key_path": preferred_key_path,
                    "controller_ssh_key_path": controller_private or "",
                }
            )
        else:
            updates.update(
                {
                    "user": "root",
                    "password": str(item.get("password", "")).strip(),
                    "ssh_key_path": "",
                    "controller_ssh_key_path": controller_private or "",
                }
            )
        if self._update_inventory_server(safe_name, updates):
            logs.append("inventory update: ok")
        else:
            logs.append("inventory update: failed")

        refreshed = self._find_inventory_server_raw(safe_name) or item
        refreshed_user = str(refreshed.get("user", "root")).strip() or "root"
        refreshed_manager_path = str(refreshed.get("manager_path", "")).strip() or f"/home/{refreshed_user}/vpn-unified-manager/vpn_manager.py"
        verify_ssh_prefix, _, verify_transport_error = self._prepare_remote_transport(refreshed)
        if verify_transport_error:
            logs.append(f"post-bootstrap transport: failed ({verify_transport_error})")
            return False, logs
        verify_raw_port = refreshed.get("port", 22)
        verify_port = 22
        if isinstance(verify_raw_port, int):
            verify_port = verify_raw_port
        elif isinstance(verify_raw_port, str) and verify_raw_port.strip().isdigit():
            verify_port = int(verify_raw_port.strip())
        verify_host = str(refreshed.get("host", host)).strip() or host
        ping_cmd = f"sudo -n python3 {shlex.quote(refreshed_manager_path)} backend ping --json"
        ok, details = self._run_remote_with_hostkey_retry(
            [*verify_ssh_prefix, ping_cmd],
            timeout_seconds=120,
            host=verify_host,
            port=verify_port,
        )
        logs.append(f"backend ping: {'ok' if ok else 'failed'} ({details})")
        if not ok:
            return False, logs

        installed_on_main: list[str] = []
        for proto in ["amneziawg", "openvpn", "outline", "xray"]:
            try:
                if self._protocol_installed(proto):
                    installed_on_main.append(proto)
            except Exception:
                continue
        if not installed_on_main:
            logs.append("protocol sync: no installed protocols on main")
            return True, logs

        logs.append(f"protocol sync: start ({', '.join(installed_on_main)})")
        for proto in installed_on_main:
            check_ok, already_installed, check_details = self._remote_protocol_installed(
                verify_ssh_prefix, verify_host, verify_port, proto
            )
            if check_ok and already_installed:
                logs.append(f"protocol sync install {proto}: skip (already installed)")
                continue
            if not check_ok:
                logs.append(f"protocol sync install {proto}: pre-check warning ({check_details})")
            install_cmd = f"sudo -n python3 {shlex.quote(refreshed_manager_path)} {proto} install --json"
            attempts_total = 6
            ok = False
            details = ""
            for attempt in range(1, attempts_total + 1):
                ok, details = self._run_remote_with_hostkey_retry(
                    [*verify_ssh_prefix, install_cmd],
                    timeout_seconds=1800,
                    host=verify_host,
                    port=verify_port,
                )
                if ok:
                    break
                transient = self._looks_like_transient_install_error(details)
                check_ok, already_installed, _ = self._remote_protocol_installed(
                    verify_ssh_prefix, verify_host, verify_port, proto
                )
                if check_ok and already_installed:
                    ok = True
                    details = "already installed after previous attempt"
                    break
                if attempt >= attempts_total or not transient:
                    break
                transport_issue = self._looks_like_transient_transport_error(details)
                if proto == "amneziawg" and not transport_issue:
                    clean_ok, clean_details = self._cleanup_remote_install_processes(
                        verify_ssh_prefix,
                        verify_host,
                        verify_port,
                        refreshed_manager_path,
                        proto,
                    )
                    logs.append(
                        f"protocol sync install {proto}: cleanup stale processes "
                        f"{'ok' if clean_ok else 'warn'} ({clean_details})"
                    )
                if self._looks_like_unmet_dependencies_error(details):
                    repair_ok, repair_details = self._repair_remote_package_state(
                        verify_ssh_prefix,
                        verify_host,
                        verify_port,
                    )
                    logs.append(
                        f"protocol sync install {proto}: repair broken packages "
                        f"{'ok' if repair_ok else 'warn'} ({repair_details})"
                    )
                wait_seconds = min(90, (15 if transport_issue else 10) * attempt)
                logs.append(
                    f"protocol sync install {proto}: transient failure detected "
                    f"(attempt {attempt}/{attempts_total}), retry in {wait_seconds}s"
                )
                time.sleep(wait_seconds)
            status_suffix = f" after {attempt} attempt(s)" if attempt > 1 else ""
            logs.append(f"protocol sync install {proto}: {'ok' if ok else 'failed'}{status_suffix} ({details})")
            if not ok:
                return False, logs
        logs.append("protocol sync: completed")

        return True, logs

    def _run_control_plane(self, args: list[str], timeout_seconds: int = 600) -> str:
        manager_path = self.repo_root / "vpn_manager.py"
        cmd = [sys.executable, str(manager_path), *args, "--json"]
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_seconds)
        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()
        payload: dict[str, object] | None = None
        if stdout:
            try:
                parsed = json.loads(stdout)
                if isinstance(parsed, dict):
                    payload = parsed
            except json.JSONDecodeError:
                payload = None
        if proc.returncode != 0:
            if payload and isinstance(payload.get("error"), str):
                return f"❌ Error: {payload['error']}"
            details = stderr or stdout or "command failed"
            return f"❌ Error: {details}"
        if not payload:
            return stdout or "ok"
        result = payload.get("result")
        if isinstance(result, dict):
            summary = result.get("summary")
            if isinstance(summary, dict):
                total = summary.get("total", 0)
                ok = summary.get("ok", 0)
                failed = summary.get("failed", 0)
                return f"total={total}, ok={ok}, failed={failed}"
        return self._format_result(result)

    def _run_control_plane_payload(self, args: list[str], timeout_seconds: int = 600) -> tuple[bool, dict[str, object] | None, str]:
        manager_path = self.repo_root / "vpn_manager.py"
        cmd = [sys.executable, str(manager_path), *args, "--json"]
        try:
            proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            return False, None, f"timeout after {timeout_seconds}s"
        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()
        payload: dict[str, object] | None = None
        if stdout:
            try:
                parsed = json.loads(stdout)
                if isinstance(parsed, dict):
                    payload = parsed
            except json.JSONDecodeError:
                payload = None
        if proc.returncode != 0:
            if payload and isinstance(payload.get("error"), str):
                return False, payload, str(payload.get("error"))
            details = stderr or stdout or f"exit code {proc.returncode}"
            return False, payload, details
        if not payload:
            return False, None, "invalid json from control-plane"
        return True, payload, ""

    def _server_choice_items(self) -> list[tuple[str, str]]:
        choices: list[tuple[str, str]] = []
        for item in self._inventory_servers():
            if not item.get("enabled"):
                continue
            raw_name = str(item.get("name", "")).strip()
            if not raw_name:
                continue
            try:
                safe_name = sanitize_client_name(raw_name)
            except Exception:
                continue
            country = str(item.get("country", "")).strip() or "-"
            label = f"{country} ({raw_name})"
            choices.append((safe_name, label))
        return choices

    def _extract_remote_node_payload(
        self,
        payload: dict[str, object] | None,
        server_name: str,
    ) -> tuple[bool, object, str]:
        if not payload:
            return False, {}, "empty response payload"
        result_obj = payload.get("result")
        if not isinstance(result_obj, dict):
            return False, {}, "invalid response payload"
        nodes = result_obj.get("nodes")
        if not isinstance(nodes, dict):
            return False, {}, "nodes are missing in response"
        node_result = nodes.get(server_name)
        if not isinstance(node_result, dict):
            return False, {}, f"node result is missing for {server_name}"
        if node_result.get("ok") is not True:
            return False, node_result.get("result"), str(node_result.get("error") or "remote node failed")
        return True, node_result.get("result"), ""

    def _fetch_remote_config_text(self, server_safe_name: str, config_path: str) -> tuple[bool, str]:
        item = self._find_inventory_server_raw(server_safe_name)
        if not item:
            return False, "server not found in inventory"
        raw_port = item.get("port", 22)
        port = 22
        if isinstance(raw_port, int):
            port = raw_port
        elif isinstance(raw_port, str) and raw_port.strip().isdigit():
            port = int(raw_port.strip())
        host = str(item.get("host", "")).strip()
        ssh_prefix, _, transport_error = self._prepare_remote_transport(item)
        if transport_error:
            return False, transport_error
        sudo_cmd = [*ssh_prefix, f"sudo -n cat {shlex.quote(config_path)}"]
        ok, output = self._run_remote_with_hostkey_retry(sudo_cmd, timeout_seconds=120, host=host, port=port)
        if ok:
            return True, output
        lowered = output.lower()
        sudo_related_error = (
            "sudo:" in lowered
            or "is not in the sudoers file" in lowered
            or "a password is required" in lowered
            or "permission denied" in lowered
        )
        if not sudo_related_error:
            return False, output
        plain_cmd = [*ssh_prefix, f"cat {shlex.quote(config_path)}"]
        ok_plain, output_plain = self._run_remote_with_hostkey_retry(
            plain_cmd,
            timeout_seconds=120,
            host=host,
            port=port,
        )
        if ok_plain:
            return True, output_plain
        return False, f"{output}; fallback cat failed: {output_plain}"

    def _remote_openvpn_client_proto(self, server_safe_name: str, client_safe_name: str) -> str:
        server_item = self._find_inventory_server(server_safe_name)
        if not server_item:
            return "udp"
        server_name = str(server_item.get("name", "")).strip()
        if not server_name:
            return "udp"
        ok, payload, _ = self._run_control_plane_payload(
            ["remote", server_name, "openvpn", "show-client-config-path", "--name", client_safe_name],
            timeout_seconds=240,
        )
        if not ok or not payload:
            return "udp"
        node_ok, node_payload, _ = self._extract_remote_node_payload(payload, server_name)
        if not node_ok or not isinstance(node_payload, dict):
            return "udp"
        config_path = str(node_payload.get("path", "")).strip()
        if not config_path:
            return "udp"
        fetched_ok, config_text = self._fetch_remote_config_text(server_safe_name, config_path)
        if not fetched_ok:
            return "udp"
        return self._read_ovpn_proto_text(config_text)

    def _complete_create_client(
        self,
        token: str,
        chat_id: str,
        protocol: str,
        name: str,
        proto_choice: str | None,
        target: str,
    ) -> None:
        if target == "local":
            manager = self._manager_from_args([protocol], require_name=False)
            result = (
                manager.create_client(name, proto=proto_choice)
                if protocol == "openvpn" and proto_choice in {"udp", "tcp"}
                else manager.create_client(name)
            )
            path_value = result.get("config") if isinstance(result, dict) else None
            if path_value and Path(path_value).exists():
                if protocol == "outline":
                    content = Path(path_value).read_text().strip()
                    if content:
                        self._send_code_message(token, chat_id, content)
                elif protocol == "xray":
                    content = Path(path_value).read_text().strip()
                    if content:
                        self._send_qr_for_link(token, chat_id, content, str(result.get("client", name)))
                else:
                    ext = "ovpn" if protocol == "openvpn" else "conf"
                    self._send_document(
                        token,
                        chat_id,
                        Path(path_value),
                        caption=f"client: {result.get('client', name)}",
                        filename_override=f"{result.get('client', name)}.{ext}",
                    )
            self._send_temporary_message(token, chat_id, self._format_result(result), delay_seconds=3)
            return

        server_item = self._find_inventory_server(target)
        if not server_item:
            raise RuntimeError("Selected server not found.")
        server_name = str(server_item.get("name", "")).strip()
        if not server_name:
            raise RuntimeError("Selected server has invalid name.")
        args = ["remote", server_name, protocol, "create-client", "--name", name]
        if protocol == "openvpn" and proto_choice in {"udp", "tcp"}:
            args.extend(["--proto", proto_choice])
        ok, payload, err = self._run_control_plane_payload(args, timeout_seconds=420)
        if not ok or not payload:
            raise RuntimeError(err or "Remote create-client failed.")
        result_obj = payload.get("result")
        if not isinstance(result_obj, dict):
            raise RuntimeError("Invalid remote response: result is missing.")
        nodes = result_obj.get("nodes")
        if not isinstance(nodes, dict):
            raise RuntimeError("Invalid remote response: nodes are missing.")
        node_result = nodes.get(server_name)
        if not isinstance(node_result, dict):
            raise RuntimeError(f"No node result for {server_name}.")
        if node_result.get("ok") is not True:
            raise RuntimeError(str(node_result.get("error") or "Remote node failed."))
        remote_payload = node_result.get("result")
        payload_dict = remote_payload if isinstance(remote_payload, dict) else {}
        config_path = node_result.get("config_path")
        if not isinstance(config_path, str):
            config_path = payload_dict.get("config")
        if not isinstance(config_path, str) or not config_path:
            raise RuntimeError("Remote config path is missing.")
        fetched_ok, config_text = self._fetch_remote_config_text(target, config_path)
        if not fetched_ok:
            raise RuntimeError(f"Cannot fetch remote config: {config_text}")
        client_label = str(payload_dict.get("client", name))
        content = config_text.strip()
        if protocol == "outline":
            if not content:
                raise RuntimeError("Remote config is empty.")
            self._send_code_message(token, chat_id, content)
        elif protocol == "xray":
            if not content:
                raise RuntimeError("Remote config is empty.")
            self._send_qr_for_link(token, chat_id, content, client_label)
        else:
            ext = "ovpn" if protocol == "openvpn" else "conf"
            tmp_path = Path(tempfile.gettempdir()) / f"vpn-remote-{secrets.token_hex(8)}.{ext}"
            try:
                tmp_path.write_text(config_text)
                self._send_document(
                    token,
                    chat_id,
                    tmp_path,
                    caption=f"client: {client_label}",
                    filename_override=f"{client_label}.{ext}",
                )
            finally:
                tmp_path.unlink(missing_ok=True)
        self._send_temporary_message(token, chat_id, self._format_result(payload_dict or remote_payload), delay_seconds=3)

    def _get_openvpn_client_proto(self) -> str:
        cfg = _load_config(self.config_path)
        proto = str(cfg.get("openvpn_client_proto", "udp")).lower()
        return proto if proto in {"udp", "tcp"} else "udp"

    def _set_openvpn_client_proto(self, proto: str) -> str:
        proto_lower = proto.lower()
        if proto_lower not in {"udp", "tcp"}:
            raise ValueError("proto must be udp or tcp")
        cfg = _load_config(self.config_path)
        cfg["openvpn_client_proto"] = proto_lower
        _save_config(self.config_path, cfg)
        return proto_lower

    def _get_openvpn_server_proto(self) -> str:
        try:
            conf = Path("/etc/openvpn/server/server.conf").read_text()
        except Exception:
            return "udp"
        for line in conf.splitlines():
            line = line.strip()
            if line.lower().startswith("proto "):
                parts = line.split()
                if len(parts) >= 2 and parts[1].lower() in {"udp", "tcp"}:
                    return parts[1].lower()
        return "udp"

    def _read_ovpn_proto(self, path: Path) -> str:
        try:
            data = path.read_text().splitlines()
        except Exception:
            return "udp"
        for line in data:
            line = line.strip()
            if line.lower().startswith("proto "):
                parts = line.split()
                if len(parts) >= 2 and parts[1].lower() in {"udp", "tcp"}:
                    return parts[1].lower()
        return "udp"

    def _read_ovpn_proto_text(self, content: str) -> str:
        for line in content.splitlines():
            clean = line.strip()
            if clean.lower().startswith("proto "):
                parts = clean.split()
                if len(parts) >= 2 and parts[1].lower() in {"udp", "tcp"}:
                    return parts[1].lower()
        return "udp"

    def _send_qr_for_link(self, token: str, chat_id: str, link: str, name: str) -> None:
        if not link.strip():
            return
        if shutil.which("qrencode") is None:
            self._send_message(token, chat_id, "qrencode is not installed, QR was not generated.")
            return
        tmp_path = Path(tempfile.gettempdir()) / f"vpn-qr-{secrets.token_hex(8)}.png"
        try:
            subprocess.run(
                ["qrencode", "-o", str(tmp_path), "-s", "8", "-m", "2", link],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._send_photo(token, chat_id, tmp_path, caption=link)
        except Exception as exc:  # noqa: BLE001
            self._send_message(token, chat_id, f"❌ Error generating QR: {exc}")
        finally:
            tmp_path.unlink(missing_ok=True)

    def status(self) -> dict[str, str | bool]:
        cfg = _load_config(self.config_path)
        allowed_users = cfg.get("allowed_users", [])
        if not isinstance(allowed_users, list):
            allowed_users = []
        return {
            "config_path": str(self.config_path),
            "token_configured": "token" in cfg and bool(cfg.get("token")),
            "chat_id": cfg.get("chat_id", ""),  # legacy
            "allowed_user_id": cfg.get("allowed_user_id", ""),
            "allowed_users": [str(u) for u in allowed_users if isinstance(u, str)],
        }

    def _allowed_users_summary(self, status: dict[str, str | bool]) -> str:
        raw_primary = str(status.get("allowed_user_id") or "").strip()
        raw_users = status.get("allowed_users") or []
        users: list[str] = []
        if isinstance(raw_users, list):
            for item in raw_users:
                text = str(item).strip()
                if text:
                    users.append(text)
        ordered: list[str] = []
        seen: set[str] = set()
        if raw_primary:
            ordered.append(f"{raw_primary} (primary)")
            seen.add(raw_primary)
        for uid in users:
            if uid in seen:
                continue
            seen.add(uid)
            ordered.append(uid)
        return ", ".join(ordered) if ordered else "(empty)"

    def configure(
        self,
        token: str | None,
        chat_id: str | None,
        allowed_user_id: str | None = None,
    ) -> dict[str, str | bool]:
        cfg = _load_config(self.config_path)
        if token:
            cfg["token"] = token.strip()
        if chat_id:
            clean_chat = chat_id.strip()
            if not clean_chat.replace("-", "").isdigit():
                raise ValueError("chat_id must contain digits only.")
            cfg["chat_id"] = clean_chat
        if allowed_user_id:
            clean_uid = allowed_user_id.strip()
            if not clean_uid.replace("-", "").isdigit():
                raise ValueError("allowed_user_id must contain digits only.")
            cfg["allowed_user_id"] = clean_uid
        _save_config(self.config_path, cfg)
        return self.status()

    def add_allowed_user(self, user_id: str) -> dict[str, str | bool]:
        clean = user_id.strip()
        if not clean.replace("-", "").isdigit():
            raise ValueError("User ID must be digits.")
        cfg = _load_config(self.config_path)
        allowed_users = cfg.get("allowed_users", [])
        if not isinstance(allowed_users, list):
            allowed_users = []
        if clean not in allowed_users:
            allowed_users.append(clean)
        cfg["allowed_users"] = allowed_users
        _save_config(self.config_path, cfg)
        return self.status()

    def remove_allowed_user(self, user_id: str) -> dict[str, str | bool]:
        clean = user_id.strip()
        cfg = _load_config(self.config_path)
        protected = str(cfg.get("allowed_user_id", "")).strip()
        if protected and clean == protected:
            raise ValueError("Cannot remove primary allowed_user_id (edit config manually).")
        allowed_users = cfg.get("allowed_users", [])
        if isinstance(allowed_users, list):
            allowed_users = [u for u in allowed_users if u != clean]
        else:
            allowed_users = []
        cfg["allowed_users"] = allowed_users
        _save_config(self.config_path, cfg)
        return self.status()

    def send_test_message(self, text: str) -> str:
        cfg = _load_config(self.config_path)
        token = cfg.get("token", "")
        chat_id = cfg.get("allowed_user_id") or (cfg.get("allowed_users") or [None])[0] or cfg.get("chat_id")
        if not token or not chat_id:
            raise RuntimeError("Configure token and at least one allowed user first.")
        self._send_message(token, chat_id, text)
        return "Message sent."

    def run_polling(self, once: bool = False) -> None:
        require_root()
        cfg = _load_config(self.config_path)
        token = cfg.get("token", "").strip()
        chat_id = cfg.get("chat_id")
        allowed_user_id = cfg.get("allowed_user_id")
        allowed_users = cfg.get("allowed_users", [])
        if not token:
            raise RuntimeError("Telegram bot token is not configured.")

        offset = None
        backoff = 1
        while True:
            try:
                updates = self._get_updates(token, offset)
                backoff = 1
            except Exception as exc:  # noqa: BLE001
                print(f"polling error: {exc}", file=sys.stderr)
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)
                continue
            for update in updates:
                offset = update.get("update_id", 0) + 1
                try:
                    self._handle_update(token, chat_id, allowed_user_id, allowed_users, update)
                except Exception as exc:  # noqa: BLE001
                    print(f"update error: {exc}", file=sys.stderr)
            if once:
                return
            time.sleep(1)

    def _handle_update(
        self,
        token: str,
        allowed_chat_id: str | None,
        allowed_user_id: str | None,
        allowed_users: list[str] | Any,
        update: dict[str, Any],
    ) -> None:
        cfg = _load_config(self.config_path)
        allowed_list = allowed_users if isinstance(allowed_users, list) else []
        allowed_set = {str(u) for u in allowed_list if isinstance(u, str)}
        allowed_uid = (allowed_user_id or cfg.get("allowed_user_id") or "").strip()
        if allowed_uid:
            allowed_set.add(allowed_uid)
        configured_chat = cfg.get("chat_id")
        if configured_chat:
            allowed_set.add(str(configured_chat))

        callback = update.get("callback_query")
        if callback:
            chat = callback.get("message", {}).get("chat", {})
            chat_id = str(chat.get("id", ""))
            actor_id = str((callback.get("from") or {}).get("id", ""))
            if not chat_id:
                return
            if allowed_set and chat_id not in allowed_set and actor_id not in allowed_set:
                self._send_message(token, chat_id, "⚠️ Bot is locked to allowed users only.")
                self._answer_callback(token, callback.get("id", ""), "Denied")
                return
            self._handle_callback(token, chat_id, callback)
            return

        message = update.get("message") or update.get("edited_message")
        if not message or "text" not in message:
            return
        chat = message.get("chat") or {}
        chat_id = str(chat.get("id", ""))
        actor_id = str((message.get("from") or {}).get("id", ""))
        text = str(message.get("text", "")).strip()
        if not chat_id or not text:
            return
        if allowed_set and chat_id not in allowed_set and actor_id not in allowed_set:
            self._send_message(token, chat_id, "⚠️ Bot is locked to allowed users only.")
            return

        lower = text.lower()
        if lower == "clients":
            self._delete_message(token, chat_id, message.get("message_id"))
            self._send_clients_choice(token, chat_id)
            return
        if lower == "protocols":
            self._delete_message(token, chat_id, message.get("message_id"))
            self._send_protocol_choice(token, chat_id)
            return
        if lower == "settings":
            self._delete_message(token, chat_id, message.get("message_id"))
            self._send_settings_menu(token, chat_id, section="root")
            return

        pending = self._pending.get(chat_id)
        if pending and pending.get("mode") == "add-user":
            self._pending.pop(chat_id, None)
            try:
                self.add_allowed_user(text)
                self._send_message(token, chat_id, f"Added: {text}")
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"❌ Error: {exc}")
            self._send_settings_menu(token, chat_id, section="users")
            return
        if pending and pending.get("mode") == "add-server-name":
            try:
                safe_name = sanitize_client_name(text)
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"Invalid server name: {exc}")
                self._send_message(token, chat_id, "Enter server name (slug):")
                return
            self._pending[chat_id] = {"mode": "add-server-country", "server_name": safe_name}
            self._send_message(token, chat_id, "Enter country (for example DE/US/NL):")
            return
        if pending and pending.get("mode") == "add-server-country":
            server_name = pending.get("server_name", "").strip()
            country = text.strip()
            if not server_name:
                self._pending.pop(chat_id, None)
                self._send_message(token, chat_id, "❌ Error: internal wizard state lost. Start again.")
                self._send_settings_menu(token, chat_id, section="servers")
                return
            if not country:
                self._send_message(token, chat_id, "Country cannot be empty. Enter it again:")
                return
            self._pending[chat_id] = {"mode": "add-server-ip", "server_name": server_name, "country": country}
            self._send_message(token, chat_id, "Enter server IP:")
            return
        if pending and pending.get("mode") == "add-server-ip":
            server_name = pending.get("server_name", "").strip()
            country = pending.get("country", "").strip()
            host = text.strip()
            if not server_name or not country:
                self._pending.pop(chat_id, None)
                self._send_message(token, chat_id, "❌ Error: internal wizard state lost. Start again.")
                self._send_settings_menu(token, chat_id, section="servers")
                return
            try:
                ipaddress.ip_address(host)
            except ValueError:
                self._send_message(token, chat_id, "Invalid IP. Enter an IPv4/IPv6 address:")
                return
            self._pending[chat_id] = {
                "mode": "add-server-password",
                "server_name": server_name,
                "country": country,
                "host": host,
            }
            self._send_message(token, chat_id, "Enter root password:")
            return
        if pending and pending.get("mode") == "add-server-password":
            server_name = pending.get("server_name", "").strip()
            country = pending.get("country", "").strip()
            host = pending.get("host", "").strip()
            password = text.strip()
            self._pending.pop(chat_id, None)
            if not server_name or not country or not host:
                self._send_message(token, chat_id, "❌ Error: internal wizard state lost. Start again.")
                self._send_settings_menu(token, chat_id, section="servers")
                return
            if not password:
                self._send_message(token, chat_id, "❌ Error: password is empty.")
                self._send_settings_menu(token, chat_id, section="servers")
                return
            servers_path = self._servers_path()
            inventory_snapshot = _load_servers(servers_path)
            try:
                self._upsert_inventory_server(server_name, country, host, password)
                self._send_message(token, chat_id, f"✅ Server saved: {server_name} ({country}) {host} user=root")
                self._send_message(token, chat_id, f"Starting auto-setup for {server_name} ...")
                safe_name = sanitize_client_name(server_name)
                ok, setup_log = self._setup_server_now(safe_name)
                self._append_server_setup_log(server_name, setup_log)
                if setup_log:
                    self._send_code_message(token, chat_id, "\n".join(setup_log))
                if ok:
                    self._send_message(token, chat_id, f"✅ Setup completed: {server_name}")
                else:
                    _save_servers(servers_path, inventory_snapshot)
                    self._send_message(token, chat_id, f"❌ Setup failed: {server_name}")
                    self._send_message(token, chat_id, "Inventory changes were rolled back: server was not added.")
            except Exception as exc:  # noqa: BLE001
                _save_servers(servers_path, inventory_snapshot)
                self._send_message(token, chat_id, f"❌ Error: {exc}")
            self._send_settings_menu(token, chat_id, section="servers")
            return
        if pending and pending.get("mode") == "create":
            protocol = pending["protocol"]
            proto_choice = pending.get("proto")
            if protocol == "openvpn" and proto_choice not in {"udp", "tcp"}:
                proto_choice = self._get_openvpn_client_proto()
            try:
                name = sanitize_client_name(text)
                server_choices = self._server_choice_items()
                if server_choices:
                    keyboard: list[list[dict[str, str]]] = [
                        [{"text": "Main", "callback_data": "create-country:local"}]
                    ]
                    for safe_server, label in server_choices:
                        keyboard.append([{"text": label[:52], "callback_data": f"create-country:{safe_server}"}])
                    self._pending[chat_id] = {
                        "mode": "create-country",
                        "protocol": protocol,
                        "proto": proto_choice or "",
                        "client_name": name,
                    }
                    self._send_message(token, chat_id, "Select country (server):", keyboard=keyboard, cleanup=True)
                    return
                self._pending.pop(chat_id, None)
                self._complete_create_client(token, chat_id, protocol, name, proto_choice, "local")
            except Exception as exc:  # noqa: BLE001
                self._pending.pop(chat_id, None)
                self._send_message(token, chat_id, f"❌ Error: {exc}")
            self._send_client_actions(token, chat_id, protocol)
            return
        if pending and pending.get("mode") == "delete-name":
            protocol = pending["protocol"]
            self._pending.pop(chat_id, None)
            try:
                manager = self._manager_from_args([protocol], require_name=False)
                name = sanitize_client_name(text)
                result = manager.delete_client(name)
                self._send_message(token, chat_id, self._format_result(result))
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"❌ Error: {exc}")
            self._send_client_actions(token, chat_id, protocol)
            return

        self._send_main_menu(token, chat_id)

    def _handle_callback(self, token: str, chat_id: str, callback: dict[str, Any]) -> None:
        data = str(callback.get("data", ""))
        cb_id = callback.get("id", "")
        if not data:
            return
        if data == "main":
            self._send_main_menu(token, chat_id)
            self._answer_callback(token, cb_id, "Ok")
            return
        if data.startswith("proto-menu:"):
            protocol = data.split(":", 1)[1]
            self._send_protocol_actions(token, chat_id, protocol)
            self._answer_callback(token, cb_id, "Ok")
            return
        if data.startswith("client-menu:"):
            protocol = data.split(":", 1)[1]
            self._send_client_actions(token, chat_id, protocol)
            self._answer_callback(token, cb_id, "Ok")
            return
        if data == "settings":
            self._send_settings_menu(token, chat_id, section="root")
            self._answer_callback(token, cb_id, "Ok")
            return
        if data == "settings-users":
            self._send_settings_menu(token, chat_id, section="users")
            self._answer_callback(token, cb_id, "Ok")
            return
        if data == "settings-servers":
            self._send_settings_menu(token, chat_id, section="servers")
            self._answer_callback(token, cb_id, "Ok")
            return
        if data == "add-user":
            self._pending[chat_id] = {"mode": "add-user"}
            self._send_message(token, chat_id, "Enter User ID (digits):")
            self._answer_callback(token, cb_id, "Waiting")
            return
        if data == "add-server":
            self._pending[chat_id] = {"mode": "add-server-name"}
            self._send_message(token, chat_id, "Enter server name (slug):")
            self._answer_callback(token, cb_id, "Waiting")
            return
        if data == "list-servers":
            summary = self._inventory_summary()
            self._send_settings_menu(token, chat_id, section="servers", notice=f"Server list:\n{summary}")
            self._answer_callback(token, cb_id, "Done")
            return
        if data == "ping-servers":
            ping_status = self._servers_ping_status_text()
            self._send_settings_menu(token, chat_id, section="servers", notice=ping_status)
            self._answer_callback(token, cb_id, "Done")
            return
        if data.startswith("server-info:"):
            safe_name = data.split(":", 1)[1]
            item = self._find_inventory_server(safe_name)
            if not item:
                self._send_settings_menu(token, chat_id, section="servers", notice="❌ Server not found.")
                self._answer_callback(token, cb_id, "Missing")
                return
            mark = "ON" if item.get("enabled") else "OFF"
            info_text = (
                "server:\n"
                f"name: {item.get('name')}\n"
                f"country: {item.get('country')}\n"
                f"host: {item.get('host')}\n"
                f"user: {item.get('user')}\n"
                f"enabled: {mark}"
            )
            self._send_settings_menu(token, chat_id, section="servers", notice=info_text)
            self._answer_callback(token, cb_id, "Done")
            return
        if data.startswith("remove-server:"):
            safe_name = data.split(":", 1)[1]
            removed = self._remove_inventory_server(safe_name)
            if removed:
                notice = "✅ Server removed."
            else:
                notice = "❌ Server not found."
            self._send_settings_menu(token, chat_id, section="servers", notice=notice)
            self._answer_callback(token, cb_id, "Done")
            return
        if data == "remove-user-list":
            self._send_settings_menu(token, chat_id, show_remove=True, section="users")
            self._answer_callback(token, cb_id, "Ok")
            return
        if data.startswith("remove-user:"):
            user_id = data.split(":", 1)[1]
            try:
                self.remove_allowed_user(user_id)
                notice = f"Removed: {user_id}"
            except Exception as exc:  # noqa: BLE001
                notice = f"❌ Error: {exc}"
            self._send_settings_menu(token, chat_id, section="users", notice=notice)
            self._answer_callback(token, cb_id, "Done")
            return
        if data.startswith("install:") or data.startswith("uninstall:"):
            action, protocol = data.split(":", 1)
            if action == "install":
                self._send_message(token, chat_id, f"Installing {protocol} started...")
            response = self._run_control_plane(["remote-all", protocol, action])
            self._send_message(token, chat_id, response)
            self._send_protocol_actions(token, chat_id, protocol)
            self._answer_callback(token, cb_id, "Done")
            return
        if data.startswith("clients:"):
            protocol = data.split(":", 1)[1]
            response = self._wrap(self._cmd_clients)([protocol])
            self._send_message(token, chat_id, response)
            self._answer_callback(token, cb_id, "Listed")
            return
        if data == "status:protocols":
            message = self._protocols_status_text()
            status_message_id = self._send_message(token, chat_id, message)
            if isinstance(status_message_id, int):
                self._schedule_message_delete(token, chat_id, status_message_id, delay_seconds=10)
            self._answer_callback(token, cb_id, "Status shown")
            return
        if data in {"install-all", "uninstall-all"}:
            is_install = data == "install-all"
            action_label = "Install" if is_install else "Uninstall"
            action = "install" if is_install else "uninstall"
            self._send_message(token, chat_id, f"{action_label} all protocols started...")
            for proto in ["amneziawg", "openvpn", "outline", "xray"]:
                response = self._run_control_plane(["remote-all", proto, action])
                self._send_message(token, chat_id, f"{proto}:\n{response}")
            self._send_protocol_choice(token, chat_id)
            self._answer_callback(token, cb_id, "Done")
            return
        if data.startswith("create:"):
            protocol = data.split(":", 1)[1]
            if protocol == "openvpn":
                keyboard = [
                    [
                        {"text": "udp", "callback_data": f"create-proto:{protocol}:udp"},
                        {"text": "tcp", "callback_data": f"create-proto:{protocol}:tcp"},
                    ]
                ]
                self._pending[chat_id] = {"mode": "create-proto", "protocol": protocol}
                self._send_message(token, chat_id, "Select protocol for client:", keyboard=keyboard, cleanup=True)
                self._answer_callback(token, cb_id, "Choose proto")
            else:
                self._pending[chat_id] = {"mode": "create", "protocol": protocol}
                self._send_message(token, chat_id, "Enter client name (a-z, 0-9, _ , -):", cleanup=True)
                self._answer_callback(token, cb_id, "Waiting for name")
            return
        if data.startswith("create-proto:"):
            _, protocol, proto = data.split(":", 2)
            proto = proto.lower()
            if proto not in {"udp", "tcp"}:
                self._answer_callback(token, cb_id, "Invalid proto")
                return
            self._pending[chat_id] = {"mode": "create", "protocol": protocol, "proto": proto}
            self._send_message(
                token,
                chat_id,
                f"Enter client name (OpenVPN {proto.upper()}) (a-z, 0-9, _ , -):",
                cleanup=True,
            )
            self._answer_callback(token, cb_id, "Waiting for name")
            return
        if data.startswith("create-country:"):
            target = data.split(":", 1)[1]
            pending = self._pending.get(chat_id)
            if not pending or pending.get("mode") != "create-country":
                self._answer_callback(token, cb_id, "Expired")
                self._send_message(token, chat_id, "Client creation session expired. Run Create again.")
                return
            protocol = str(pending.get("protocol", "")).strip()
            client_name = str(pending.get("client_name", "")).strip()
            proto_choice = str(pending.get("proto", "")).strip() or None
            self._pending.pop(chat_id, None)
            try:
                self._complete_create_client(token, chat_id, protocol, client_name, proto_choice, target)
                self._answer_callback(token, cb_id, "Done")
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"❌ Error: {exc}")
                self._answer_callback(token, cb_id, "Failed")
            self._send_client_actions(token, chat_id, protocol)
            return
        if data.startswith("delete:"):
            parts = data.split(":")
            if len(parts) == 3:
                _, protocol, name = parts
                target = "local"
            elif len(parts) == 4:
                _, protocol, target, name = parts
            else:
                self._answer_callback(token, cb_id, "Invalid")
                return
            safe = sanitize_client_name(name)
            target_label = "Main" if target == "local" else target
            self._send_temporary_message(token, chat_id, f"Deleting: {safe} ({target_label}) ...", delay_seconds=3)
            try:
                if target == "local":
                    response = self._cmd_delete([protocol, safe])
                else:
                    server_item = self._find_inventory_server(target)
                    if not server_item:
                        raise RuntimeError("Selected server not found.")
                    server_name = str(server_item.get("name", "")).strip()
                    if not server_name:
                        raise RuntimeError("Selected server has invalid name.")
                    ok, payload, err = self._run_control_plane_payload(
                        ["remote", server_name, protocol, "delete-client", "--name", safe],
                        timeout_seconds=300,
                    )
                    if not ok:
                        raise RuntimeError(err or "Remote delete-client failed.")
                    node_ok, node_payload, node_err = self._extract_remote_node_payload(payload, server_name)
                    if not node_ok:
                        raise RuntimeError(node_err)
                    response = self._format_result(node_payload)
                self._send_temporary_message(token, chat_id, f"✅ Deleted: {safe}", delay_seconds=3)
                if response:
                    self._send_temporary_message(token, chat_id, response, delay_seconds=3)
                self._send_client_actions(token, chat_id, protocol)
                self._answer_callback(token, cb_id, "Deleted")
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"❌ Error: {exc}")
                self._answer_callback(token, cb_id, "Failed")
            return
        if data.startswith("config:"):
            parts = data.split(":")
            if len(parts) == 3:
                _, protocol, name = parts
                target = "local"
            elif len(parts) == 4:
                _, protocol, target, name = parts
            else:
                self._answer_callback(token, cb_id, "Invalid")
                return
            try:
                safe_name = sanitize_client_name(name)
                if target == "local":
                    manager = self._manager_from_args([protocol, safe_name], require_name=True)
                    info = manager.show_client_config_path(safe_name)
                    path_value = info.get("path")
                    if not path_value:
                        raise RuntimeError("Config path not found.")
                    file_path = Path(path_value)
                    client_label = info.get("client", safe_name)
                    if protocol == "outline":
                        content = file_path.read_text().strip() if file_path.exists() else ""
                        if not content:
                            raise RuntimeError("Key file is empty.")
                        self._send_code_message(token, chat_id, content)
                        self._answer_callback(token, cb_id, "Config sent")
                    elif protocol == "xray":
                        content = file_path.read_text().strip() if file_path.exists() else ""
                        if not content:
                            raise RuntimeError("Key file is empty.")
                        self._send_qr_for_link(token, chat_id, content, client_label)
                        self._answer_callback(token, cb_id, "Config sent")
                    else:
                        proto_label = ""
                        if protocol == "openvpn":
                            proto_label = f" [{self._read_ovpn_proto(file_path).upper()}]"
                        caption = f"client: {client_label}{proto_label}"
                        ext = "ovpn" if protocol == "openvpn" else "conf"
                        download_name = f"{client_label}.{ext}"
                        self._send_document(
                            token,
                            chat_id,
                            file_path,
                            caption=caption,
                            strip_indent=True,
                            filename_override=download_name,
                        )
                        self._answer_callback(token, cb_id, "Config sent")
                else:
                    server_item = self._find_inventory_server(target)
                    if not server_item:
                        raise RuntimeError("Selected server not found.")
                    server_name = str(server_item.get("name", "")).strip()
                    if not server_name:
                        raise RuntimeError("Selected server has invalid name.")
                    ok, payload, err = self._run_control_plane_payload(
                        ["remote", server_name, protocol, "show-client-config-path", "--name", safe_name],
                        timeout_seconds=240,
                    )
                    if not ok:
                        raise RuntimeError(err or "Remote show-client-config-path failed.")
                    node_ok, node_payload, node_err = self._extract_remote_node_payload(payload, server_name)
                    if not node_ok:
                        raise RuntimeError(node_err)
                    info = node_payload if isinstance(node_payload, dict) else {}
                    path_value = str(info.get("path", "")).strip()
                    if not path_value:
                        raise RuntimeError("Remote config path not found.")
                    fetched_ok, config_text = self._fetch_remote_config_text(target, path_value)
                    if not fetched_ok:
                        raise RuntimeError(f"Cannot fetch remote config: {config_text}")
                    client_label = str(info.get("client", safe_name)).strip() or safe_name
                    content = config_text.strip()
                    if protocol == "outline":
                        if not content:
                            raise RuntimeError("Key file is empty.")
                        self._send_code_message(token, chat_id, content)
                        self._answer_callback(token, cb_id, "Config sent")
                    elif protocol == "xray":
                        if not content:
                            raise RuntimeError("Key file is empty.")
                        self._send_qr_for_link(token, chat_id, content, client_label)
                        self._answer_callback(token, cb_id, "Config sent")
                    else:
                        ext = "ovpn" if protocol == "openvpn" else "conf"
                        proto_label = ""
                        if protocol == "openvpn":
                            proto_label = f" [{self._read_ovpn_proto_text(config_text).upper()}]"
                        tmp_path = Path(tempfile.gettempdir()) / f"vpn-remote-{secrets.token_hex(8)}.{ext}"
                        try:
                            tmp_path.write_text(config_text)
                            self._send_document(
                                token,
                                chat_id,
                                tmp_path,
                                caption=f"client: {client_label}{proto_label}",
                                strip_indent=True,
                                filename_override=f"{client_label}.{ext}",
                            )
                            self._answer_callback(token, cb_id, "Config sent")
                        finally:
                            tmp_path.unlink(missing_ok=True)
            except Exception as exc:  # noqa: BLE001
                self._send_message(token, chat_id, f"❌ Error: {exc}")
                self._answer_callback(token, cb_id, "Failed")
            self._send_client_actions(token, chat_id, protocol)
            return
        if data.startswith("delete-name:"):
            protocol = data.split(":", 1)[1]
            self._pending[chat_id] = {"mode": "delete-name", "protocol": protocol}
            self._send_message(token, chat_id, "Enter client name to delete:")
            self._answer_callback(token, cb_id, "Waiting for name")
            return
        self._answer_callback(token, cb_id, "Unknown action")


    def _wrap(self, func: Callable[[list[str]], str]) -> Callable[[list[str]], str]:
        def wrapper(args: list[str]) -> str:
            try:
                return func(args)
            except Exception as exc:  # noqa: BLE001
                return f"❌ Error: {exc}"

        return wrapper

    def _cmd_help(self, _: list[str]) -> str:
        return (
            "Commands:\n"
            " /status — bot status\n"
            " /install <protocol>\n"
            " /uninstall <protocol>\n"
            " /clients <protocol>\n"
            " /create <protocol> <name>\n"
            " /delete <protocol> <name>\n"
            " /config <protocol> <name>\n"
            "Protocols: amneziawg, openvpn, outline, xray"
        )

    def _cmd_status(self, _: list[str]) -> str:
        st = self.status()
        token_state = "yes" if st["token_configured"] else "no"
        chat_value = st["chat_id"] or "(not set)"
        return f"Token: {token_state}\nChat: {chat_value}\nConfig: {st['config_path']}"

    def _cmd_install(self, args: list[str]) -> str:
        protocol = args[0].lower()
        return self._run_control_plane(["remote-all", protocol, "install"])

    def _cmd_uninstall(self, args: list[str]) -> str:
        protocol = args[0].lower()
        return self._run_control_plane(["remote-all", protocol, "uninstall"])

    def _cmd_clients(self, args: list[str]) -> str:
        manager = self._manager_from_args(args)
        items = manager.list_clients()
        return "\n".join(items) if items else "No clients."

    def _cmd_create(self, args: list[str]) -> str:
        manager = self._manager_from_args(args, require_name=True)
        name = sanitize_client_name(args[1])
        result = manager.create_client(name)
        return self._format_result(result)

    def _cmd_delete(self, args: list[str]) -> str:
        manager = self._manager_from_args(args, require_name=True)
        name = sanitize_client_name(args[1])
        result = manager.delete_client(name)
        return self._format_result(result)

    def _cmd_config(self, args: list[str]) -> str:
        manager = self._manager_from_args(args, require_name=True)
        name = sanitize_client_name(args[1])
        result = manager.show_client_config_path(name)
        return self._format_result(result)

    def _parse_client_entry(self, item: str) -> tuple[str, str]:
        if "\t" in item:
            left, right = item.split("\t", 1)
            return left.strip(), right.strip()
        if " " in item:
            left, right = item.split(" ", 1)
            return left.strip(), right.strip()
        return item.strip(), ""

    def _manager_from_args(self, args: list[str], require_name: bool = False):
        if not args:
            raise ValueError("Protocol is required.")
        protocol = args[0].lower()
        if require_name and len(args) < 2:
            raise ValueError("Client name is required.")
        if protocol == "amneziawg":
            return AmneziaWGManager(repo_root=self.repo_root)
        if protocol == "openvpn":
            return OpenVPNManager(repo_root=self.repo_root)
        if protocol == "outline":
            return OutlineManager(repo_root=self.repo_root)
        if protocol == "xray":
            return XrayRealityManager(repo_root=self.repo_root)
        raise ValueError("Unsupported protocol.")

    def _format_result(self, result) -> str:
        if isinstance(result, dict):
            return "\n".join(f"{k}: {v}" for k, v in result.items())
        if isinstance(result, list):
            return "\n".join(str(item) for item in result)
        return str(result)

    def _protocol_installed(self, protocol: str) -> bool:
        if protocol == "amneziawg":
            return shutil.which("awg") is not None and Path("/etc/amnezia/amneziawg/awg0.conf").exists()
        if protocol == "openvpn":
            return shutil.which("openvpn") is not None and Path("/etc/openvpn/server/server.conf").exists()
        if protocol == "outline":
            return Path("/usr/local/bin/outline-ss-server").exists() and (
                Path("/etc/outline-ss-server/config.json").exists() or Path("/etc/outline-ss-server/config.yml").exists()
            )
        if protocol == "xray":
            return Path("/usr/local/bin/xray").exists() and Path("/usr/local/etc/xray/config.json").exists()
        raise ValueError("Unsupported protocol.")

    def _protocols_status_text(self) -> str:
        names = {"amneziawg": "AmneziaWG", "openvpn": "OpenVPN", "outline": "Outline", "xray": "Xray"}
        entries = []
        for proto in ["amneziawg", "openvpn", "outline", "xray"]:
            installed = self._protocol_installed(proto)
            mark = "✅" if installed else "❌"
            extra = ""
            entries.append(f"{names.get(proto, proto.title())}: {mark}{extra}")
        return "\n".join(entries)

    def _servers_ping_status_text(self) -> str:
        ok, payload, err = self._run_control_plane_payload(["remote-all", "backend", "ping"], timeout_seconds=180)
        if not ok or not payload:
            return f"❌ Error: {err or 'ping failed'}"
        result_obj = payload.get("result")
        if not isinstance(result_obj, dict):
            return "❌ Error: invalid ping response payload."

        lines: list[str] = ["Server reachability:"]

        local_result = result_obj.get("local")
        if isinstance(local_result, dict):
            if local_result.get("ok") is True:
                local_payload = local_result.get("result")
                local_host = "main"
                if isinstance(local_payload, dict):
                    local_host = str(local_payload.get("host", "main")).strip() or "main"
                lines.append(f"Main: ✅ ok ({local_host})")
            else:
                local_error = str(local_result.get("error") or "local ping failed")
                lines.append(f"Main: ❌ {local_error[:220]}")

        inventory_by_name: dict[str, dict[str, object]] = {}
        for item in self._inventory_servers():
            name = str(item.get("name", "")).strip()
            if name:
                inventory_by_name[name] = item

        nodes_result = result_obj.get("nodes")
        if isinstance(nodes_result, dict):
            for node_name, node_value in nodes_result.items():
                node_name_text = str(node_name).strip() or "unknown"
                item = inventory_by_name.get(node_name_text)
                if item:
                    country = str(item.get("country", "")).strip() or "-"
                    label = f"{node_name_text} ({country})"
                else:
                    label = node_name_text
                if not isinstance(node_value, dict):
                    lines.append(f"{label}: ❌ invalid node response")
                    continue
                if node_value.get("ok") is True:
                    node_payload = node_value.get("result")
                    remote_host = ""
                    if isinstance(node_payload, dict):
                        remote_host = str(node_payload.get("host", "")).strip()
                    suffix = f" ({remote_host})" if remote_host else ""
                    lines.append(f"{label}: ✅ ok{suffix}")
                else:
                    node_error = str(node_value.get("error") or "remote ping failed")
                    lines.append(f"{label}: ❌ {node_error[:220]}")

        summary = result_obj.get("summary")
        if isinstance(summary, dict):
            total = int(summary.get("total", 0) or 0)
            ok_count = int(summary.get("ok", 0) or 0)
            failed = int(summary.get("failed", 0) or 0)
            lines.append("")
            lines.append(f"Summary: total={total}, ok={ok_count}, failed={failed}")
        return "\n".join(lines)

    def _get_updates(self, token: str, offset: int | None) -> list[dict]:
        payload = {"timeout": "25"}
        if offset is not None:
            payload["offset"] = str(offset)
        raw = self._api_call(token, "getUpdates", payload)
        if not isinstance(raw, list):
            return []
        return [u for u in raw if isinstance(u, dict)]

    def _send_message(
        self,
        token: str,
        chat_id: str,
        text: str,
        keyboard: list[list[dict[str, str]]] | None = None,
        reply_keyboard: list[list[str]] | None = None,
        cleanup: bool = False,
    ) -> int | None:
        if cleanup:
            prev_id = self._last_menu_message.get(chat_id)
            if prev_id:
                self._delete_message(token, chat_id, prev_id)
        payload: dict[str, Any] = {"chat_id": chat_id, "text": text}
        if keyboard:
            payload["reply_markup"] = {"inline_keyboard": keyboard}
        elif reply_keyboard:
            payload["reply_markup"] = {"keyboard": [[{"text": item} for item in row] for row in reply_keyboard], "resize_keyboard": True}
        result = self._api_call(token, "sendMessage", payload)
        message_id: int | None = None
        if isinstance(result, dict):
            current_id = result.get("message_id")
            if isinstance(current_id, int):
                message_id = current_id
        if cleanup and isinstance(result, dict):
            message_id = result.get("message_id")
            if isinstance(message_id, int):
                self._last_menu_message[chat_id] = message_id
        return message_id

    def _schedule_message_delete(self, token: str, chat_id: str, message_id: int, delay_seconds: int) -> None:
        wait_seconds = max(1, delay_seconds)

        def _delete_later() -> None:
            time.sleep(wait_seconds)
            self._delete_message(token, chat_id, message_id)

        threading.Thread(target=_delete_later, daemon=True).start()

    def _send_temporary_message(self, token: str, chat_id: str, text: str, delay_seconds: int) -> None:
        message_id = self._send_message(token, chat_id, text)
        if isinstance(message_id, int):
            self._schedule_message_delete(token, chat_id, message_id, delay_seconds=delay_seconds)

    def _send_code_message(self, token: str, chat_id: str, text: str) -> None:
        payload: dict[str, Any] = {
            "chat_id": chat_id,
            "text": f"<code>{html.escape(text)}</code>",
            "parse_mode": "HTML",
        }
        self._api_call(token, "sendMessage", payload)

    def _send_document(
        self,
        token: str,
        chat_id: str,
        file_path: Path,
        caption: str | None = None,
        strip_indent: bool = False,
        filename_override: str | None = None,
    ) -> None:
        if not file_path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")
        url = f"https://api.telegram.org/bot{token}/sendDocument"
        boundary = f"--------------{secrets.token_hex(12)}"
        parts: list[bytes] = []

        def _field(name: str, value: str) -> bytes:
            return (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode()

        parts.append(_field("chat_id", str(chat_id)))
        if caption:
            parts.append(_field("caption", caption))
        file_bytes = file_path.read_bytes()
        if strip_indent:
            try:
                text = file_bytes.decode("utf-8", errors="replace")
                text = textwrap.dedent(text)
                lines = text.splitlines()
                expanded = [ln.expandtabs(4) for ln in lines]
                # Remove all leading spaces/tabs from each non-empty line.
                stripped_lines = [ln.lstrip(" \t") if ln.strip() else "" for ln in expanded]
                text = "\n".join(stripped_lines)
                file_bytes = text.encode("utf-8")
            except Exception:
                pass
        filename = file_path.name
        parts.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="document"; filename="{filename_override or filename}"\r\n'
                "Content-Type: application/octet-stream\r\n\r\n"
            ).encode()
        )
        parts.append(file_bytes)
        parts.append(b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)

        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with urllib.request.urlopen(request, timeout=35) as resp:
            response_body = resp.read().decode()
        parsed = json.loads(response_body)
        if not parsed.get("ok"):
            description = parsed.get("description", "Telegram API error.")
            raise RuntimeError(description)

    def _send_photo(self, token: str, chat_id: str, file_path: Path, caption: str | None = None) -> None:
        if not file_path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")
        url = f"https://api.telegram.org/bot{token}/sendPhoto"
        boundary = f"--------------{secrets.token_hex(12)}"
        parts: list[bytes] = []

        def _field(name: str, value: str) -> bytes:
            return (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode()

        parts.append(_field("chat_id", str(chat_id)))
        if caption:
            parts.append(_field("caption", f"<code>{html.escape(caption)}</code>"))
            parts.append(_field("parse_mode", "HTML"))
        image_bytes = file_path.read_bytes()
        parts.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="photo"; filename="{file_path.name}"\r\n'
                "Content-Type: image/png\r\n\r\n"
            ).encode()
        )
        parts.append(image_bytes)
        parts.append(b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)

        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with urllib.request.urlopen(request, timeout=35) as resp:
            response_body = resp.read().decode()
        parsed = json.loads(response_body)
        if not parsed.get("ok"):
            description = parsed.get("description", "Telegram API error.")
            raise RuntimeError(description)

    def _answer_callback(self, token: str, callback_id: str, text: str) -> None:
        if not callback_id:
            return
        payload: dict[str, Any] = {"callback_query_id": callback_id, "text": text, "show_alert": False}
        self._api_call(token, "answerCallbackQuery", payload)

    def _delete_message(self, token: str, chat_id: str, message_id: int) -> None:
        if not message_id:
            return
        try:
            self._api_call(token, "deleteMessage", {"chat_id": chat_id, "message_id": str(message_id)})
        except Exception:
            pass

    def _api_call(self, token: str, method: str, payload: dict[str, Any]) -> object:
        url = f"https://api.telegram.org/bot{token}/{method}"
        payload_encoded: dict[str, str] = {}
        for key, value in payload.items():
            if key == "reply_markup" and isinstance(value, dict):
                payload_encoded[key] = json.dumps(value)
            else:
                payload_encoded[key] = str(value)
        data = urllib.parse.urlencode(payload_encoded).encode()
        request = urllib.request.Request(url, data=data, method="POST")
        with urllib.request.urlopen(request, timeout=35) as resp:
            body = resp.read().decode()
        parsed = json.loads(body)
        if not parsed.get("ok"):
            description = parsed.get("description", "Telegram API error.")
            raise RuntimeError(description)
        return parsed.get("result", {})

    def _send_main_menu(self, token: str, chat_id: str) -> None:
        self._send_message(
            token,
            chat_id,
            "Choose section:",
            reply_keyboard=[["Clients", "Protocols"], ["Settings"]],
            cleanup=True,
        )

    def _send_protocol_choice(self, token: str, chat_id: str) -> None:
        keyboard = [
            [
                {"text": "AmneziaWG", "callback_data": "proto-menu:amneziawg"},
                {"text": "OpenVPN", "callback_data": "proto-menu:openvpn"},
            ],
            [
                {"text": "Outline", "callback_data": "proto-menu:outline"},
                {"text": "Xray", "callback_data": "proto-menu:xray"},
            ],
            [
                {"text": "Install all", "callback_data": "install-all"},
                {"text": "Uninstall all", "callback_data": "uninstall-all"},
            ],
            [
                {"text": "Status", "callback_data": "status:protocols"},
            ],
            [{"text": "Back", "callback_data": "main"}],
        ]
        self._send_message(token, chat_id, "Protocols: select protocol", keyboard=keyboard, cleanup=True)

    def _send_clients_choice(self, token: str, chat_id: str) -> None:
        keyboard = [
            [
                {"text": "AmneziaWG", "callback_data": "client-menu:amneziawg"},
                {"text": "OpenVPN", "callback_data": "client-menu:openvpn"},
                {"text": "Outline", "callback_data": "client-menu:outline"},
                {"text": "Xray", "callback_data": "client-menu:xray"},
            ],
            [{"text": "Back", "callback_data": "main"}],
        ]
        self._send_message(token, chat_id, "Clients: select protocol", keyboard=keyboard, cleanup=True)

    def _send_protocol_actions(self, token: str, chat_id: str, protocol: str) -> None:
        keyboard = [
            [
                {"text": "Install", "callback_data": f"install:{protocol}"},
                {"text": "Uninstall", "callback_data": f"uninstall:{protocol}"},
            ],
            [{"text": "Back", "callback_data": "main"}],
        ]
        self._send_message(token, chat_id, f"{protocol}: protocol actions", keyboard=keyboard, cleanup=True)

    def _send_client_actions(self, token: str, chat_id: str, protocol: str) -> None:
        keyboard: list[list[dict[str, str]]] = []
        summary: list[str] = []
        warnings: list[str] = []
        manager = self._manager_from_args([protocol], require_name=False)
        try:
            names = manager.list_clients()
            for raw in names:
                raw_name = str(raw).strip()
                if not raw_name:
                    continue
                ip = ""
                if protocol == "amneziawg":
                    raw_name, ip = self._parse_client_entry(raw_name)
                    if not raw_name or ip == "10.8.1.2":
                        continue
                try:
                    safe = sanitize_client_name(raw_name)
                except Exception:
                    continue
                display_name = f"{raw_name} ({ip})" if ip else raw_name
                if protocol == "openvpn":
                    proto = "udp"
                    try:
                        info = manager.show_client_config_path(safe)
                        path_value = info.get("path")
                        if path_value:
                            proto = self._read_ovpn_proto(Path(path_value))
                    except Exception:
                        proto = "udp"
                    display_name = f"{raw_name} [{proto.upper()}]"
                summary.append(f"{display_name} — Main")
                button_text = f"{display_name} · Main"[:52]
                keyboard.append(
                    [
                        {"text": button_text, "callback_data": f"config:{protocol}:local:{safe}"},
                        {"text": "Delete", "callback_data": f"delete:{protocol}:local:{safe}"},
                    ]
                )
        except Exception as exc:
            warnings.append(f"Main: {exc}")

        for server_safe, server_label in self._server_choice_items():
            server_item = self._find_inventory_server(server_safe)
            if not server_item:
                continue
            server_name = str(server_item.get("name", "")).strip()
            if not server_name:
                continue
            ok, payload, err = self._run_control_plane_payload(
                ["remote", server_name, protocol, "list-clients"],
                timeout_seconds=240,
            )
            if not ok:
                warnings.append(f"{server_label}: {err or 'list failed'}")
                continue
            node_ok, node_payload, node_err = self._extract_remote_node_payload(payload, server_name)
            if not node_ok:
                warnings.append(f"{server_label}: {node_err}")
                continue
            if not isinstance(node_payload, list):
                warnings.append(f"{server_label}: invalid list format")
                continue
            for raw in node_payload:
                raw_name = str(raw).strip()
                if not raw_name:
                    continue
                ip = ""
                if protocol == "amneziawg":
                    raw_name, ip = self._parse_client_entry(raw_name)
                    if not raw_name or ip == "10.8.1.2":
                        continue
                try:
                    safe = sanitize_client_name(raw_name)
                except Exception:
                    continue
                display_name = f"{raw_name} ({ip})" if ip else raw_name
                if protocol == "openvpn":
                    remote_proto = self._remote_openvpn_client_proto(server_safe, safe)
                    display_name = f"{raw_name} [{remote_proto.upper()}]"
                summary.append(f"{display_name} — {server_label}")
                button_text = f"{display_name} · {server_label}"[:52]
                keyboard.append(
                    [
                        {"text": button_text, "callback_data": f"config:{protocol}:{server_safe}:{safe}"},
                        {"text": "Delete", "callback_data": f"delete:{protocol}:{server_safe}:{safe}"},
                    ]
                )

        keyboard.append([{"text": "Create", "callback_data": f"create:{protocol}"}])
        keyboard.append([{"text": "Back", "callback_data": "main"}])
        list_text = "\n".join(summary) if summary else "No clients yet."
        if warnings:
            list_text = f"{list_text}\n\n⚠ {'; '.join(warnings[:3])}"
        title = "AmneziaWG" if protocol == "amneziawg" else protocol
        self._send_message(token, chat_id, f"{title} - client list:\n{list_text}", keyboard=keyboard, cleanup=True)

    def _send_settings_menu(
        self,
        token: str,
        chat_id: str,
        show_remove: bool = False,
        section: str = "root",
        notice: str = "",
    ) -> None:
        status = self.status()
        allowed = status.get("allowed_users") or []
        summary = self._allowed_users_summary(status)
        servers_info = self._inventory_summary()
        notice_text = notice.strip()
        notice_block = f"{notice_text}\n\n" if notice_text else ""

        if section == "users":
            keyboard = [
                [{"text": "Add user", "callback_data": "add-user"}],
                [{"text": "Remove user", "callback_data": "remove-user-list"}],
            ]
            if show_remove:
                protected = status.get("allowed_user_id") or ""
                removable = [u for u in allowed if u != protected]
                if removable:
                    rows: list[list[dict[str, str]]] = []
                    row: list[dict[str, str]] = []
                    for uid in removable:
                        row.append({"text": f"Del {uid}", "callback_data": f"remove-user:{uid}"})
                        if len(row) == 3:
                            rows.append(row)
                            row = []
                    if row:
                        rows.append(row)
                    keyboard = rows
                else:
                    keyboard = []
            keyboard.append([{"text": "Back", "callback_data": "settings"}])
            self._send_message(
                token,
                chat_id,
                f"{notice_block}User Settings\nAllowed users: {summary}",
                keyboard=keyboard,
                cleanup=True,
            )
            return

        if section == "servers":
            keyboard = [
                [{"text": "Add server", "callback_data": "add-server"}],
                [{"text": "List servers", "callback_data": "list-servers"}],
                [{"text": "Ping servers", "callback_data": "ping-servers"}],
            ]
            for item in self._inventory_servers():
                name = str(item.get("name", "")).strip()
                if not name:
                    continue
                try:
                    safe_name = sanitize_client_name(name)
                except Exception:
                    continue
                country = str(item.get("country", "")).strip() or "-"
                mark = "ON" if item.get("enabled") else "OFF"
                label = f"{name} ({country}) [{mark}]"
                keyboard.append(
                    [
                        {"text": label[:42], "callback_data": f"server-info:{safe_name}"},
                        {"text": "Delete", "callback_data": f"remove-server:{safe_name}"},
                    ]
                )
            keyboard.append([{"text": "Back", "callback_data": "settings"}])
            self._send_message(
                token,
                chat_id,
                f"{notice_block}Server Settings\nServers:\n{servers_info}",
                keyboard=keyboard,
                cleanup=True,
            )
            return

        keyboard = [
            [{"text": "User Settings", "callback_data": "settings-users"}],
            [{"text": "Server Settings", "callback_data": "settings-servers"}],
            [{"text": "Back", "callback_data": "main"}],
        ]
        self._send_message(
            token,
            chat_id,
            f"{notice_block}Settings\nAllowed users: {summary}\n\nServers:\n{servers_info}",
            keyboard=keyboard,
            cleanup=True,
        )
