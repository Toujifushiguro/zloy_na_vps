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
