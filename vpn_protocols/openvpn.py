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
