#!/usr/bin/env python3
"""Rebuild vpn-unified-manager-bundle.sh: POSIX sh + heredocs, no tar/base64."""
from __future__ import annotations

import secrets
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "vpn-unified-manager-bundle.sh"

# Paths inside TARGET (same layout as repo); bytes unchanged except \r\n -> \n.
EMBED: list[str] = [
    "vpn_manager.py",
    "vpn_protocols/__init__.py",
    "vpn_protocols/amneziawg.py",
    "vpn_protocols/openvpn.py",
    "vpn_protocols/outline.py",
    "vpn_protocols/xray_reality.py",
    "vpn_protocols/shared.py",
    "vpn_protocols/telegram_bot.py",
]


def pick_delimiter(content: str) -> str:
    for _ in range(500):
        delim = "__VPN_MGR_" + secrets.token_hex(24) + "__"
        if delim not in content:
            return delim
    raise RuntimeError("could not reserve heredoc delimiter")


def main() -> None:
    chunks: list[str] = []
    chunks.append(
        """#!/bin/sh
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
  printf '%s' "$1" | tr -d '\\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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
  BOOTSTRAP_USER="$BOOTSTRAP_NEW_USER" \\
  BOOTSTRAP_SSH_PORT="$BOOTSTRAP_SSH_PORT" \\
  BOOTSTRAP_SSH_KEY="$BOOTSTRAP_SSH_KEY" \\
  BOOTSTRAP_CONTROLLER_PUB="$BOOTSTRAP_CONTROLLER_PUB" \\
  BOOTSTRAP_TELEGRAM_TOKEN="$BOOTSTRAP_TELEGRAM_TOKEN" \\
  BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID="$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" \\
  BOOTSTRAP_JSON_PATH="$bootstrap_json" \\
  VPN_PROFILE_JSON_PATH="$vpn_profile_json" \\
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

bootstrap_path.write_text(json.dumps(bootstrap_data, ensure_ascii=True, indent=2) + "\\n", encoding="utf-8")
vpn_profile_path.write_text(json.dumps(vpn_profile_data, ensure_ascii=True, indent=2) + "\\n", encoding="utf-8")
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
  printf "=== New server setup ===\\n\\n"

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
  printf "Public SSH key for new user (Enter to use controller key):\\n"
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

  printf "\\nWill perform:\\n"
  printf "  - Create user: %s\\n" "$BOOTSTRAP_NEW_USER"
  printf "  - SSH port: %s\\n" "$BOOTSTRAP_SSH_PORT"
  printf "  - Controller SSH key: %s\\n" "$BOOTSTRAP_CONTROLLER_KEY_PATH"
  printf "  - Disable root login and password authentication\\n"
  if [ -n "$BOOTSTRAP_TELEGRAM_TOKEN" ] && [ -n "$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" ]; then
    printf "  - Configure and auto-start Telegram bot after deploy\\n"
  else
    printf "  - Telegram bot setup skipped (can configure later)\\n"
  fi
  printf "  - Save profiles to /etc/vpn-unified-manager/\\n\\n"
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
    printf '%s\\n' "$BOOTSTRAP_SSH_KEY" >> "$auth_keys"
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
  BOOTSTRAP_HANDOFF_JSON="$handoff_bootstrap_json" \\
  BOOTSTRAP_TELEGRAM_TOKEN="$BOOTSTRAP_TELEGRAM_TOKEN" \\
  BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID="$BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID" \\
  python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["BOOTSTRAP_HANDOFF_JSON"])
data = {
    "telegram_token": os.environ["BOOTSTRAP_TELEGRAM_TOKEN"],
    "telegram_allowed_user_id": os.environ["BOOTSTRAP_TELEGRAM_ALLOWED_USER_ID"],
}
path.write_text(json.dumps(data, ensure_ascii=True, indent=2) + "\\n", encoding="utf-8")
PY
  chown "$BOOTSTRAP_NEW_USER:$BOOTSTRAP_NEW_USER" "$handoff_bootstrap_json"
  chmod 600 "$handoff_bootstrap_json"

  echo "Switching to user $BOOTSTRAP_NEW_USER to deploy bundle..."
  exec su - "$BOOTSTRAP_NEW_USER" -c "BOOTSTRAP_HANDOFF=1 sh \\"$handoff_script\\" --dir \\"$TARGET\\" --no-bootstrap"
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

"""
    )

    for rel in EMBED:
        src = ROOT / rel
        raw = src.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise RuntimeError(f"not utf-8: {src}") from exc
        text = text.replace("\r\n", "\n")
        if not text.endswith("\n"):
            text += "\n"
        delim = pick_delimiter(text)
        chunks.append(f'cat > "$TARGET/{rel}" <<\'{delim}\'\n')
        chunks.append(text)
        chunks.append(f"{delim}\n")

    chunks.append(
        """install_bundle_copy() {
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
chmod 644 "$TARGET/vpn_protocols/__init__.py" \\
  "$TARGET/servers.json" \\
  "$TARGET/vpn_protocols/amneziawg.py" \\
  "$TARGET/vpn_protocols/openvpn.py" \\
  "$TARGET/vpn_protocols/outline.py" \\
  "$TARGET/vpn_protocols/xray_reality.py" \\
  "$TARGET/vpn_protocols/shared.py" \\
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
exec python3 "$TARGET/vpn_manager.py" "\\$@"
EOF
  chmod 755 /usr/local/bin/vpn-manager
  echo "Installed: $TARGET"
  echo "Command: vpn-manager"
else
  echo "Installed: $TARGET"
  echo "Run: sudo python3 $TARGET/vpn_manager.py"
fi
"""
    )

    script = "".join(chunks)
    OUT.write_text(script, encoding="utf-8", newline="\n")
    OUT.chmod(0o755)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
