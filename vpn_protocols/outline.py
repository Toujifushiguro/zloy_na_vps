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
