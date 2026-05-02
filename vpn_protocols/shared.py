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
