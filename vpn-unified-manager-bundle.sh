#!/bin/sh
# Creates vpn_manager.py + vpn_protocols/ under TARGET.
# Default TARGET: $SUDO_USER home + /vpn-unified-manager (so "sudo ./script" -> ~that user).
# Plain file bodies via heredocs - no git, no tar. Regenerate: ./scripts/regenerate-bundle.sh
set -eu

GLOBAL=0
TARGET=""
BOOTSTRAP_MODE="auto"
BOOTSTRAP_HANDOFF="${BOOTSTRAP_HANDOFF:-0}"

usage() {
  echo "Usage: sudo $0 [--dir PATH] [--global] [--bootstrap|--no-bootstrap]" >&2
  echo "  --dir PATH   install dir (default: HOME/vpn-unified-manager of invoking user)" >&2
  echo "  --global     install /usr/local/bin/vpn-manager" >&2
  echo "  --bootstrap  run VPS bootstrap (user/ssh/profile), then deploy as new user" >&2
  echo "  --no-bootstrap  skip bootstrap step" >&2
  exit 1
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

trim_ws() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      if [ "$#" -lt 2 ]; then
        echo "error: --dir requires a path" >&2
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --global)
      GLOBAL=1
      shift
      ;;
    --bootstrap)
      BOOTSTRAP_MODE="on"
      shift
      ;;
    --no-bootstrap)
      BOOTSTRAP_MODE="off"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if ! is_root && [ "$BOOTSTRAP_HANDOFF" != "1" ]; then
  echo "Run as root: sudo $0 ..." >&2
  exit 1
fi

if [ "$GLOBAL" -eq 1 ] && ! is_root; then
  echo "error: --global requires root" >&2
  exit 1
fi

ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  if ! is_root; then
    echo "error: python3 is required in handoff mode (install it before retry)" >&2
    exit 1
  fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y python3
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y python3
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    yum install -y python3
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python
    return
  fi
  if command -v zypper >/dev/null 2>&1; then
    zypper install -y python3
    return
  fi
  echo "error: python3 not found and could not auto-install for this distro" >&2
  exit 1
}

ensure_controller_ssh_key() {
  profile_dir="/etc/vpn-unified-manager"
  key_dir="$profile_dir/keys"
  key_path="$key_dir/controller_ed25519"
  pub_path="$key_path.pub"
  mkdir -p "$profile_dir" "$key_dir"
  chmod 700 "$profile_dir" "$key_dir" 2>/dev/null || true
  if [ ! -s "$key_path" ] || [ ! -s "$pub_path" ]; then
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y openssh-client
      fi
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      echo "error: ssh-keygen is required to create controller key" >&2
      exit 1
    fi
    ssh-keygen -t ed25519 -N "" -f "$key_path" -C "vpn-unified-manager-controller" >/dev/null
  fi
  chmod 600 "$key_path" 2>/dev/null || true
  chmod 644 "$pub_path" 2>/dev/null || true
  BOOTSTRAP_CONTROLLER_KEY_PATH="$key_path"
  BOOTSTRAP_CONTROLLER_PUB="$(cat "$pub_path" 2>/dev/null || true)"
  if [ -z "$BOOTSTRAP_CONTROLLER_PUB" ]; then
    echo "error: failed to read generated controller public key" >&2
    exit 1
  fi
}

write_profiles() {
  profile_dir="/etc/vpn-unified-manager"
  bootstrap_json="$profile_dir/bootstrap.json"
  vpn_profile_json="$profile_dir/vpn-profile.json"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir"
  BOOTSTRAP_USER="$BOOTSTRAP_NEW_USER" \
  BOOTSTRAP_SSH_PORT="$BOOTSTRAP_SSH_PORT" \
  BOOTSTRAP_SSH_KEY="$BOOTSTRAP_SSH_KEY" \
  BOOTSTRAP_CONTROLLER_PUB="$BOOTSTRAP_CONTROLLER_PUB" \
  BOOTSTRAP_TELEGRAM_TOKEN="$BOOTSTRAP_TELEGRAM_TOKEN" \
  BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID="$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" \
  BOOTSTRAP_JSON_PATH="$bootstrap_json" \
  VPN_PROFILE_JSON_PATH="$vpn_profile_json" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

bootstrap_path = Path(os.environ["BOOTSTRAP_JSON_PATH"])
vpn_profile_path = Path(os.environ["VPN_PROFILE_JSON_PATH"])
main_key = os.environ["BOOTSTRAP_SSH_KEY"].strip()
controller_key = os.environ.get("BOOTSTRAP_CONTROLLER_PUB", "").strip()
all_keys = [key for key in [main_key, controller_key] if key]
seen: set[str] = set()
unique_keys: list[str] = []
for key in all_keys:
    if key in seen:
        continue
    seen.add(key)
    unique_keys.append(key)

bootstrap_data = {
    "version": 1,
    "new_user": os.environ["BOOTSTRAP_USER"],
    "ssh_port": os.environ["BOOTSTRAP_SSH_PORT"],
    "ssh_public_key": main_key,
    "controller_ssh_public_key": controller_key,
    "ssh_public_keys": unique_keys,
    "telegram_token": os.environ["BOOTSTRAP_TELEGRAM_TOKEN"],
    "telegram_allowed_user_id": os.environ["BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID"],
    "disable_root_login": True,
    "disable_password_auth": True,
}

vpn_profile_data = {
    "version": 1,
    "default_protocol": "",
    "active_protocols": [],
    "server_updates": {},
}

bootstrap_path.write_text(json.dumps(bootstrap_data, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
vpn_profile_path.write_text(json.dumps(vpn_profile_data, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
os.chmod(bootstrap_path, 0o600)
os.chmod(vpn_profile_path, 0o600)
PY
}

restart_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl stop sshd.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl disable sshd.socket 2>/dev/null || true
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    return
  fi
  service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
}

configure_ssh() {
  mkdir -p /etc/ssh/sshd_config.d
  dropin="/etc/ssh/sshd_config.d/00-setup-server.conf"
  cat > "$dropin" <<EOF
Port $BOOTSTRAP_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
  chmod 644 "$dropin"

  sshd_conf="/etc/ssh/sshd_config"
  if [ -f "$sshd_conf" ]; then
    cp "$sshd_conf" "${sshd_conf}.bak"
    sed -i "s/^#*Port .*/Port $BOOTSTRAP_SSH_PORT/" "$sshd_conf" || true
    sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$sshd_conf" || true
    sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" "$sshd_conf" || true
    sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" "$sshd_conf" || true
  fi
}

bootstrap_setup() {
  printf "=== New server setup ===\n\n"

  printf "New username: "
  IFS= read -r raw_user
  BOOTSTRAP_NEW_USER="$(trim_ws "$raw_user")"
  if [ -z "$BOOTSTRAP_NEW_USER" ]; then
    echo "Username cannot be empty." >&2
    exit 1
  fi
  case "$BOOTSTRAP_NEW_USER" in
    [A-Za-z0-9]*)
      ;;
    *)
      echo "Invalid username: first symbol must be a letter or digit." >&2
      exit 1
      ;;
  esac
  case "$BOOTSTRAP_NEW_USER" in
    *[!A-Za-z0-9_-]*)
      echo "Invalid username: use only letters, digits, underscore and hyphen." >&2
      exit 1
      ;;
  esac

  printf "New SSH port (1024-65535, e.g. 2222): "
  IFS= read -r raw_port
  BOOTSTRAP_SSH_PORT="$(trim_ws "$raw_port")"
  case "$BOOTSTRAP_SSH_PORT" in
    ''|*[!0-9]*)
      echo "Specify a valid numeric SSH port." >&2
      exit 1
      ;;
  esac
  if [ "$BOOTSTRAP_SSH_PORT" -lt 1024 ] || [ "$BOOTSTRAP_SSH_PORT" -gt 65535 ]; then
    echo "Specify a valid port (1024-65535)." >&2
    exit 1
  fi

  ensure_controller_ssh_key
  printf "Public SSH key for new user (Enter to use controller key):\n"
  IFS= read -r raw_key
  BOOTSTRAP_SSH_KEY="$(trim_ws "$raw_key")"
  if [ -z "$BOOTSTRAP_SSH_KEY" ]; then
    BOOTSTRAP_SSH_KEY="$BOOTSTRAP_CONTROLLER_PUB"
  fi
  if [ -z "$BOOTSTRAP_SSH_KEY" ]; then
    echo "SSH key not provided and controller key is empty." >&2
    exit 1
  fi

  printf "Telegram bot token (optional, Enter to skip): "
  IFS= read -r raw_token
  BOOTSTRAP_TELEGRAM_TOKEN="$(trim_ws "$raw_token")"

  printf "Approved Telegram user ID (optional, Enter to skip): "
  IFS= read -r raw_tg_uid
  BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID="$(trim_ws "$raw_tg_uid")"
  case "$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" in
    ''|*[!0-9]*)
      if [ -n "$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" ]; then
        echo "Telegram user ID must contain only digits." >&2
        exit 1
      fi
      ;;
  esac

  printf "\nWill perform:\n"
  printf "  - Create user: %s\n" "$BOOTSTRAP_NEW_USER"
  printf "  - SSH port: %s\n" "$BOOTSTRAP_SSH_PORT"
  printf "  - Controller SSH key: %s\n" "$BOOTSTRAP_CONTROLLER_KEY_PATH"
  printf "  - Disable root login and password authentication\n"
  if [ -n "$BOOTSTRAP_TELEGRAM_TOKEN" ] && [ -n "$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" ]; then
    printf "  - Configure and auto-start Telegram bot after deploy\n"
  else
    printf "  - Telegram bot setup skipped (can configure later)\n"
  fi
  printf "  - Save profiles to /etc/vpn-unified-manager/\n\n"
  printf "Continue? (yes/no): "
  IFS= read -r confirm
  confirm="$(trim_ws "$confirm")"
  if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi

  echo "[0/5] Updating apt (if available)..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
  fi

  echo "[1/5] Creating user $BOOTSTRAP_NEW_USER..."
  if id "$BOOTSTRAP_NEW_USER" >/dev/null 2>&1; then
    echo "User already exists: $BOOTSTRAP_NEW_USER"
  else
    useradd -m -s /bin/bash "$BOOTSTRAP_NEW_USER"
  fi

  echo "[2/5] Setting sudo privileges..."
  if command -v usermod >/dev/null 2>&1 && getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$BOOTSTRAP_NEW_USER" || true
  fi
  if [ -d /etc/sudoers.d ]; then
    echo "$BOOTSTRAP_NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$BOOTSTRAP_NEW_USER"
    chmod 440 "/etc/sudoers.d/$BOOTSTRAP_NEW_USER"
  fi

  echo "[3/5] Setting up authorized_keys..."
  user_home="$(getent passwd "$BOOTSTRAP_NEW_USER" | cut -d: -f6)"
  if [ -z "$user_home" ]; then
    user_home="/home/$BOOTSTRAP_NEW_USER"
  fi
  mkdir -p "$user_home/.ssh"
  auth_keys="$user_home/.ssh/authorized_keys"
  touch "$auth_keys"
  if ! grep -Fqx "$BOOTSTRAP_SSH_KEY" "$auth_keys"; then
    printf '%s\n' "$BOOTSTRAP_SSH_KEY" >> "$auth_keys"
  fi
  chown -R "$BOOTSTRAP_NEW_USER:$BOOTSTRAP_NEW_USER" "$user_home/.ssh"
  chmod 700 "$user_home/.ssh"
  chmod 600 "$auth_keys"

  echo "[4/5] Configuring SSH..."
  configure_ssh

  echo "[5/5] Restarting sshd..."
  restart_ssh

  ensure_python3
  write_profiles
  echo "Saved profiles: /etc/vpn-unified-manager/bootstrap.json, /etc/vpn-unified-manager/vpn-profile.json"
}

maybe_bootstrap_handoff() {
  if [ "$BOOTSTRAP_HANDOFF" = "1" ]; then
    return 0
  fi
  if ! is_root; then
    return 0
  fi
  if [ "$BOOTSTRAP_MODE" = "off" ]; then
    return 0
  fi
  if [ "$BOOTSTRAP_MODE" = "auto" ] && [ -n "${SUDO_USER:-}" ]; then
    return 0
  fi
  if [ "$GLOBAL" -eq 1 ]; then
    echo "error: --global is not supported in bootstrap handoff mode." >&2
    echo "Run bundle again with --global after deploy if needed." >&2
    exit 1
  fi

  bootstrap_setup

  if [ -z "$TARGET" ]; then
    TARGET="/home/$BOOTSTRAP_NEW_USER/vpn-unified-manager"
  fi
  case "$TARGET" in
    /*) : ;;
    *) TARGET="/home/$BOOTSTRAP_NEW_USER/$TARGET" ;;
  esac

  script_path="$0"
  case "$script_path" in
    /*) : ;;
    *) script_path="$(pwd)/$script_path" ;;
  esac
  handoff_script="/tmp/vpn-unified-manager-bundle-handoff.sh"
  handoff_bootstrap_json="/tmp/vpn-unified-manager-bootstrap.json"
  cp "$script_path" "$handoff_script"
  chmod 755 "$handoff_script"
  BOOTSTRAP_HANDOFF_JSON="$handoff_bootstrap_json" \
  BOOTSTRAP_TELEGRAM_TOKEN="$BOOTSTRAP_TELEGRAM_TOKEN" \
  BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID="$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["BOOTSTRAP_HANDOFF_JSON"])
data = {
    "telegram_token": os.environ["BOOTSTRAP_TELEGRAM_TOKEN"],
    "telegram_allowed_user_id": os.environ["BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID"],
}
path.write_text(json.dumps(data, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
  chown "$BOOTSTRAP_NEW_USER:$BOOTSTRAP_NEW_USER" "$handoff_bootstrap_json"
  chmod 600 "$handoff_bootstrap_json"

  echo "Switching to user $BOOTSTRAP_NEW_USER to deploy bundle..."
  exec su - "$BOOTSTRAP_NEW_USER" -c "BOOTSTRAP_HANDOFF=1 sh \"$handoff_script\" --dir \"$TARGET\" --no-bootstrap"
}

maybe_bootstrap_handoff

if [ -z "$TARGET" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    _uh="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    if [ -n "$_uh" ]; then
      TARGET="$_uh/vpn-unified-manager"
    else
      TARGET="${HOME:-/root}/vpn-unified-manager"
    fi
  else
    TARGET="${HOME:-/root}/vpn-unified-manager"
  fi
fi

ensure_python3

mkdir -p "$TARGET/vpn_protocols"

maybe_configure_telegram_bot() {
  if [ "$BOOTSTRAP_HANDOFF" != "1" ]; then
    return 0
  fi
  handoff_bootstrap_json="/tmp/vpn-unified-manager-bootstrap.json"
  if [ ! -f "$handoff_bootstrap_json" ]; then
    return 0
  fi
  TARGET="$TARGET" BOOTSTRAP_HANDOFF_JSON="$handoff_bootstrap_json" python3 - <<'PY'
import json
import os
from pathlib import Path

handoff_json = Path(os.environ["BOOTSTRAP_HANDOFF_JSON"])
try:
    data = json.loads(handoff_json.read_text(encoding="utf-8") or "{}")
except Exception:
    data = {}

token = str(data.get("telegram_token") or "").strip()
allowed_user_id = str(data.get("telegram_allowed_user_id") or "").strip()
if not token or not allowed_user_id:
    raise SystemExit(0)
PY

  sudo TARGET="$TARGET" BOOTSTRAP_HANDOFF_JSON="$handoff_bootstrap_json" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

target = Path(os.environ["TARGET"])
handoff_json = Path(os.environ["BOOTSTRAP_HANDOFF_JSON"])
try:
    data = json.loads(handoff_json.read_text(encoding="utf-8") or "{}")
except Exception:
    data = {}

token = str(data.get("telegram_token") or "").strip()
allowed_user_id = str(data.get("telegram_allowed_user_id") or "").strip()
if not token or not allowed_user_id:
    raise SystemExit(0)

sys.path.insert(0, str(target))
from vpn_manager import _telegram_start_background
from vpn_protocols.telegram_bot import TelegramBotManager

bot = TelegramBotManager(repo_root=target)
bot.configure(token, None, allowed_user_id)
ok, err = _telegram_start_background(target, bot)
if not ok and err != "Bot is already running.":
    raise SystemExit(err or "Failed to start Telegram bot")
print("Telegram bot configured and started.")
PY
  rm -f "$handoff_bootstrap_json" 2>/dev/null || true
}

cat > "$TARGET/vpn_manager.py" <<'__VPN_MGR_277f6af191d71464d73df5823128d1fcb0425f140b362788__'
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
__VPN_MGR_277f6af191d71464d73df5823128d1fcb0425f140b362788__
cat > "$TARGET/vpn_protocols/__init__.py" <<'__VPN_MGR_6ce1de3011d5ac4754ba9508e936110e2c2562428bee209a__'
# Protocol implementations for unified VPN manager.
__VPN_MGR_6ce1de3011d5ac4754ba9508e936110e2c2562428bee209a__
cat > "$TARGET/vpn_protocols/amneziawg.py" <<'__VPN_MGR_7c44a0f70f8644f8f3b1ff948e60d15e5d5e890c0248ed68__'
from __future__ import annotations

import random
import re
import textwrap
from pathlib import Path

from .shared import read_text, replace_or_append_line, run, write_text


class AmneziaWGManager:
    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.conf_dir = Path("/etc/amnezia/amneziawg")
        self.server_conf = self.conf_dir / "awg0.conf"
        self.clients_dir = self.conf_dir / "clients"
        self.keys_dir = self.conf_dir / "keys"
        self.interface = "awg0"
        self.subnet_prefix = "10.9.1"
        self.vpn_subnet = "10.9.1.0/24"
        self.vpn_server_ip = "10.9.1.1"

    def _sync_network_from_server_conf(self) -> None:
        conf = read_text(self.server_conf)
        if not conf:
            return
        match = re.search(r"^Address\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)\.1/24$", conf, flags=re.MULTILINE)
        if not match:
            return
        prefix = match.group(1)
        self.subnet_prefix = prefix
        self.vpn_subnet = f"{prefix}.0/24"
        self.vpn_server_ip = f"{prefix}.1"

    def _route_has_subnet(self, prefix: str) -> bool:
        routes = run("ip -4 route show", check=False)
        target = f"{prefix}.0/24"
        for line in routes.splitlines():
            line = line.strip()
            if line.startswith(target + " ") or f" {target} " in line:
                return True
        return False

    def _pick_install_subnet(self) -> None:
        candidates = ["10.9.1"] + [f"10.{n}.1" for n in range(10, 31)]
        for prefix in candidates:
            if not self._route_has_subnet(prefix):
                self.subnet_prefix = prefix
                self.vpn_subnet = f"{prefix}.0/24"
                self.vpn_server_ip = f"{prefix}.1"
                return
        raise RuntimeError("Cannot find free /24 subnet for AmneziaWG.")

    def _service_restart(self) -> None:
        run(f"awg-quick down {self.interface} 2>/dev/null || true", check=False)
        run(f"awg-quick up {self.interface}", check=False)

    def _server_params(self) -> dict[str, str]:
        conf = read_text(self.server_conf)
        if not conf:
            raise RuntimeError(f"Server config not found: {self.server_conf}")
        params: dict[str, str] = {}
        for line in conf.splitlines():
            match = re.match(r"^(\w+)\s*=\s*(.+)$", line.strip())
            if match:
                params[match.group(1)] = match.group(2).strip()
        required = ["ListenPort", "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4"]
        for key in required:
            if key not in params:
                raise RuntimeError(f"Missing '{key}' in {self.server_conf}")
        return params

    def _server_public_key(self) -> str:
        priv = read_text(self.keys_dir / "server_privatekey").strip()
        if not priv:
            raise RuntimeError("Missing server private key.")
        return run(f"echo '{priv}' | awg pubkey")

    def _cps_lines(self) -> str:
        i1 = read_text(self.conf_dir / "cps_i1.txt").strip()
        if not i1:
            return ""
        return textwrap.dedent(
            f"""\
            I1 = <b 0x{i1}>
            I2 = .
            I3 = .
            I4 = .
            I5 = .
            """
        ).strip()

    def _server_ip(self) -> str:
        ip = run(
            "ip -4 addr show $(ip -o route get 1 | grep -oP 'dev \\K\\S+') 2>/dev/null | "
            "grep -oP '(?<=inet )[\\d.]+' | head -1",
            check=False,
        )
        if not ip:
            ip = run("hostname -I | awk '{print $1}'", check=False)
        if not ip:
            raise RuntimeError("Cannot detect server IP.")
        return ip

    def _peer_blocks(self) -> list[dict[str, str]]:
        self._sync_network_from_server_conf()
        conf = read_text(self.server_conf)
        peers: list[dict[str, str]] = []
        if not conf:
            return peers
        lines = conf.splitlines()
        i = 0
        while i < len(lines):
            if lines[i].strip() != "[Peer]":
                i += 1
                continue
            name = ""
            if i > 0:
                prev = lines[i - 1].strip()
                m_name = re.match(r"^#\s*client:\s*(.+)$", prev)
                if m_name:
                    name = m_name.group(1).strip()
            peer: dict[str, str] = {"_name": name}
            j = i + 1
            while j < len(lines):
                current = lines[j].strip()
                if current == "[Peer]" or current.startswith("# client:"):
                    break
                m_line = re.match(r"^(\w+)\s*=\s*(.+)$", lines[j].strip())
                if m_line:
                    peer[m_line.group(1)] = m_line.group(2).strip()
                j += 1
            if peer.get("PublicKey"):
                peers.append(peer)
            i = j
        return peers

    def _next_free_ip(self) -> str:
        used = {1}
        for peer in self._peer_blocks():
            allowed = peer.get("AllowedIPs", "")
            m = re.match(rf"^{re.escape(self.subnet_prefix)}\.(\d+)/32$", allowed)
            if m:
                used.add(int(m.group(1)))
        for last_octet in range(2, 255):
            if last_octet not in used:
                return f"{self.subnet_prefix}.{last_octet}"
        raise RuntimeError(f"No free client IP in {self.vpn_subnet}")

    def _client_file(self, name: str) -> Path:
        return self.clients_dir / f"awg0-client-{name}.conf"

    def _client_pubkey(self, client_name: str) -> str:
        conf = read_text(self._client_file(client_name))
        m_priv = re.search(r"^PrivateKey\s*=\s*(\S+)$", conf, flags=re.MULTILINE)
        if not m_priv:
            raise RuntimeError(f"PrivateKey not found in client config: {client_name}")
        return run(f"echo '{m_priv.group(1)}' | awg pubkey")

    def _peer_public_key_by_name(self, name: str) -> str | None:
        for peer in self._peer_blocks():
            if peer.get("_name") == name and peer.get("PublicKey"):
                return peer["PublicKey"]
        return None

    def _main_interface(self) -> str:
        iface = run(
            "ip -o route get 1 2>/dev/null | grep -oP 'dev \\K\\S+' || "
            "ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1",
            check=False,
        )
        if not iface:
            raise RuntimeError("Could not detect main network interface.")
        return iface

    def _server_public_ip(self, interface: str) -> str:
        ip = run(
            f"ip -4 addr show dev '{interface}' 2>/dev/null | grep -oP '(?<=inet )[\\d.]+' | head -1",
            check=False,
        )
        if not ip:
            ip = run("ip -o route get 1 2>/dev/null | grep -oP 'src \\K\\S+'", check=False)
        if not ip:
            ip = run("hostname -I | awk '{print $1}'", check=False)
        if not ip:
            raise RuntimeError("Could not detect server IP.")
        return ip

    def _ssh_port(self) -> int:
        port = run(
            "grep -E '^Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1",
            check=False,
        )
        if not port or not port.isdigit():
            return 22
        return int(port)

    def _port_in_use(self, port: int) -> bool:
        udp_busy = run(f"ss -ulnp 2>/dev/null | grep -q ':{port} ' && echo yes || echo no", check=False)
        if udp_busy == "yes":
            return True
        tcp_busy = run(f"ss -tlnp 2>/dev/null | grep -q ':{port} ' && echo yes || echo no", check=False)
        return tcp_busy == "yes"

    def _random_listen_port(self, exclude: int) -> int:
        for _ in range(20):
            candidate = random.randint(10000, 65535)
            if candidate == exclude:
                continue
            if not self._port_in_use(candidate):
                return candidate
        raise RuntimeError("Could not find a free port for VPN.")

    def _release_apt_lock(self) -> None:
        run(
            "for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do "
            "  [ -e \"$lock\" ] || continue; "
            "  pids=$(lsof -t \"$lock\" 2>/dev/null || true); "
            "  if [ -n \"$pids\" ]; then kill $pids 2>/dev/null || true; sleep 2; fi; "
            "done",
            check=False,
        )
        run("pids=$(pgrep -x apt-get 2>/dev/null || true); [ -n \"$pids\" ] && kill $pids 2>/dev/null || true", check=False)
        run("dpkg --configure -a 2>/dev/null || true", check=False)

    def _apt_candidate_amneziawg(self) -> str:
        return run(
            "apt-cache policy amneziawg 2>/dev/null | awk '/Candidate:/ {print $2; exit}'",
            check=False,
        )

    def _ubuntu_codename(self) -> str:
        codename = run(
            ". /etc/os-release 2>/dev/null; "
            "printf '%s' \"${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}\"",
            check=False,
        )
        return codename.strip()

    def _cleanup_amnezia_ppa_sources(self) -> None:
        source_dir = Path("/etc/apt/sources.list.d")
        if not source_dir.exists():
            return
        for path in source_dir.glob("amnezia-ubuntu-ppa-*"):
            if path.suffix in {".sources", ".list"}:
                path.unlink(missing_ok=True)

    def _ensure_amnezia_ppa_source(self, codename: str) -> None:
        if not codename:
            return
        source_file = Path(f"/etc/apt/sources.list.d/amnezia-ubuntu-ppa-{codename}.list")
        source_content = (
            "deb [trusted=yes] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/ "
            f"{codename} main\n"
        )
        write_text(source_file, source_content, mode=0o644)

    def _ensure_installed(self) -> None:
        if run("command -v awg >/dev/null 2>&1 && echo yes || echo no", check=False) == "yes":
            return
        if run("command -v apt-get >/dev/null 2>&1 && echo yes || echo no", check=False) != "yes":
            raise RuntimeError("AmneziaWG auto-install currently supports apt-based systems only.")
        self._release_apt_lock()
        codename = self._ubuntu_codename()
        if codename:
            self._cleanup_amnezia_ppa_sources()
            self._ensure_amnezia_ppa_source(codename)
        run(
            "DEBIAN_FRONTEND=noninteractive "
            "apt-get -o DPkg::Lock::Timeout=120 -o Acquire::ForceIPv4=true "
            "-o APT::Update::Post-Invoke-Success::= update"
        )
        run(
            "DEBIAN_FRONTEND=noninteractive "
            "apt-get -o DPkg::Lock::Timeout=120 install -y software-properties-common linux-headers-$(uname -r)",
            check=False,
        )
        candidate = self._apt_candidate_amneziawg()
        if not candidate or candidate == "(none)":
            # Avoid nested apt update from add-apt-repository and hard-stop if it stalls.
            run("timeout 45s add-apt-repository -n -y ppa:amnezia/ppa", check=False)
            if codename:
                self._cleanup_amnezia_ppa_sources()
                self._ensure_amnezia_ppa_source(codename)
        # Disable post-invoke hooks to avoid apt-check/update-motd stuck processes.
        run(
            "DEBIAN_FRONTEND=noninteractive "
            "apt-get -o DPkg::Lock::Timeout=120 -o Acquire::ForceIPv4=true "
            "-o APT::Update::Post-Invoke-Success::= update -qq"
        )
        candidate = self._apt_candidate_amneziawg()
        if not candidate or candidate == "(none)":
            codename = self._ubuntu_codename() or "unknown"
            raise RuntimeError(f"AmneziaWG package candidate not found for distro codename '{codename}'.")
        run(
            "DEBIAN_FRONTEND=noninteractive "
            "apt-get -o DPkg::Lock::Timeout=120 install -y amneziawg amneziawg-tools qrencode"
        )
        run("apt-get install -y amneziawg-dkms 2>/dev/null || true", check=False)

    def _generate_keys_if_needed(self) -> None:
        self.keys_dir.mkdir(parents=True, exist_ok=True)
        run(f"chmod 700 '{self.keys_dir}'", check=False)
        if (self.keys_dir / "server_privatekey").exists():
            return
        run(f"awg genkey | tee '{self.keys_dir / 'server_privatekey'}' | awg pubkey > '{self.keys_dir / 'server_publickey'}'")
        run(f"awg genkey | tee '{self.keys_dir / 'client_privatekey'}' | awg pubkey > '{self.keys_dir / 'client_publickey'}'")
        run(f"awg genpsk > '{self.keys_dir / 'presharedkey'}'")
        run(f"chmod 600 '{self.keys_dir}'/*", check=False)

    def _ensure_cps_i1(self) -> str:
        cps_i1_file = self.conf_dir / "cps_i1.txt"
        if not cps_i1_file.exists():
            i1_hex = run("openssl rand -hex 48 2>/dev/null", check=False)
            if not i1_hex:
                i1_hex = run("od -v -An -tx1 -N48 /dev/urandom 2>/dev/null | tr -d ' \\n'", check=False)
            if i1_hex:
                write_text(cps_i1_file, f"{i1_hex}\n", mode=0o600)
        return read_text(cps_i1_file).strip()

    def install(self):
        self._pick_install_subnet()
        main_interface = self._main_interface()
        server_ip = self._server_public_ip(main_interface)
        ssh_port = self._ssh_port()
        listen_port = self._random_listen_port(ssh_port)

        self._ensure_installed()
        run("modprobe amneziawg 2>/dev/null || true", check=False)

        write_text(
            Path("/etc/sysctl.d/00-amnezia.conf"),
            "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n",
            mode=0o644,
        )
        run("sysctl -p /etc/sysctl.d/00-amnezia.conf", check=False)

        self._generate_keys_if_needed()

        jc = random.randint(4, 12)
        jmin = 8
        jmax = jmin + 50 + random.randint(0, 199)
        s1 = random.randint(10, 109)
        s2 = random.randint(10, 109)
        s3 = random.randint(10, 109)
        s4 = random.randint(10, 109)
        h1 = random.randint(0, 2**31 - 1)
        h2 = random.randint(0, 2**31 - 1)
        h3 = random.randint(0, 2**31 - 1)
        h4 = random.randint(0, 2**31 - 1)

        i1_hex = self._ensure_cps_i1()

        server_priv = read_text(self.keys_dir / "server_privatekey").strip()
        server_pub = read_text(self.keys_dir / "server_publickey").strip()
        client_priv = read_text(self.keys_dir / "client_privatekey").strip()
        client_pub = read_text(self.keys_dir / "client_publickey").strip()
        preshared = read_text(self.keys_dir / "presharedkey").strip()
        self.clients_dir.mkdir(parents=True, exist_ok=True)

        server_conf_content = textwrap.dedent(
            f"""\
            [Interface]
            PrivateKey = {server_priv}
            Address = {self.vpn_server_ip}/24
            ListenPort = {listen_port}
            Jc = {jc}
            Jmin = {jmin}
            Jmax = {jmax}
            S1 = {s1}
            S2 = {s2}
            S3 = {s3}
            S4 = {s4}
            H1 = {h1}
            H2 = {h2}
            H3 = {h3}
            H4 = {h4}
            PostUp = iptables -A INPUT -i {main_interface} -p udp --dport {listen_port} -j ACCEPT; iptables -A FORWARD -i awg0 -o {main_interface} -j ACCEPT; iptables -A FORWARD -i {main_interface} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s {self.vpn_subnet} -o {main_interface} -j MASQUERADE
            PostDown = iptables -D INPUT -i {main_interface} -p udp --dport {listen_port} -j ACCEPT; iptables -D FORWARD -i awg0 -o {main_interface} -j ACCEPT; iptables -D FORWARD -i {main_interface} -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s {self.vpn_subnet} -o {main_interface} -j MASQUERADE

            [Peer]
            PresharedKey = {preshared}
            PublicKey = {client_pub}
            AllowedIPs = {self.subnet_prefix}.2/32
            """
        )
        write_text(self.server_conf, server_conf_content, mode=0o600)

        cps_block = ""
        if i1_hex:
            cps_block = textwrap.dedent(
                f"""\
                I1 = <b 0x{i1_hex}>
                I2 = .
                I3 = .
                I4 = .
                I5 = .
                """
            )

        initial_client_conf = textwrap.dedent(
            f"""\
            [Interface]
            PrivateKey = {client_priv}
            Address = {self.subnet_prefix}.2/24
            DNS = 8.8.8.8, 8.8.4.4
            Jc = {jc}
            Jmin = {jmin}
            Jmax = {jmax}
            S1 = {s1}
            S2 = {s2}
            S3 = {s3}
            S4 = {s4}
            H1 = {h1}
            H2 = {h2}
            H3 = {h3}
            H4 = {h4}
            {cps_block}[Peer]
            PresharedKey = {preshared}
            PublicKey = {server_pub}
            Endpoint = {server_ip}:{listen_port}
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25
            """
        )
        write_text(self.clients_dir / "awg0-client-initial.conf", initial_client_conf, mode=0o600)

        ufw_active = run("command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active' && echo yes || echo no", check=False)
        if ufw_active == "yes":
            run("ufw disable 2>/dev/null || true", check=False)

        run("awg-quick down awg0 2>/dev/null || true", check=False)
        run("awg-quick up awg0")
        run("systemctl enable awg-quick@awg0", check=False)
        run("command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null || true", check=False)

        return {
            "status": "installed",
            "protocol": "amneziawg",
            "server_ip": server_ip,
        }

    def uninstall(self):
        run("systemctl disable --now awg-quick@awg0 2>/dev/null || true", check=False)
        run("awg-quick down awg0 2>/dev/null || true", check=False)
        run("rm -rf /etc/amnezia/amneziawg", check=False)
        run("rm -f /etc/sysctl.d/00-amnezia.conf", check=False)
        run("sysctl -p /etc/sysctl.d/00-amnezia.conf 2>/dev/null || true", check=False)
        run(
            "apt-get remove -y amneziawg amneziawg-tools amneziawg-dkms 2>/dev/null || true",
            check=False,
        )
        leftovers = [p for p in [self.conf_dir, Path("/etc/sysctl.d/00-amnezia.conf")] if p.exists()]
        if leftovers:
            raise RuntimeError("Uninstall incomplete: " + ", ".join(str(p) for p in leftovers))
        return {"status": "uninstalled", "protocol": "amneziawg"}

    def list_clients(self):
        peers = self._peer_blocks()
        out: list[str] = []
        for idx, peer in enumerate(peers, start=1):
            name = peer.get("_name") or f"peer-{idx}"
            allowed = peer.get("AllowedIPs", "?").replace("/32", "")
            # Skip the initial client created during install (.2 address).
            if allowed == f"{self.subnet_prefix}.2":
                continue
            out.append(f"{name}\t{allowed}")
        return out

    def create_client(self, name: str):
        path = self._client_file(name)
        if path.exists():
            raise RuntimeError(f"Client '{name}' already exists.")

        params = self._server_params()
        client_ip = self._next_free_ip()
        server_public_key = self._server_public_key()
        server_ip = self._server_ip()
        client_priv = run("awg genkey")
        client_pub = run(f"echo '{client_priv}' | awg pubkey")
        psk = run("awg genpsk")
        cps = self._cps_lines()
        cps_block = f"{cps}\n" if cps else ""

        conf = textwrap.dedent(
            f"""\
            [Interface]
            PrivateKey = {client_priv}
            Address = {client_ip}/24
            DNS = 8.8.8.8, 8.8.4.4
            Jc = {params['Jc']}
            Jmin = {params['Jmin']}
            Jmax = {params['Jmax']}
            S1 = {params['S1']}
            S2 = {params['S2']}
            S3 = {params['S3']}
            S4 = {params['S4']}
            H1 = {params['H1']}
            H2 = {params['H2']}
            H3 = {params['H3']}
            H4 = {params['H4']}
            {cps_block}[Peer]
            PresharedKey = {psk}
            PublicKey = {server_public_key}
            Endpoint = {server_ip}:{params['ListenPort']}
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25
            """
        )
        write_text(path, conf, mode=0o600)

        peer_block = textwrap.dedent(
            f"""\

            # client: {name}
            [Peer]
            PresharedKey = {psk}
            PublicKey = {client_pub}
            AllowedIPs = {client_ip}/32
            """
        )
        current_server = read_text(self.server_conf)
        write_text(self.server_conf, current_server.rstrip() + "\n" + peer_block, mode=0o600)
        self._service_restart()

        return {"client": name, "ip": client_ip, "config": str(path)}

    def delete_client(self, name: str):
        conf_path = self._client_file(name)
        pubkey: str | None = None
        if conf_path.exists():
            try:
                pubkey = self._client_pubkey(name)
            except Exception:
                pubkey = None
        if not pubkey:
            pubkey = self._peer_public_key_by_name(name)
        if not pubkey:
            raise RuntimeError(f"PublicKey not found for client '{name}'.")

        server_text = read_text(self.server_conf)
        lines = server_text.splitlines()
        new_lines: list[str] = []
        i = 0
        removed = False
        while i < len(lines):
            if lines[i].strip() == "[Peer]":
                start = i
                if start > 0 and lines[start - 1].strip().startswith("# client:"):
                    start -= 1
                j = i
                block_lines: list[str] = []
                while j < len(lines):
                    block_lines.append(lines[j])
                    j += 1
                    if j < len(lines) and (
                        lines[j].strip().startswith("[") or lines[j].strip().startswith("# client:")
                    ):
                        break
                block_text = "\n".join(block_lines)
                if pubkey in block_text:
                    removed = True
                    i = j
                    continue
            new_lines.append(lines[i])
            i += 1
        if not removed:
            raise RuntimeError(f"Peer block not found for client '{name}'.")

        write_text(self.server_conf, "\n".join(new_lines).rstrip() + "\n", mode=0o600)
        conf_path.unlink(missing_ok=True)
        self._service_restart()
        return {"deleted": name}

    def rename_client(self, name: str, new_name: str):
        old_path = self._client_file(name)
        new_path = self._client_file(new_name)
        if not old_path.exists():
            raise RuntimeError(f"Client '{name}' not found.")
        if new_path.exists():
            raise RuntimeError(f"Client '{new_name}' already exists.")

        old_path.rename(new_path)
        server_text = read_text(self.server_conf)
        server_text = re.sub(
            rf"^#\s*client:\s*{re.escape(name)}$",
            f"# client: {new_name}",
            server_text,
            flags=re.MULTILINE,
        )
        write_text(self.server_conf, server_text, mode=0o600)
        return {"renamed": name, "to": new_name, "config": str(new_path)}

    def update_server(self, updates: dict[str, str]):
        allowed_keys = {
            "ListenPort",
            "Jc",
            "Jmin",
            "Jmax",
            "S1",
            "S2",
            "S3",
            "S4",
            "H1",
            "H2",
            "H3",
            "H4",
        }
        unsupported = [k for k in updates if k not in allowed_keys]
        if unsupported:
            raise RuntimeError(f"Unsupported keys for AmneziaWG server update: {', '.join(unsupported)}")

        content = read_text(self.server_conf)
        if not content:
            raise RuntimeError(f"Server config not found: {self.server_conf}")
        for key, value in updates.items():
            content = replace_or_append_line(content, key, value)
        write_text(self.server_conf, content, mode=0o600)
        self._service_restart()
        return {"updated_server_keys": ",".join(sorted(updates.keys()))}

    def update_client(self, name: str, updates: dict[str, str]):
        path = self._client_file(name)
        content = read_text(path)
        if not content:
            raise RuntimeError(f"Client config not found: {path}")
        for key, value in updates.items():
            content = replace_or_append_line(content, key, value)
        write_text(path, content, mode=0o600)
        return {"updated_client": name, "keys": ",".join(sorted(updates.keys()))}

    def show_client_config_path(self, name: str):
        path = self._client_file(name)
        if not path.exists():
            raise RuntimeError(f"Client config not found: {path}")
        return {"client": name, "path": str(path)}
__VPN_MGR_7c44a0f70f8644f8f3b1ff948e60d15e5d5e890c0248ed68__
cat > "$TARGET/vpn_protocols/openvpn.py" <<'__VPN_MGR_d0658e66c06df652231ec7cbb63f97f52ebe2c5c7f4b7da9__'
from __future__ import annotations

import re
from pathlib import Path

from .shared import read_text, run, write_text


class OpenVPNManager:
    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.easyrsa_dir = Path("/etc/openvpn/server/easy-rsa")
        self.server_dir = Path("/etc/openvpn/server")
        self.server_conf = self.server_dir / "server.conf"
        self.server_tcp_conf = self.server_dir / "server-tcp.conf"
        self.clients_dir = Path("/etc/openvpn/clients")
        self.nat_script = Path("/usr/local/sbin/openvpn-nat.sh")
        self.nat_service_file = Path("/etc/systemd/system/openvpn-nat.service")
        self.service = "openvpn-server@server"
        self.tcp_service = "openvpn-server@server-tcp"
        self.instances: dict[str, dict[str, str | Path]] = {
            "udp": {
                "name": "server",
                "conf": self.server_conf,
                "service": self.service,
                "port": "34461",
                "net": "10.8.1.0",
                "mask": "255.255.255.0",
                "dev": "tun0",
            },
            "tcp": {
                "name": "server-tcp",
                "conf": self.server_tcp_conf,
                "service": self.tcp_service,
                "port": "34462",
                "net": "10.8.2.0",
                "mask": "255.255.255.0",
                "dev": "tun1",
            },
        }
        self.primary_proto = "udp"
        self.defaults = {
            "dns1": "1.1.1.1",
            "dns2": "8.8.8.8",
            "cipher": "AES-256-GCM",
            "auth": "SHA512",
            "easyrsa_cn": "OpenVPN-CA",
            "server_cn": "server",
        }

    def _service_restart(self) -> None:
        run("systemctl enable --now openvpn-nat.service", check=False)
        for item in self.instances.values():
            service = str(item["service"])
            run(f"systemctl restart {service}", check=False)

    def _server_ip(self) -> str:
        ip = run("curl -4 -s https://ifconfig.me", check=False)
        if not ip:
            ip = run("hostname -I | awk '{print $1}'", check=False)
        if not ip:
            raise RuntimeError("Cannot detect server IP.")
        return ip

    def _instance(self, proto: str) -> dict[str, str | Path]:
        self._validate_proto(proto)
        return self.instances[proto]

    def _parse_port_proto(self, conf_path: Path) -> tuple[str, str] | None:
        if not conf_path.exists():
            return None
        conf = read_text(conf_path)
        m_port = re.search(r"^port\s+(\d+)$", conf, flags=re.MULTILINE)
        m_proto = re.search(r"^proto\s+(\S+)$", conf, flags=re.MULTILINE)
        if not m_port or not m_proto:
            return None
        return m_port.group(1), m_proto.group(1)

    def _server_port_proto(self, preferred_proto: str | None = None) -> tuple[str, str]:
        if preferred_proto:
            self._validate_proto(preferred_proto)
            preferred_conf = self._instance(preferred_proto)["conf"]  # type: ignore[arg-type]
            parsed_preferred = self._parse_port_proto(preferred_conf)
            if parsed_preferred:
                return parsed_preferred
            raise RuntimeError(
                f"OpenVPN {preferred_proto.upper()} listener is not configured. "
                "Run openvpn install (or reinstall) to create both UDP/TCP listeners."
            )
        order: list[str] = []
        order.append(self.primary_proto)
        for proto in ["udp", "tcp"]:
            if proto not in order:
                order.append(proto)
        for proto in order:
            parsed = self._parse_port_proto(self._instance(proto)["conf"])  # type: ignore[arg-type]
            if parsed:
                return parsed
        raise RuntimeError("Cannot parse port/proto in OpenVPN server configs.")

    def _mask_to_cidr(self, mask: str) -> str:
        if mask == "255.255.255.0":
            return "24"
        if mask == "255.255.0.0":
            return "16"
        if mask == "255.0.0.0":
            return "8"
        raise RuntimeError("Unsupported netmask. Use 255.255.255.0, 255.255.0.0 or 255.0.0.0")

    def _validate_proto(self, proto: str) -> None:
        if proto not in {"udp", "tcp"}:
            raise RuntimeError("proto must be udp or tcp")

    def _set_server_line(self, conf_path: Path, key: str, value: str) -> None:
        conf = read_text(conf_path)
        if not conf:
            raise RuntimeError(f"Server config not found: {conf_path}")
        if re.search(rf"^{re.escape(key)}\s+.+$", conf, flags=re.MULTILINE):
            conf = re.sub(rf"^{re.escape(key)}\s+.+$", f"{key} {value}", conf, flags=re.MULTILINE)
        else:
            conf = conf.rstrip() + f"\n{key} {value}\n"
        write_text(conf_path, conf, mode=0o600)

    def _set_server_network(self, conf_path: Path, subnet: str, mask: str) -> None:
        conf = read_text(conf_path)
        if not conf:
            raise RuntimeError(f"Server config not found: {conf_path}")
        line = f"server {subnet} {mask}"
        if re.search(r"^server\s+\S+\s+\S+$", conf, flags=re.MULTILINE):
            conf = re.sub(r"^server\s+\S+\s+\S+$", line, conf, flags=re.MULTILINE)
        else:
            conf = conf.rstrip() + f"\n{line}\n"
        write_text(conf_path, conf, mode=0o600)

    def _set_dns_push(self, conf_path: Path, dns1: str, dns2: str) -> None:
        conf = read_text(conf_path)
        if not conf:
            raise RuntimeError(f"Server config not found: {conf_path}")
        lines = [line for line in conf.splitlines() if not line.strip().startswith('push "dhcp-option DNS ')]
        lines.append(f'push "dhcp-option DNS {dns1}"')
        lines.append(f'push "dhcp-option DNS {dns2}"')
        write_text(conf_path, "\n".join(lines).rstrip() + "\n", mode=0o600)

    def _write_server_conf(
        self,
        conf_path: Path,
        dev_name: str,
        port: str,
        proto: str,
        net: str,
        mask: str,
        dns1: str,
        dns2: str,
    ) -> None:
        content = (
            f"port {port}\n"
            f"proto {proto}\n"
            f"dev {dev_name}\n"
            f"ca {self.server_dir}/ca.crt\n"
            f"cert {self.server_dir}/{self.defaults['server_cn']}.crt\n"
            f"key {self.server_dir}/{self.defaults['server_cn']}.key\n"
            f"dh {self.server_dir}/dh.pem\n"
            f"server {net} {mask}\n"
            f"ifconfig-pool-persist {self.server_dir}/ipp.txt\n"
            "keepalive 10 120\n"
            f"cipher {self.defaults['cipher']}\n"
            f"data-ciphers {self.defaults['cipher']}\n"
            f"auth {self.defaults['auth']}\n"
            "user nobody\n"
            "group nogroup\n"
            "persist-key\n"
            "persist-tun\n"
            f"crl-verify {self.server_dir}/crl.pem\n"
            f"status {self.server_dir}/openvpn-status.log\n"
            "verb 3\n"
            "tls-server\n"
            "tls-version-min 1.2\n"
            f"tls-auth {self.server_dir}/ta.key 0\n"
            "topology subnet\n"
            'push "redirect-gateway def1 bypass-dhcp"\n'
            f'push "dhcp-option DNS {dns1}"\n'
            f'push "dhcp-option DNS {dns2}"\n'
            "explicit-exit-notify 1\n"
        )
        write_text(conf_path, content, mode=0o600)

    def _configure_nat_service(self, iface: str, listeners: list[tuple[str, str, str]]) -> None:
        apply_lines: list[str] = []
        remove_lines: list[str] = []
        for dev_name, net, mask in listeners:
            cidr = self._mask_to_cidr(mask)
            source = f"{net}/{cidr}"
            apply_lines.extend(
                [
                    f"  iptables -C FORWARD -i {dev_name} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i {dev_name} -j ACCEPT",
                    f"  iptables -C FORWARD -o {dev_name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o {dev_name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
                    f'  iptables -t nat -C POSTROUTING -s "{source}" -o "${{IFACE}}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "{source}" -o "${{IFACE}}" -j MASQUERADE',
                ]
            )
            remove_lines.extend(
                [
                    f"  iptables -D FORWARD -i {dev_name} -j ACCEPT 2>/dev/null || true",
                    f"  iptables -D FORWARD -o {dev_name} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true",
                    f'  iptables -t nat -D POSTROUTING -s "{source}" -o "${{IFACE}}" -j MASQUERADE 2>/dev/null || true',
                ]
            )
        if not apply_lines:
            raise RuntimeError("No OpenVPN listeners configured for NAT.")
        apply_block = "\n".join(apply_lines)
        remove_block = "\n".join(remove_lines)
        nat_script = (
            "#!/bin/sh\n"
            "set -eu\n"
            'ACTION="${1:-apply}"\n'
            f'IFACE="{iface}"\n'
            'if [ "${ACTION}" = "apply" ]; then\n'
            f"{apply_block}\n"
            'elif [ "${ACTION}" = "remove" ]; then\n'
            f"{remove_block}\n"
            "fi\n"
        )
        nat_service = (
            "[Unit]\n"
            "Description=OpenVPN NAT rules\n"
            "After=network-online.target\n"
            "Wants=network-online.target\n"
            "Before=openvpn-server@server.service\n"
            "Before=openvpn-server@server-tcp.service\n"
            "\n"
            "[Service]\n"
            "Type=oneshot\n"
            "RemainAfterExit=yes\n"
            "ExecStart=/usr/local/sbin/openvpn-nat.sh apply\n"
            "ExecStop=/usr/local/sbin/openvpn-nat.sh remove\n"
            "\n"
            "[Install]\n"
            "WantedBy=multi-user.target\n"
        )
        write_text(self.nat_script, nat_script, mode=0o755)
        write_text(self.nat_service_file, nat_service, mode=0o644)
        run("systemctl daemon-reload", check=False)
        run("systemctl enable --now openvpn-nat.service", check=False)

    def _build_ovpn(
        self,
        name: str,
        remote_host: str | None = None,
        remote_port: str | None = None,
        proto: str | None = None,
    ) -> Path:
        issued = self.easyrsa_dir / "pki" / "issued" / f"{name}.crt"
        key = self.easyrsa_dir / "pki" / "private" / f"{name}.key"
        if not issued.exists() or not key.exists():
            run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa build-client-full '{name}' nopass")
            run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa gen-crl", check=False)
            crl = self.easyrsa_dir / "pki" / "crl.pem"
            if crl.exists():
                run(f"cp '{crl}' '{self.server_dir / 'crl.pem'}'", check=False)

        if proto:
            self._validate_proto(proto)
            final_proto = proto
            server_port, _ = self._server_port_proto(preferred_proto=final_proto)
        else:
            server_port, server_proto = self._server_port_proto()
            final_proto = server_proto
        final_port = remote_port or server_port
        host = remote_host or self._server_ip()
        ca = read_text(self.server_dir / "ca.crt")
        ta = read_text(self.server_dir / "ta.key")
        crt = run(f"openssl x509 -in '{issued}' 2>/dev/null", check=False)
        prv = read_text(key)
        if not all([ca.strip(), ta.strip(), crt.strip(), prv.strip()]):
            raise RuntimeError("OpenVPN certificate material is incomplete.")

        content = (
            "client\n"
            "dev tun\n"
            f"proto {final_proto}\n"
            f"remote {host} {final_port}\n"
            "resolv-retry infinite\n"
            "nobind\n"
            "persist-key\n"
            "persist-tun\n"
            "remote-cert-tls server\n"
            f"cipher {self.defaults['cipher']}\n"
            f"data-ciphers {self.defaults['cipher']}\n"
            f"auth {self.defaults['auth']}\n"
            "verb 3\n"
            "key-direction 1\n"
            "<ca>\n"
            f"{ca}\n"
            "</ca>\n"
            "<cert>\n"
            f"{crt}\n"
            "</cert>\n"
            "<key>\n"
            f"{prv}\n"
            "</key>\n"
            "<tls-auth>\n"
            f"{ta}\n"
            "</tls-auth>\n"
        )
        self.clients_dir.mkdir(parents=True, exist_ok=True)
        out = self.clients_dir / f"{name}.ovpn"
        write_text(out, content, mode=0o600)
        return out

    def install(self):
        self._install_packages()
        public_iface = self._detect_iface()
        public_ip = self._server_ip()

        self.server_dir.mkdir(parents=True, exist_ok=True)
        self.clients_dir.mkdir(parents=True, exist_ok=True)
        self.easyrsa_dir.mkdir(parents=True, exist_ok=True)
        run(f"mkdir -p '{self.server_dir / 'ccd'}'")
        run(f"cp -r /usr/share/easy-rsa/* '{self.easyrsa_dir}/'", check=False)
        run(f"chmod 700 '{self.easyrsa_dir}'", check=False)

        pki_ca = self.easyrsa_dir / "pki" / "ca.crt"
        if not pki_ca.exists():
            run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa init-pki")
            run(
                f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 "
                f"./easyrsa --req-cn='{self.defaults['easyrsa_cn']}' build-ca nopass"
            )
            run(
                f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 "
                f"./easyrsa build-server-full '{self.defaults['server_cn']}' nopass"
            )
            run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa gen-dh")
            run(f"openvpn --genkey secret '{self.server_dir / 'ta.key'}'")
            run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa gen-crl")

            run(f"cp '{self.easyrsa_dir / 'pki/ca.crt'}' '{self.server_dir / 'ca.crt'}'")
            run(f"cp '{self.easyrsa_dir / 'pki/issued/server.crt'}' '{self.server_dir / 'server.crt'}'")
            run(f"cp '{self.easyrsa_dir / 'pki/private/server.key'}' '{self.server_dir / 'server.key'}'")
            run(f"cp '{self.easyrsa_dir / 'pki/dh.pem'}' '{self.server_dir / 'dh.pem'}'")
            run(f"cp '{self.easyrsa_dir / 'pki/crl.pem'}' '{self.server_dir / 'crl.pem'}'")
            run(f"chmod 600 '{self.server_dir / 'server.key'}' '{self.server_dir / 'ta.key'}'", check=False)
            run(f"chmod 644 '{self.server_dir / 'crl.pem'}'", check=False)

        for proto in ["udp", "tcp"]:
            item = self._instance(proto)
            self._write_server_conf(
                item["conf"],  # type: ignore[arg-type]
                str(item["dev"]),
                str(item["port"]),
                proto,
                str(item["net"]),
                str(item["mask"]),
                self.defaults["dns1"],
                self.defaults["dns2"],
            )
        write_text(Path("/etc/sysctl.d/99-openvpn-forwarding.conf"), "net.ipv4.ip_forward=1\n", mode=0o644)
        run("sysctl --system >/dev/null", check=False)
        listener_networks = [
            (str(item["dev"]), str(item["net"]), str(item["mask"]))
            for item in self.instances.values()
        ]
        self._configure_nat_service(public_iface, listener_networks)
        for item in self.instances.values():
            service = str(item["service"])
            run(f"systemctl enable --now {service}", check=False)
            run(f"systemctl restart {service}", check=False)

        return {
            "status": "installed",
            "protocol": "openvpn",
            "server_ip": public_ip,
            "port": str(self.instances["udp"]["port"]),
            "proto": "udp",
            "network": f"{self.instances['udp']['net']}/{self._mask_to_cidr(str(self.instances['udp']['mask']))}",
            "tcp_port": str(self.instances["tcp"]["port"]),
            "tcp_proto": "tcp",
            "tcp_network": f"{self.instances['tcp']['net']}/{self._mask_to_cidr(str(self.instances['tcp']['mask']))}",
            "interface": public_iface,
        }

    def _install_packages(self) -> None:
        if run("command -v apt-get >/dev/null 2>&1 && echo yes || echo no", check=False) == "yes":
            run("export DEBIAN_FRONTEND=noninteractive; apt-get update")
            run("apt-get install -y openvpn easy-rsa iptables openssl curl")
            return
        raise RuntimeError("OpenVPN auto-install currently supports apt-based systems only.")

    def _detect_iface(self) -> str:
        iface = run(
            "ip -4 route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}'",
            check=False,
        )
        if not iface:
            raise RuntimeError("Cannot detect public network interface.")
        return iface

    def uninstall(self):
        run("systemctl disable --now openvpn-nat.service 2>/dev/null || true", check=False)
        for item in self.instances.values():
            service = str(item["service"])
            run(f"systemctl disable --now {service} 2>/dev/null || true", check=False)
        run(f"sh '{self.nat_script}' remove 2>/dev/null || true", check=False)
        run(f"rm -f '{self.nat_script}'", check=False)
        run(f"rm -f '{self.nat_service_file}'", check=False)
        run(f"rm -f '{self.server_conf}' '{self.server_tcp_conf}'", check=False)
        run(f"rm -rf '{self.server_dir}'", check=False)
        run(f"rm -rf '{self.clients_dir}'", check=False)
        run("rm -f /etc/sysctl.d/99-openvpn-forwarding.conf", check=False)
        run("systemctl daemon-reload", check=False)
        run("sysctl --system >/dev/null", check=False)
        leftovers = [
            p
            for p in [
                self.server_dir,
                self.clients_dir,
                self.nat_script,
                self.nat_service_file,
                Path("/etc/sysctl.d/99-openvpn-forwarding.conf"),
            ]
            if p.exists()
        ]
        if leftovers:
            raise RuntimeError("Uninstall incomplete: " + ", ".join(str(p) for p in leftovers))
        return {"status": "uninstalled", "protocol": "openvpn"}

    def list_clients(self):
        issued = self.easyrsa_dir / "pki" / "issued"
        if not issued.exists():
            return []
        out: list[str] = []
        for crt in sorted(issued.glob("*.crt")):
            name = crt.stem
            if name not in {"server", "ca"}:
                out.append(name)
        return out

    def create_client(
        self,
        name: str,
        remote_host: str | None = None,
        remote_port: str | None = None,
        proto: str | None = None,
    ):
        if proto:
            self._validate_proto(proto)
        path = self._build_ovpn(name, remote_host=remote_host, remote_port=remote_port, proto=proto)
        default_port, default_proto = self._server_port_proto(preferred_proto=proto)
        return {
            "client": name,
            "config": str(path),
            "remote_host": remote_host or self._server_ip(),
            "remote_port": remote_port or default_port,
            "proto": proto or default_proto,
        }

    def delete_client(self, name: str):
        run(f"cd '{self.easyrsa_dir}' && EASYRSA_BATCH=1 ./easyrsa revoke '{name}'", check=False)
        run(f"cd '{self.easyrsa_dir}' && EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl", check=False)
        crl = self.easyrsa_dir / "pki" / "crl.pem"
        if crl.exists():
            run(f"cp '{crl}' '{self.server_dir}/crl.pem'", check=False)
            expected = f"crl-verify {self.server_dir}/crl.pem"
            for conf_path in [self.server_conf, self.server_tcp_conf]:
                if not conf_path.exists():
                    continue
                conf = read_text(conf_path)
                if expected not in conf:
                    write_text(conf_path, conf.rstrip() + f"\n{expected}\n", mode=0o600)
        (self.clients_dir / f"{name}.ovpn").unlink(missing_ok=True)
        self._service_restart()
        return {"revoked": name}

    def rename_client(self, name: str, new_name: str):
        if name == new_name:
            raise RuntimeError("Old and new names are identical.")
        existing_clients = set(self.list_clients())
        if name not in existing_clients:
            raise RuntimeError(f"Client '{name}' not found.")
        if new_name in existing_clients:
            raise RuntimeError(f"Client '{new_name}' already exists.")
        new_path = self._build_ovpn(new_name)
        self.delete_client(name)
        return {
            "renamed": name,
            "to": new_name,
            "note": "OpenVPN rename is performed as create-new + revoke-old.",
            "config": str(new_path),
        }

    def update_server(self, updates: dict[str, str]):
        dns1 = None
        dns2 = None
        target_proto = self.primary_proto
        by_proto: dict[str, dict[str, str]] = {"udp": {}, "tcp": {}}

        def _validate_port(value: str) -> None:
            if not value.isdigit() or not (1 <= int(value) <= 65535):
                raise RuntimeError("port must be 1..65535")

        for key, value in updates.items():
            low = key.lower()
            if low == "proto":
                self._validate_proto(value)
                target_proto = value
            elif low == "port":
                _validate_port(value)
                by_proto[target_proto]["port"] = value
            elif low == "udp_port":
                _validate_port(value)
                by_proto["udp"]["port"] = value
            elif low == "tcp_port":
                _validate_port(value)
                by_proto["tcp"]["port"] = value
            elif low == "subnet":
                by_proto[target_proto]["subnet"] = value
            elif low == "mask":
                self._mask_to_cidr(value)
                by_proto[target_proto]["mask"] = value
            elif low == "udp_subnet":
                by_proto["udp"]["subnet"] = value
            elif low == "udp_mask":
                self._mask_to_cidr(value)
                by_proto["udp"]["mask"] = value
            elif low == "tcp_subnet":
                by_proto["tcp"]["subnet"] = value
            elif low == "tcp_mask":
                self._mask_to_cidr(value)
                by_proto["tcp"]["mask"] = value
            elif low == "dns1":
                dns1 = value
            elif low == "dns2":
                dns2 = value
            else:
                raise RuntimeError(f"Unsupported OpenVPN server key: {key}")

        listeners_changed = False
        for proto in ["udp", "tcp"]:
            conf_path = self._instance(proto)["conf"]  # type: ignore[arg-type]
            if not conf_path.exists():
                continue
            port = by_proto[proto].get("port")
            if port:
                self._set_server_line(conf_path, "port", port)
                listeners_changed = True
            subnet = by_proto[proto].get("subnet")
            mask = by_proto[proto].get("mask")
            if subnet or mask:
                conf = read_text(conf_path)
                m = re.search(r"^server\s+(\S+)\s+(\S+)$", conf, flags=re.MULTILINE)
                current_subnet = m.group(1) if m else str(self._instance(proto)["net"])
                current_mask = m.group(2) if m else str(self._instance(proto)["mask"])
                self._set_server_network(conf_path, subnet or current_subnet, mask or current_mask)
                listeners_changed = True

        if dns1 is not None or dns2 is not None:
            for proto in ["udp", "tcp"]:
                conf_path = self._instance(proto)["conf"]  # type: ignore[arg-type]
                if not conf_path.exists():
                    continue
                conf = read_text(conf_path)
                existing_dns = re.findall(r'^push "dhcp-option DNS ([^"]+)"$', conf, flags=re.MULTILINE)
                final_dns1 = dns1 if dns1 is not None else (existing_dns[0] if existing_dns else self.defaults["dns1"])
                final_dns2 = dns2 if dns2 is not None else (existing_dns[1] if len(existing_dns) > 1 else self.defaults["dns2"])
                self._set_dns_push(conf_path, final_dns1, final_dns2)
                listeners_changed = True

        if listeners_changed:
            listener_networks: list[tuple[str, str, str]] = []
            for proto in ["udp", "tcp"]:
                item = self._instance(proto)
                conf_path = item["conf"]  # type: ignore[assignment]
                net = str(item["net"])
                mask = str(item["mask"])
                if isinstance(conf_path, Path) and conf_path.exists():
                    conf = read_text(conf_path)
                    m = re.search(r"^server\s+(\S+)\s+(\S+)$", conf, flags=re.MULTILINE)
                    if m:
                        net = m.group(1)
                        mask = m.group(2)
                listener_networks.append((str(item["dev"]), net, mask))
            self._configure_nat_service(self._detect_iface(), listener_networks)

        self._service_restart()
        return {"updated_server_keys": ",".join(sorted(updates.keys()))}

    def update_client(self, name: str, updates: dict[str, str]):
        path = self.clients_dir / f"{name}.ovpn"
        if not path.exists():
            path = self._build_ovpn(name)

        content = read_text(path)
        lines = content.splitlines()
        for key, value in updates.items():
            low = key.lower()
            if low == "remote_host":
                updated = False
                for i, line in enumerate(lines):
                    if line.startswith("remote "):
                        parts = line.split()
                        if len(parts) >= 3:
                            lines[i] = f"remote {value} {parts[2]}"
                            updated = True
                            break
                if not updated:
                    raise RuntimeError("remote line not found in client config")
            elif low == "remote_port":
                if not value.isdigit():
                    raise RuntimeError("remote_port must be numeric")
                updated = False
                for i, line in enumerate(lines):
                    if line.startswith("remote "):
                        parts = line.split()
                        if len(parts) >= 3:
                            lines[i] = f"remote {parts[1]} {value}"
                            updated = True
                            break
                if not updated:
                    raise RuntimeError("remote line not found in client config")
            elif low == "proto":
                if value not in {"udp", "tcp"}:
                    raise RuntimeError("proto must be udp or tcp")
                for i, line in enumerate(lines):
                    if line.startswith("proto "):
                        lines[i] = f"proto {value}"
                        break
            else:
                raise RuntimeError(f"Unsupported OpenVPN client key: {key}")

        write_text(path, "\n".join(lines).rstrip() + "\n", mode=0o600)
        return {"updated_client": name, "keys": ",".join(sorted(updates.keys())), "config": str(path)}

    def show_client_config_path(self, name: str):
        path = self.clients_dir / f"{name}.ovpn"
        if not path.exists():
            path = self._build_ovpn(name)
        return {"client": name, "path": str(path)}
__VPN_MGR_d0658e66c06df652231ec7cbb63f97f52ebe2c5c7f4b7da9__
cat > "$TARGET/vpn_protocols/outline.py" <<'__VPN_MGR_81af53cec2df2b41ca01d3f781dc31c46e98b31a368f2ae7__'
from __future__ import annotations

import base64
import json
import secrets
import string
import textwrap
from pathlib import Path

from .shared import read_text, run, sanitize_client_name, write_text


class OutlineManager:
    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.config_dir = Path("/etc/outline-ss-server")
        self.config_path = self.config_dir / "config.yml"
        self.clients_dir = self.config_dir / "clients"
        self.binary = Path("/usr/local/bin/outline-ss-server")
        self.service = "outline-ss-server"
        self.port = 12345
        self.cipher = "chacha20-ietf-poly1305"

    def _server_ip(self) -> str:
        ip = run("curl -4 -s https://ifconfig.me", check=False)
        if not ip:
            ip = run("hostname -I | awk '{print $1}'", check=False)
        if not ip:
            raise RuntimeError("Cannot detect server IP.")
        return ip.strip()

    def _random_secret(self, length: int = 16) -> str:
        alphabet = string.ascii_letters + string.digits
        return "".join(secrets.choice(alphabet) for _ in range(length))

    def _load_config(self) -> dict:
        text = read_text(self.config_path)
        if not text:
            return {}
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            keys = []
            current = {}
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("- id:"):
                    if current:
                        keys.append(current)
                    current = {"id": stripped.split(":", 1)[1].strip()}
                elif stripped.startswith("name:") and current is not None:
                    current["name"] = stripped.split(":", 1)[1].strip()
                elif stripped.startswith("cipher:") and current is not None:
                    current["cipher"] = stripped.split(":", 1)[1].strip()
                elif stripped.startswith("secret:") and current is not None:
                    current["secret"] = stripped.split(":", 1)[1].strip()
            if current:
                keys.append(current)
            return {
                "services": [
                    {
                        "listeners": [
                            {"type": "tcp", "address": f"[::]:{self.port}"},
                            {"type": "udp", "address": f"[::]:{self.port}"},
                        ],
                        "keys": keys,
                    }
                ]
            }

    def _write_config(self, data: dict) -> None:
        write_text(self.config_path, json.dumps(data, ensure_ascii=True, indent=2), mode=0o600)

    def _ensure_service_block(self, data: dict) -> dict:
        services = data.get("services") or []
        if services:
            return data
        services.append(
            {
                "listeners": [
                    {"type": "tcp", "address": f"[::]:{self.port}"},
                    {"type": "udp", "address": f"[::]:{self.port}"},
                ],
                "keys": [],
            }
        )
        data["services"] = services
        return data

    def _ensure_binary(self) -> None:
        if self.binary.exists():
            return
        url = "https://github.com/OutlineFoundation/tunnel-server/releases/download/v1.9.2/outline-ss-server_1.9.2_linux_x86_64.tar.gz"
        run(f"curl -L -o /tmp/outline-ss-server.tar.gz {url}")
        run("tar -xzf /tmp/outline-ss-server.tar.gz -C /tmp outline-ss-server")
        run(f"install -m 755 /tmp/outline-ss-server {self.binary}")

    def _write_unit(self) -> None:
        unit = textwrap.dedent(
            f"""\
            [Unit]
            Description=Outline Shadowsocks Server
            After=network.target

            [Service]
            Type=simple
            ExecStart={self.binary} -config {self.config_path}
            Restart=on-failure
            User=root

            [Install]
            WantedBy=multi-user.target
            """
        )
        write_text(Path("/etc/systemd/system/outline-ss-server.service"), unit, mode=0o644)

    def _restart_service(self) -> None:
        run("systemctl daemon-reload", check=False)
        run(f"systemctl enable --now {self.service}", check=False)
        run(f"systemctl restart {self.service}", check=False)

    def _build_ss_uri(self, secret: str, name: str) -> str:
        server_ip = self._server_ip()
        payload = f"{self.cipher}:{secret}@{server_ip}:{self.port}"
        b64 = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
        return f"ss://{b64}#{name}"

    def install(self):
        self._ensure_binary()
        data = self._ensure_service_block({})
        default_secret = self._random_secret()
        data["services"][0]["keys"] = [
            {
                "id": "key-1",
                "name": "default",
                "cipher": self.cipher,
                "secret": default_secret,
            }
        ]
        self._write_config(data)
        self._write_unit()
        self._restart_service()

        uri = self._build_ss_uri(default_secret, "default")
        self.clients_dir.mkdir(parents=True, exist_ok=True)
        client_path = self.clients_dir / "default.txt"
        write_text(client_path, uri + "\n", mode=0o600)

        return {
            "status": "installed",
            "protocol": "outline",
            "port": str(self.port),
            "cipher": self.cipher,
            "client": "default",
            "config": str(client_path),
            "uri": uri,
        }

    def uninstall(self):
        run(f"systemctl disable --now {self.service}", check=False)
        run("rm -f /etc/systemd/system/outline-ss-server.service", check=False)
        run(f"rm -f {self.binary}", check=False)
        run(f"rm -rf {self.config_dir}", check=False)
        run("systemctl daemon-reload", check=False)
        leftovers = [
            p
            for p in [
                Path("/etc/systemd/system/outline-ss-server.service"),
                self.binary,
                self.config_dir,
            ]
            if p.exists()
        ]
        if leftovers:
            raise RuntimeError("Uninstall incomplete: " + ", ".join(str(p) for p in leftovers))
        return {"status": "uninstalled", "protocol": "outline"}

    def _get_keys(self) -> list[dict]:
        data = self._ensure_service_block(self._load_config())
        keys = data.get("services", [{}])[0].get("keys") or []
        return keys

    def _find_key(self, name: str) -> dict | None:
        safe = sanitize_client_name(name)
        for key in self._get_keys():
            if key.get("name") == safe:
                return key
        return None

    def list_clients(self):
        keys = self._get_keys()
        out: list[str] = []
        for key in keys:
            name = key.get("name") or key.get("id") or "unknown"
            out.append(name)
        return out

    def create_client(self, name: str):
        safe = sanitize_client_name(name)
        data = self._ensure_service_block(self._load_config())
        keys = data["services"][0].get("keys") or []
        for key in keys:
            if key.get("name") == safe:
                raise RuntimeError(f"Client '{safe}' already exists.")
        secret = self._random_secret()
        key_entry = {
            "id": f"key-{safe}",
            "name": safe,
            "cipher": self.cipher,
            "secret": secret,
        }
        keys.append(key_entry)
        data["services"][0]["keys"] = keys
        self._write_config(data)
        self._restart_service()

        uri = self._build_ss_uri(secret, safe)
        self.clients_dir.mkdir(parents=True, exist_ok=True)
        client_path = self.clients_dir / f"{safe}.txt"
        write_text(client_path, uri + "\n", mode=0o600)
        return {"client": safe, "config": str(client_path), "uri": uri}

    def delete_client(self, name: str):
        safe = sanitize_client_name(name)
        data = self._ensure_service_block(self._load_config())
        keys = data["services"][0].get("keys") or []
        new_keys = [k for k in keys if k.get("name") != safe]
        if len(new_keys) == len(keys):
            raise RuntimeError(f"Client '{safe}' not found.")
        data["services"][0]["keys"] = new_keys
        self._write_config(data)
        self._restart_service()
        (self.clients_dir / f"{safe}.txt").unlink(missing_ok=True)
        return {"deleted": safe}

    def rename_client(self, name: str, new_name: str):
        safe_old = sanitize_client_name(name)
        safe_new = sanitize_client_name(new_name)
        if safe_old == safe_new:
            raise RuntimeError("Old and new names are identical.")
        data = self._ensure_service_block(self._load_config())
        keys = data["services"][0].get("keys") or []
        if any(k.get("name") == safe_new for k in keys):
            raise RuntimeError(f"Client '{safe_new}' already exists.")
        found = False
        for key in keys:
            if key.get("name") == safe_old:
                key["name"] = safe_new
                key["id"] = f"key-{safe_new}"
                found = True
                break
        if not found:
            raise RuntimeError(f"Client '{safe_old}' not found.")
        data["services"][0]["keys"] = keys
        self._write_config(data)
        self._restart_service()
        old_path = self.clients_dir / f"{safe_old}.txt"
        old_path.unlink(missing_ok=True)
        secret = None
        for key in keys:
            if key.get("name") == safe_new:
                secret = key.get("secret")
        uri = self._build_ss_uri(secret, safe_new) if secret else ""
        new_path = self.clients_dir / f"{safe_new}.txt"
        if uri:
            write_text(new_path, uri + "\n", mode=0o600)
        return {"renamed": safe_old, "to": safe_new, "config": str(new_path)}

    def update_client(self, name: str, updates: dict[str, str]):
        raise RuntimeError("update-client is not supported for outline.")

    def update_server(self, updates: dict[str, str]):
        raise RuntimeError("update-server is not supported for outline.")

    def show_client_config_path(self, name: str):
        safe = sanitize_client_name(name)
        path = self.clients_dir / f"{safe}.txt"
        if not path.exists():
            key = self._find_key(safe)
            if not key:
                raise RuntimeError(f"Client config not found: {path}")
            secret = key.get("secret")
            uri = self._build_ss_uri(secret, safe) if secret else ""
            if not uri:
                raise RuntimeError(f"Client config not found: {path}")
            self.clients_dir.mkdir(parents=True, exist_ok=True)
            write_text(path, uri + "\n", mode=0o600)
        return {"client": safe, "path": str(path)}
__VPN_MGR_81af53cec2df2b41ca01d3f781dc31c46e98b31a368f2ae7__
cat > "$TARGET/vpn_protocols/xray_reality.py" <<'__VPN_MGR_74e64cd292c734088097364aeae321def3f9d0d047819b63__'
from __future__ import annotations

import json
import secrets
import urllib.parse
from pathlib import Path

from .shared import read_text, run, sanitize_client_name, write_text


class XrayRealityManager:
    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.config_path = Path("/usr/local/etc/xray/config.json")
        self.clients_dir = Path("/etc/xray/clients")
        self.service = "xray"
        self.port = 443
        self.server_names = ["www.cloudflare.com", "cloudflare.com"]
        self.dest = "www.cloudflare.com:443"
        self.flow = "xtls-rprx-vision"

    def _server_ip(self) -> str:
        ip = run("curl -4 -s https://ifconfig.me", check=False)
        if not ip:
            ip = run("hostname -I | awk '{print $1}'", check=False)
        if not ip:
            raise RuntimeError("Cannot detect server IP.")
        return ip.strip()

    def _uuid(self) -> str:
        value = run("/usr/local/bin/xray uuid", check=False)
        if not value:
            raise RuntimeError("Failed to generate UUID with xray.")
        return value.strip()

    def _x25519(self) -> tuple[str, str]:
        out = run("/usr/local/bin/xray x25519", check=False)
        private_key = ""
        public_key = ""
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("PrivateKey:"):
                private_key = line.split(":", 1)[1].strip()
            if line.startswith("Password (PublicKey):"):
                public_key = line.split(":", 1)[1].strip()
        if not private_key or not public_key:
            raise RuntimeError("Failed to generate X25519 keypair.")
        return private_key, public_key

    def _short_id(self) -> str:
        return secrets.token_hex(4)

    def _ensure_xray_installed(self) -> None:
        if Path("/usr/local/bin/xray").exists():
            return
        if run("command -v apt-get >/dev/null 2>&1 && echo yes || echo no", check=False).strip() == "yes":
            run(
                "export DEBIAN_FRONTEND=noninteractive; "
                "for i in 1 2 3; do "
                "apt-get update -qq && apt-get install -y curl unzip ca-certificates qrencode && exit 0; "
                "sleep 2; "
                "done; "
                "echo 'Failed to install xray prerequisites (curl/unzip/ca-certificates/qrencode) via apt.' >&2; "
                "exit 1"
            )
        installer_url = "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        installer_path = "/tmp/xray-install-release.sh"
        run("command -v bash >/dev/null 2>&1 || { echo 'bash is required to install xray'; exit 1; }")
        run(f"curl -fsSL '{installer_url}' -o '{installer_path}'")
        run(f"bash '{installer_path}' install")
        run(f"rm -f '{installer_path}'", check=False)

    def _default_config(self, client_uuid: str, private_key: str, short_id: str) -> dict[str, object]:
        return {
            "log": {
                "access": "/var/log/xray/access.log",
                "error": "/var/log/xray/error.log",
                "loglevel": "warning",
            },
            "inbounds": [
                {
                    "listen": "0.0.0.0",
                    "port": self.port,
                    "protocol": "vless",
                    "settings": {
                        "clients": [
                            {
                                "id": client_uuid,
                                "flow": self.flow,
                                "email": "default",
                            }
                        ],
                        "decryption": "none",
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": {
                            "show": False,
                            "dest": self.dest,
                            "xver": 0,
                            "serverNames": self.server_names,
                            "privateKey": private_key,
                            "minClientVer": "",
                            "maxClientVer": "",
                            "maxTimeDiff": 0,
                            "shortIds": [short_id],
                        },
                    },
                    "sniffing": {
                        "enabled": True,
                        "destOverride": ["http", "tls", "quic"],
                    },
                }
            ],
            "outbounds": [
                {"protocol": "freedom", "tag": "direct"},
                {"protocol": "blackhole", "tag": "block"},
            ],
        }

    def _load_config(self) -> dict[str, object]:
        raw = read_text(self.config_path)
        if not raw:
            raise RuntimeError(f"Xray config not found: {self.config_path}")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Invalid Xray config JSON: {exc}") from exc
        if not isinstance(data, dict):
            raise RuntimeError("Xray config root must be an object.")
        return data

    def _save_config(self, config: dict[str, object]) -> None:
        write_text(self.config_path, json.dumps(config, ensure_ascii=True, indent=2), mode=0o644)

    def _find_inbound(self, config: dict[str, object]) -> dict[str, object]:
        inbounds = config.get("inbounds")
        if not isinstance(inbounds, list):
            raise RuntimeError("Invalid Xray config: 'inbounds' missing.")
        for inbound in inbounds:
            if not isinstance(inbound, dict):
                continue
            if inbound.get("protocol") != "vless":
                continue
            stream = inbound.get("streamSettings")
            if not isinstance(stream, dict):
                continue
            if stream.get("security") == "reality":
                return inbound
        raise RuntimeError("VLESS Reality inbound not found in Xray config.")

    def _clients(self, inbound: dict[str, object]) -> list[dict[str, object]]:
        settings = inbound.get("settings")
        if not isinstance(settings, dict):
            raise RuntimeError("Invalid Xray inbound: settings missing.")
        clients = settings.get("clients")
        if not isinstance(clients, list):
            empty_clients: list[dict[str, object]] = []
            settings["clients"] = empty_clients
            return empty_clients
        clean: list[dict[str, object]] = []
        for item in clients:
            if isinstance(item, dict):
                clean.append(item)
        settings["clients"] = clean
        return clean

    def _public_key(self, inbound: dict[str, object]) -> str:
        stream = inbound.get("streamSettings")
        if not isinstance(stream, dict):
            raise RuntimeError("Invalid Xray inbound stream settings.")
        reality = stream.get("realitySettings")
        if not isinstance(reality, dict):
            raise RuntimeError("Invalid Xray reality settings.")
        public_key = reality.get("publicKey")
        if isinstance(public_key, str) and public_key:
            return public_key
        private_key = reality.get("privateKey")
        if not isinstance(private_key, str) or not private_key:
            raise RuntimeError("Xray reality privateKey not found.")
        out = run(f"/usr/local/bin/xray x25519 -i '{private_key}'", check=False)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("Password (PublicKey):"):
                value = line.split(":", 1)[1].strip()
                if value:
                    reality["publicKey"] = value
                    return value
        raise RuntimeError("Cannot derive reality public key.")

    def _short_id_from_inbound(self, inbound: dict[str, object]) -> str:
        stream = inbound.get("streamSettings")
        if not isinstance(stream, dict):
            raise RuntimeError("Invalid Xray inbound stream settings.")
        reality = stream.get("realitySettings")
        if not isinstance(reality, dict):
            raise RuntimeError("Invalid Xray reality settings.")
        short_ids = reality.get("shortIds")
        if isinstance(short_ids, list):
            for value in short_ids:
                if isinstance(value, str) and value:
                    return value
        raise RuntimeError("Xray reality shortIds not found.")

    def _sni_from_inbound(self, inbound: dict[str, object]) -> str:
        stream = inbound.get("streamSettings")
        if not isinstance(stream, dict):
            raise RuntimeError("Invalid Xray inbound stream settings.")
        reality = stream.get("realitySettings")
        if not isinstance(reality, dict):
            raise RuntimeError("Invalid Xray reality settings.")
        names = reality.get("serverNames")
        if isinstance(names, list):
            for value in names:
                if isinstance(value, str) and value:
                    return value
        raise RuntimeError("Xray reality serverNames not found.")

    def _port_from_inbound(self, inbound: dict[str, object]) -> int:
        port = inbound.get("port")
        if not isinstance(port, int):
            raise RuntimeError("Xray inbound port is invalid.")
        return port

    def _build_uri(self, name: str, client_id: str, inbound: dict[str, object]) -> str:
        server_ip = self._server_ip()
        sni = self._sni_from_inbound(inbound)
        pbk = self._public_key(inbound)
        sid = self._short_id_from_inbound(inbound)
        port = self._port_from_inbound(inbound)
        fragment = urllib.parse.quote(name, safe="")
        spx = urllib.parse.quote("/", safe="")
        return (
            f"vless://{client_id}@{server_ip}:{port}"
            f"?type=tcp&security=reality&encryption=none&flow={self.flow}"
            f"&sni={urllib.parse.quote(sni, safe='')}"
            f"&fp=chrome&pbk={urllib.parse.quote(pbk, safe='')}"
            f"&sid={urllib.parse.quote(sid, safe='')}&spx={spx}#{fragment}"
        )

    def _write_client_uri(self, name: str, uri: str) -> Path:
        self.clients_dir.mkdir(parents=True, exist_ok=True)
        path = self.clients_dir / f"{name}.txt"
        write_text(path, uri + "\n", mode=0o600)
        return path

    def _restart(self) -> None:
        run("systemctl daemon-reload", check=False)
        run(f"systemctl enable --now {self.service}", check=False)
        run(f"systemctl restart {self.service}", check=False)
        run("iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 443 -j ACCEPT", check=False)

    def install(self):
        self._ensure_xray_installed()
        client_uuid = self._uuid()
        private_key, _ = self._x25519()
        short_id = self._short_id()
        config = self._default_config(client_uuid, private_key, short_id)
        inbound = self._find_inbound(config)
        uri = self._build_uri("default", client_uuid, inbound)
        self._save_config(config)
        self._restart()
        path = self._write_client_uri("default", uri)
        return {
            "status": "installed",
            "protocol": "xray",
            "port": str(self.port),
            "client": "default",
            "config": str(path),
            "uri": uri,
        }

    def uninstall(self):
        run(f"systemctl disable --now {self.service} 2>/dev/null || true", check=False)
        run("rm -rf /usr/local/etc/xray", check=False)
        run("rm -rf /etc/xray", check=False)
        leftovers = [p for p in [Path("/usr/local/etc/xray"), Path("/etc/xray")] if p.exists()]
        if leftovers:
            raise RuntimeError("Uninstall incomplete: " + ", ".join(str(p) for p in leftovers))
        return {"status": "uninstalled", "protocol": "xray"}

    def list_clients(self):
        config = self._load_config()
        inbound = self._find_inbound(config)
        clients = self._clients(inbound)
        result: list[str] = []
        for item in clients:
            email = item.get("email")
            if isinstance(email, str) and email.strip():
                result.append(email.strip())
        return sorted(result)

    def _find_client(self, clients: list[dict[str, object]], name: str) -> dict[str, object] | None:
        for item in clients:
            email = item.get("email")
            if isinstance(email, str) and email == name:
                return item
        return None

    def create_client(self, name: str):
        safe = sanitize_client_name(name)
        config = self._load_config()
        inbound = self._find_inbound(config)
        clients = self._clients(inbound)
        if self._find_client(clients, safe):
            raise RuntimeError(f"Client '{safe}' already exists.")
        client_uuid = self._uuid()
        clients.append({"id": client_uuid, "flow": self.flow, "email": safe})
        self._save_config(config)
        self._restart()
        uri = self._build_uri(safe, client_uuid, inbound)
        path = self._write_client_uri(safe, uri)
        return {"client": safe, "config": str(path), "uri": uri}

    def delete_client(self, name: str):
        safe = sanitize_client_name(name)
        config = self._load_config()
        inbound = self._find_inbound(config)
        clients = self._clients(inbound)
        kept: list[dict[str, object]] = []
        removed = False
        for item in clients:
            email = item.get("email")
            if isinstance(email, str) and email == safe:
                removed = True
                continue
            kept.append(item)
        if not removed:
            raise RuntimeError(f"Client '{safe}' not found.")
        settings = inbound.get("settings")
        if not isinstance(settings, dict):
            raise RuntimeError("Invalid Xray inbound settings.")
        settings["clients"] = kept
        self._save_config(config)
        self._restart()
        (self.clients_dir / f"{safe}.txt").unlink(missing_ok=True)
        return {"deleted": safe}

    def rename_client(self, name: str, new_name: str):
        old = sanitize_client_name(name)
        new = sanitize_client_name(new_name)
        if old == new:
            raise RuntimeError("Old and new names are identical.")
        config = self._load_config()
        inbound = self._find_inbound(config)
        clients = self._clients(inbound)
        if self._find_client(clients, new):
            raise RuntimeError(f"Client '{new}' already exists.")
        client = self._find_client(clients, old)
        if not client:
            raise RuntimeError(f"Client '{old}' not found.")
        client["email"] = new
        self._save_config(config)
        self._restart()
        client_id = client.get("id")
        if not isinstance(client_id, str) or not client_id:
            raise RuntimeError("Client UUID missing.")
        uri = self._build_uri(new, client_id, inbound)
        path = self._write_client_uri(new, uri)
        (self.clients_dir / f"{old}.txt").unlink(missing_ok=True)
        return {"renamed": old, "to": new, "config": str(path)}

    def update_server(self, updates: dict[str, str]):
        raise RuntimeError("update-server is not supported for xray.")

    def update_client(self, name: str, updates: dict[str, str]):
        raise RuntimeError("update-client is not supported for xray.")

    def show_client_config_path(self, name: str):
        safe = sanitize_client_name(name)
        path = self.clients_dir / f"{safe}.txt"
        if path.exists():
            return {"client": safe, "path": str(path)}
        config = self._load_config()
        inbound = self._find_inbound(config)
        clients = self._clients(inbound)
        client = self._find_client(clients, safe)
        if not client:
            raise RuntimeError(f"Client config not found: {path}")
        client_id = client.get("id")
        if not isinstance(client_id, str) or not client_id:
            raise RuntimeError("Client UUID missing.")
        uri = self._build_uri(safe, client_id, inbound)
        out = self._write_client_uri(safe, uri)
        return {"client": safe, "path": str(out)}
__VPN_MGR_74e64cd292c734088097364aeae321def3f9d0d047819b63__
cat > "$TARGET/vpn_protocols/shared.py" <<'__VPN_MGR_1c8d8217f0e9c9888c80ee23947a89057ce4f4d99b2d0705__'
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


def require_root() -> None:
    if os.geteuid() != 0:
        raise PermissionError("Run as root: sudo python3 vpn_manager.py ...")


def sanitize_client_name(name: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9_-]", "", name.strip().lower().replace(" ", "_"))
    if not normalized:
        raise ValueError("Client name contains no valid characters.")
    return normalized


def run(command: str, check: bool = True) -> str:
    process = subprocess.run(command, shell=True, text=True, capture_output=True)
    if check and process.returncode != 0:
        stderr = process.stderr.strip()
        stdout = process.stdout.strip()
        details = stderr or stdout or f"Command failed: {command}"
        raise RuntimeError(details)
    return process.stdout.strip()


def read_text(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def write_text(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    os.chmod(path, mode)


def replace_or_append_line(content: str, key: str, value: str) -> str:
    pattern = rf"^{re.escape(key)}\s*=.*$"
    replacement = f"{key} = {value}"
    if re.search(pattern, content, flags=re.MULTILINE):
        return re.sub(pattern, replacement, content, flags=re.MULTILINE)
    base = content.rstrip()
    return f"{base}\n{replacement}\n" if base else f"{replacement}\n"
__VPN_MGR_1c8d8217f0e9c9888c80ee23947a89057ce4f4d99b2d0705__
cat > "$TARGET/vpn_protocols/telegram_bot.py" <<'__VPN_MGR_f0d27f3712f1635cc684cb8f9bb2a76d87f6747a33208a99__'
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
__VPN_MGR_f0d27f3712f1635cc684cb8f9bb2a76d87f6747a33208a99__
install_bundle_copy() {
  script_path="$0"
  case "$script_path" in
    /*) : ;;
    *) script_path="$(pwd)/$script_path" ;;
  esac
  if [ -f "$script_path" ]; then
    cp "$script_path" "$TARGET/vpn-unified-manager-bundle.sh" 2>/dev/null || true
    chmod 755 "$TARGET/vpn-unified-manager-bundle.sh" 2>/dev/null || true
  fi
}

install_boot_restore_unit() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  unit_file="/etc/systemd/system/vpn-unified-manager-boot.service"
  if is_root; then
    cat > "$unit_file" <<EOF
[Unit]
Description=VPN Unified Manager boot restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 "$TARGET/vpn_manager.py" backend ensure-autostart --json
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable vpn-unified-manager-boot.service >/dev/null 2>&1 || true
    systemctl start vpn-unified-manager-boot.service >/dev/null 2>&1 || true
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  cat <<EOF | sudo -n tee "$unit_file" >/dev/null || true
[Unit]
Description=VPN Unified Manager boot restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 "$TARGET/vpn_manager.py" backend ensure-autostart --json
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo -n systemctl daemon-reload >/dev/null 2>&1 || true
  sudo -n systemctl enable vpn-unified-manager-boot.service >/dev/null 2>&1 || true
  sudo -n systemctl start vpn-unified-manager-boot.service >/dev/null 2>&1 || true
}

cat > "$TARGET/servers.json" <<'__VPN_MGR_SERVERS_JSON__'
{
  "servers": []
}
__VPN_MGR_SERVERS_JSON__

chmod 755 "$TARGET/vpn_manager.py" 2>/dev/null || true
chmod 644 "$TARGET/vpn_protocols/__init__.py" \
  "$TARGET/servers.json" \
  "$TARGET/vpn_protocols/amneziawg.py" \
  "$TARGET/vpn_protocols/openvpn.py" \
  "$TARGET/vpn_protocols/outline.py" \
  "$TARGET/vpn_protocols/xray_reality.py" \
  "$TARGET/vpn_protocols/shared.py" \
  "$TARGET/vpn_protocols/telegram_bot.py" 2>/dev/null || true

install_bundle_copy

if is_root && [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER:" "$TARGET" 2>/dev/null || true
fi

install_boot_restore_unit

maybe_configure_telegram_bot

if [ "$GLOBAL" -eq 1 ]; then
  cat > /usr/local/bin/vpn-manager <<EOF
#!/bin/sh
exec python3 "$TARGET/vpn_manager.py" "\$@"
EOF
  chmod 755 /usr/local/bin/vpn-manager
  echo "Installed: $TARGET"
  echo "Command: vpn-manager"
else
  echo "Installed: $TARGET"
  echo "Run: sudo python3 $TARGET/vpn_manager.py"
fi
