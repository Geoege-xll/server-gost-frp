#!/usr/bin/env python3
"""Opt-in local protocol checks with SHA-256-verified official native binaries.

No installers or system services are run. Everything listens on random loopback
ports and is removed on exit. Requires curl and OpenSSL; downloads are explicit.
"""
import argparse
from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import platform
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_helper", ROOT / "lib/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True).stdout


def render(function, *args):
    return run("bash", "-c", 'set -euo pipefail; source "$1"; shift; "$@"',
               "integration", ROOT / "lib/deploy.sh", function, *args)


def fetch(url, path):
    run("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
        "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "180", "-o", path, url)


def native_binary(root, repo, tag, name, system, arch):
    directory = root / name
    directory.mkdir()
    downloads = directory / "downloads"
    downloads.mkdir()
    metadata = downloads / "release.json"
    fetch(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", metadata)
    asset = f"{name}_{tag.lstrip('v')}_{system}_{arch}.tar.gz"
    url, digest = release.release_asset(metadata, repo, asset)
    archive = downloads / "asset.tar.gz"
    fetch(url, archive)
    release.verify(archive, digest)
    extracted = directory / "extracted"
    extracted.mkdir()
    release.extract(archive, extracted)
    binary_name = "frps" if name == "frp" else "gost"
    binaries = list(extracted.rglob(binary_name))
    if len(binaries) != 1:
        raise RuntimeError(f"Expected exactly one {binary_name}")
    binaries[0].chmod(0o755)
    return binaries[0]


def free_port():
    with socket.socket() as stream:
        stream.bind(("127.0.0.1", 0))
        return stream.getsockname()[1]


def wait_port(port, process):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Process exited with {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            threading.Event().wait(0.1)
    raise RuntimeError(f"Loopback port {port} did not become ready")


def start(stack, root, label, *args):
    log = stack.enter_context((root / (label + ".log")).open("w+"))
    process = subprocess.Popen(list(map(str, args)), stdout=log, stderr=subprocess.STDOUT)

    def stop():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    stack.callback(stop)
    return process


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(1024)
        if data:
            self.request.sendall(data)


def check_echo(port):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as stream:
        stream.settimeout(3)
        stream.sendall(b"reverse-tunnel-test")
        if stream.recv(1024) != b"reverse-tunnel-test":
            raise RuntimeError("Reverse forward did not carry echo payload")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="Allow downloading and executing official native binaries")
    args = parser.parse_args()
    if not args.download:
        parser.error("Pass --download to explicitly enable native-binary protocol checks")
    system = platform.system().lower()
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if system not in ("darwin", "linux") or not arch:
        parser.error("Local protocol test supports macOS/Linux amd64/arm64 only")
    with tempfile.TemporaryDirectory(prefix="frp-gost-protocol-") as directory, ExitStack() as stack:
        root = Path(directory)
        try:
            gost = native_binary(root, "go-gost/gost", "v3.3.2", "gost", system, arch)
            frps = native_binary(root, "fatedier/frp", "v0.71.1", "frp", system, arch)
            frpc = next(frps.parent.rglob("frpc"))
            frpc.chmod(0o755)
            certs = root / "certs"
            render("generate_certs", certs, "127.0.0.1")
            echo = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo)
            echo.daemon_threads = True
            stack.callback(echo.server_close)
            stack.callback(echo.shutdown)
            threading.Thread(target=echo.serve_forever, daemon=True).start()
            target = echo.server_address[1]

            # GOST: same renderer as production, real mTLS relay + listener.chain.
            entry, remote = free_port(), free_port()
            server_config = root / "gost-server.yaml"
            server_config.write_text(render("render_gost_server", root, "relay_test", "relay_secret", f"127.0.0.1:{entry}"))
            run(gost, "-C", server_config, "-O", "yaml")
            server = start(stack, root, "gost-server", gost, "-C", server_config)
            wait_port(entry, server)
            client_config = root / "gost-client.json"
            client_config.write_text(json.dumps({
                "services": [{"name": "reverse-test", "addr": f"127.0.0.1:{remote}",
                              "handler": {"type": "rtcp"},
                              "listener": {"type": "rtcp", "chain": "relay-chain"},
                              "forwarder": {"nodes": [{"name": "echo", "addr": f"127.0.0.1:{target}"}]}}],
                "chains": [{"name": "relay-chain", "hops": [{"name": "hop", "nodes": [{
                    "name": "relay", "addr": f"127.0.0.1:{entry}",
                    "connector": {"type": "relay", "auth": {"username": "relay_test", "password": "relay_secret"}},
                    "dialer": {"type": "mtls", "tls": {"caFile": str(certs / "ca.crt"),
                               "certFile": str(certs / "client.crt"), "keyFile": str(certs / "client.key"),
                               "secure": True, "serverName": "127.0.0.1"}}
                }]}]}]
            }))
            client = start(stack, root, "gost-client", gost, "-C", client_config)
            wait_port(remote, client)
            check_echo(remote)
            print("PASS: GOST v3.3.2 real mTLS reverse TCP over Multiplex TLS")

            # FRP: production renderer, strict validation, v2 client and loopback proxy.
            entry, remote = free_port(), free_port()
            server_config = root / "frps.toml"
            server_config.write_text(render("render_frps_server", root, "frp_secret", entry, "127.0.0.1")
                                     .replace("single = 10001", f"single = {remote}"))
            run(frps, "verify", "-c", server_config)
            server = start(stack, root, "frps", frps, "-c", server_config)
            wait_port(entry, server)
            client_config = root / "frpc.toml"
            client_config.write_text(f'''serverAddr = "127.0.0.1"
serverPort = {entry}
auth.method = "token"
auth.token = "frp_secret"
transport.protocol = "tcp"
transport.wireProtocol = "v2"
transport.tcpMux = true
transport.tls.enable = true
transport.tls.serverName = "127.0.0.1"
transport.tls.certFile = "{certs / 'client.crt'}"
transport.tls.keyFile = "{certs / 'client.key'}"
transport.tls.trustedCaFile = "{certs / 'ca.crt'}"
[[proxies]]
name = "echo"
type = "tcp"
localIP = "127.0.0.1"
localPort = {target}
remotePort = {remote}
transport.useEncryption = false
transport.useCompression = false
''')
            run(frpc, "verify", "-c", client_config)
            client = start(stack, root, "frpc", frpc, "-c", client_config)
            wait_port(remote, client)
            check_echo(remote)
            print("PASS: FRP v0.71.1 strict configs + real mTLS/v2 reverse TCP")
        except Exception:
            # Logs contain test-only credentials, never deployment secrets.
            for log in root.glob("*.log"):
                print(f"--- {log.name} ---\n{log.read_text(errors='replace')[-12000:]}")
            raise


if __name__ == "__main__":
    main()
