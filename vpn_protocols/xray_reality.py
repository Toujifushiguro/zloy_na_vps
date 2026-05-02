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
