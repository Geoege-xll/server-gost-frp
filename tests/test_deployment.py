"""Offline regressions. No VPS access, package installation or service mutation."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_helper", ROOT / "lib/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def bash(script, *args, env=None):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + script, "test", *map(str, args)],
                          env=env, capture_output=True, text=True)


def release_fixture(directory, component, tag, digest="a" * 64):
    repo, pattern = {"gost": ("go-gost/gost", "gost_{version}_windows_amd64.zip"),
                     "frpc": ("fatedier/frp", "frp_{version}_windows_amd64.zip"),
                     "servy": ("aelassas/servy", "servy-{version}-net48-x64-portable.7z")}[component]
    asset = pattern.format(version=tag.lstrip("v"))
    metadata = Path(directory) / (component + "-release.json")
    metadata.write_text(json.dumps({"tag_name": tag, "assets": [{"name": asset,
        "browser_download_url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
        "digest": "sha256:" + digest if digest else None}]}))
    return metadata


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = self.root / "release.json"
        self.data = {"tag_name": "v3.3.2", "assets": [{
            "name": "binary.zip",
            "browser_download_url": "https://github.com/go-gost/gost/releases/download/v3.3.2/binary.zip",
            "digest": "sha256:" + "a" * 64,
        }]}

    def save(self):
        self.metadata.write_text(json.dumps(self.data))

    def test_official_asset(self):
        self.save()
        url, digest = release.release_asset(self.metadata, "go-gost/gost", "binary.zip")
        self.assertTrue(url.startswith("https://github.com/go-gost/gost/"))
        self.assertEqual(digest, "a" * 64)

    def test_bad_metadata_rejected(self):
        for change in ({"draft": True}, {"prerelease": True}, {"tag_name": "nightly"}, {"assets": []}):
            with self.subTest(change=change):
                data = self.data.copy()
                self.data.update(change)
                self.save()
                with self.assertRaises(ValueError):
                    release.release_asset(self.metadata, "go-gost/gost", "binary.zip")
                self.data = data

    def test_digest_required(self):
        for digest in (None, "", "sha256:bad", "md5:" + "a" * 32):
            with self.subTest(digest=digest):
                self.data["assets"][0]["digest"] = digest
                self.save()
                with self.assertRaises(ValueError):
                    release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_foreign_download_url_rejected(self):
        for url in ("https://example.org/binary.zip",
                    "https://github.com/go-gost/gost/releases/download/v3.3.2/other.zip",
                    "https://github.com/go-gost/gost/releases/download/v3.3.2/../../binary.zip",
                    "https://github.com/go-gost/gost/releases/download/v3.3.2/binary.zip?download=1"):
            with self.subTest(url=url):
                self.data["assets"][0]["browser_download_url"] = url
                self.save()
                with self.assertRaises(ValueError):
                    release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_duplicate_asset_rejected(self):
        self.data["assets"] *= 2
        self.save()
        with self.assertRaises(ValueError):
            release.release_asset(self.metadata, "go-gost/gost", "binary.zip")

    def test_hash_verification(self):
        path = self.root / "binary"
        path.write_bytes(b"test binary")
        release.verify(path, hashlib.sha256(path.read_bytes()).hexdigest())
        with self.assertRaises(ValueError):
            release.verify(path, "0" * 64)

    def test_version_compare(self):
        for current, target, expected in (("3.3.1", "v3.3.2", "1"), ("v3.3.2", "3.3.1", "-1"),
                                          ("v1.2", "1.2.0", "0"), ("v10.7", "v10.7", "0")):
            result = subprocess.run(["python3", "-I", str(ROOT / "lib/release.py"), "compare", current, target],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_pinned_windows_manifest(self):
        gost = release_fixture(self.root, "gost", "v3.3.2")
        servy = release_fixture(self.root, "servy", "v10.7")
        frp = release_fixture(self.root, "frpc", "v0.71.1")
        output = self.root / "components.json"
        for scheme, tunnel, extra in (("gost", "v3.3.2", []), ("frp", "v0.71.1", [frp])):
            with self.subTest(scheme=scheme):
                release.windows_manifest(output, scheme, tunnel, gost, servy, *extra)
                data = json.loads(output.read_text())
                self.assertEqual(data["schemaVersion"], 1)
                self.assertEqual(data["mode"], "offline")
                self.assertEqual(data["tunnelVersion"], tunnel)
                self.assertEqual(data["architecture"], "amd64")
                self.assertEqual({c["id"] for c in data["components"]},
                                 {"gost", "servy"} | ({"frpc"} if extra else set()))
                for component in data["components"]:
                    self.assertNotIn("latest", component["url"])
                    self.assertEqual(component["sha256"], "a" * 64)
                    self.assertTrue(component["url"].endswith("/" + component["asset"]))

    def test_invalid_manifest_sources_fail_closed(self):
        output = self.root / "components.json"
        for invalid in ("scheme", "digest", "client-version", "frp-metadata", "old-gost", "old-servy", "old-frp"):
            with self.subTest(invalid=invalid):
                gost = release_fixture(self.root, "gost", "v3.3.1" if invalid == "old-gost" else "v3.3.2")
                servy = release_fixture(self.root, "servy", "v10.6" if invalid == "old-servy" else "v10.7",
                                        digest=None if invalid == "digest" else "a" * 64)
                frp = release_fixture(self.root, "frpc", "v0.71.0" if invalid == "old-frp" else "v0.71.1")
                scheme = "bad" if invalid == "scheme" else "frp"
                tunnel = "v0.72.0" if invalid == "client-version" else "v0.71.1"
                extra = [] if invalid == "frp-metadata" else [frp]
                with self.assertRaises(ValueError):
                    release.windows_manifest(output, scheme, tunnel, gost, servy, *extra)
                self.assertFalse(output.exists())
        with self.assertRaises(ValueError):
            release.windows_manifest(output, "gost", "v3.3.3", gost, servy)
        with self.assertRaises(ValueError):
            release.windows_manifest(output, "gost", "v3.3.2", gost, servy, frp)

    def test_archive_paths(self):
        for name in ("../escape", "/tmp/escape", "a/../../escape", "a\\b", "C:/escape"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.archive_path(self.root, name)

    def test_archive_extract(self):
        for kind in ("zip", "tar"):
            destination = self.root / kind
            destination.mkdir()
            archive = self.root / (kind + ".archive")
            if kind == "zip":
                with zipfile.ZipFile(archive, "w") as stream:
                    stream.writestr("folder/binary", b"good")
            else:
                with tarfile.open(archive, "w:gz") as stream:
                    member = tarfile.TarInfo("folder/binary")
                    member.size = 4
                    stream.addfile(member, io.BytesIO(b"good"))
            release.extract(archive, destination)
            self.assertEqual((destination / "folder/binary").read_bytes(), b"good")
            with self.assertRaises(ValueError):
                release.extract(archive, destination)

    def test_tar_links_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            destination = self.root / kind.decode()
            destination.mkdir()
            archive = self.root / (kind.decode() + ".tar.gz")
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("link")
                member.type = kind
                member.linkname = "/etc/passwd"
                stream.addfile(member)
            with self.assertRaises(ValueError):
                release.extract(archive, destination)

    def test_zip_symlink_rejected(self):
        destination = self.root / "extract"
        destination.mkdir()
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            member = zipfile.ZipInfo("link")
            member.create_system = 3
            member.external_attr = 0o120777 << 16
            stream.writestr(member, "/etc/passwd")
        with self.assertRaises(ValueError):
            release.extract(archive, destination)

    def test_archive_traversal_rejected(self):
        destination = self.root / "extract"
        destination.mkdir()
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            stream.writestr("../escape", "bad")
        with self.assertRaises(ValueError):
            release.extract(archive, destination)
        self.assertFalse((self.root / "escape").exists())

    def test_template_encoding_and_injection(self):
        script = self.root / "setup.ps1"
        script.write_text('$IP = "VPS_PUBLIC_IP_PLACEHOLDER"\n$User = "GOST_USER_PLACEHOLDER"\n# 中文\n', encoding="utf-8")
        release.inject(self.root, ["VPS_PUBLIC_IP=203.0.113.1", "GOST_USER=user_a"])
        self.assertTrue(script.read_bytes().startswith(b"\xef\xbb\xbf"))
        self.assertNotIn(b"_PLACEHOLDER", script.read_bytes())
        self.assertNotIn(b"\n", script.read_bytes().replace(b"\r\n", b""))
        with self.assertRaises(ValueError):
            release.inject(self.root, ["GOST_USER=bad\"user"])
        with self.assertRaises(ValueError):
            release.inject(self.root, ["VPS_PUBLIC_IP=not-an-ip"])

    def test_unresolved_template_rejected(self):
        (self.root / "setup.ps1").write_text("TOKEN_PLACEHOLDER")
        with self.assertRaises(ValueError):
            release.inject(self.root, [])


class ShellTests(unittest.TestCase):
    def test_bash_syntax(self):
        for script in (ROOT / "install.sh", ROOT / "lib/deploy.sh",
                       ROOT / "01_Pure_GOST_v3/install_vps_gost_v3.sh",
                       ROOT / "02_FRP_GOST/install_vps_frp_gost.sh"):
            result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_safe_help_from_unrelated_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", str(ROOT / "install.sh"), "--help"], cwd=directory,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for scheme in ("01_Pure_GOST_v3/install_vps_gost_v3.sh", "02_FRP_GOST/install_vps_frp_gost.sh"):
                result = subprocess.run(["bash", str(ROOT / scheme), "--help"], cwd=directory,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_supported_architecture(self):
        for source, expected in (("x86_64", "amd64"), ("aarch64", "arm64"), ("riscv64", None)):
            result = bash('source "$1"; linux_arch "$2"', ROOT / "lib/deploy.sh", source)
            if expected:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
            else:
                self.assertNotEqual(result.returncode, 0)

    def test_shell_variable_boundaries(self):
        for script in ROOT.rglob("*.sh"):
            self.assertIsNone(re.search(r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]", script.read_text()), str(script))

    def test_explicit_ipv4_validation(self):
        for address, valid in (("203.0.113.1", True), ("not-an-ip", False), ("::1", False)):
            env = dict(os.environ, VPS_PUBLIC_IP=address)
            result = bash('source "$1"; REPO_ROOT=$2; public_ipv4', ROOT / "lib/deploy.sh", ROOT, env=env)
            self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_upgrade_avoids_unneeded_apt_changes(self):
        result = bash('source "$1"; apt-get() { printf SHOULD_NOT_RUN; return 99; }; install_dependencies upgrade',
                      ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_windows_offline_package_installs_sevenzip(self):
        result = bash('''
source "$1"
CLIENT_PLATFORM=windows
apt-get() { printf '%s\\n' "$*"; }
apt-cache() { return 0; }
command() {
    case "$*" in '-v 7z'|'-v 7zz') return 1 ;; *) builtin command "$@" ;; esac
}
install_dependencies install
''', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("p7zip-full", result.stdout)

    def test_offline_flag_is_accepted_as_compatibility_noop(self):
        # Offline is now the only mode; --upgrade/--verify with --offline must not error.
        for scheme in ("gost", "frp"):
            for args in (("--client", "windows", "--offline"), ("--offline",)):
                result = subprocess.run(["bash", str(ROOT / "install.sh"), scheme, *args, "--help"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL not installed")
    def test_certificate_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            certs = Path(directory) / "certs"
            result = bash('source "$1"; umask 077; generate_certs "$2" 127.0.0.1',
                          ROOT / "lib/deploy.sh", certs)
            self.assertEqual(result.returncode, 0, result.stderr)
            for key in certs.glob("*.key"):
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            # Leaf purposes and the IP SAN are checked by the deployment function.
            wrong_ip = subprocess.run(["openssl", "verify", "-CAfile", str(certs / "ca.crt"),
                                       "-verify_ip", "203.0.113.1", str(certs / "server.crt")], capture_output=True)
            self.assertNotEqual(wrong_ip.returncode, 0)
            wrong_purpose = subprocess.run(["openssl", "verify", "-CAfile", str(certs / "ca.crt"),
                                            "-purpose", "sslserver", str(certs / "client.crt")], capture_output=True)
            self.assertNotEqual(wrong_purpose.returncode, 0)

    def test_server_rendering(self):
        result = bash('source "$1"; render_frps_server /etc/frp token', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("wireProtocol", result.stdout)
        self.assertIn('proxyBindAddr = "127.0.0.1"', result.stdout)
        self.assertIn('allowPorts = [{ single = 10001 }, { single = 33389 }]', result.stdout)
        self.assertIn("transport.tls.force = true", result.stdout)
        result = bash('source "$1"; render_gost_server /etc/gost relay password', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("type: mtls", result.stdout)
        self.assertIn("bind: true", result.stdout)
        self.assertIn('caFile: "/etc/gost/certs/ca.crt"', result.stdout)

    def test_release_download_failure_propagates(self):
        # Even command substitution must not hide a failed HTTP transfer.
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "already-valid.json"
            metadata.write_text('{"tag_name":"v3.3.2"}')
            result = bash('source "$1"; REPO_ROOT=$2; https_get() { return 22; }; '
                          'tag=$(release_info go-gost/gost latest "$3"); printf SHOULD_NOT_RUN',
                          ROOT / "lib/deploy.sh", ROOT, metadata)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_asset_transfer_or_hash_failure_never_continues(self):
        for failure in ("http", "hash"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                metadata = release_fixture(root, "gost", "v3.3.2")
                result = bash('''
source "$1"
REPO_ROOT=$2
FAILURE=$5
https_get() {
    [ "$FAILURE" != http ] || return 22
    printf 'corrupt fixture' > "$2"
}
download_asset "$3" go-gost/gost gost_3.3.2_windows_amd64.zip "$4"
printf SHOULD_NOT_RUN
''', ROOT / "lib/deploy.sh", ROOT, metadata, root / "download.zip", failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
                if failure == "hash":
                    self.assertIn("SHA-256 mismatch", result.stderr)

    def test_remote_bootstrap_http_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "install.sh").write_bytes((ROOT / "install.sh").read_bytes())
            mock = root / "bin"
            mock.mkdir()
            for name, body in {"uname": "printf Linux", "id": "printf 0", "curl": "exit 22",
                               "apt-get": "exit 99"}.items():
                target = mock / name
                target.write_text("#!/bin/sh\n" + body + "\n")
                target.chmod(0o755)
            env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"])
            env.pop("REPO_COMMIT", None)
            result = subprocess.run(["bash", str(root / "install.sh"), "gost"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 22, result.stderr)
            self.assertNotIn("部署已", result.stdout)

    def test_no_global_network_or_http_mutation(self):
        deployment = (ROOT / "lib/deploy.sh").read_text()
        for forbidden in ("http.server", "disable_ipv6", "sysctl", "ghproxy", "bash <(curl"):
            self.assertNotIn(forbidden, deployment)
        self.assertNotIn("bash <(curl", (ROOT / "install.sh").read_text())

    def test_temp_download_account_contract_and_fallback(self):
        text = (ROOT / "lib/deploy.sh").read_text()
        for required in ("create_temp_download_account()", "useradd -m -g pkgdl -s /bin/bash",
                         "usermod -e ", "chpasswd", "pkg-dl-", "userdel -r", "userdel -r %s",
                         # Download-only restriction: dedicated group + sshd Match + ForceCommand wrapper.
                         "render_pkg_dl_wrapper()", "install_pkg_dl_restriction()",
                         "Match Group pkgdl", "ForceCommand $wrapper_dest",
                         "SSHD_CONFIG_PATH:-/etc/ssh/sshd_config",
                         "PKG_DL_WRAPPER_PATH:-/usr/local/sbin/pkg-dl-command",
                         "PermitTTY no", "AllowTcpForwarding no", "sshd -t",
                         "无法安装 SSH 下载专用限制",
                         # Persistent cleanup timer (survives reboot) + robust revocation.
                         "pkg-dl-cleanup@.timer", "OnActiveSec=25h", "loginctl terminate-user",
                         "usermod -L",
                         # Numbered steps: paste command, yes prompt, password, hash.
                         "第 1 步 · 在 Windows 住宅机打开 PowerShell",
                         r'Get-FileHash "$env:USERPROFILE\\Downloads\\%s" -Algorithm SHA256',
                         "第 1 步 · 在 Mac 住宅机打开终端",
                         "shasum -a 256 ~/Downloads/%s", "sha256sum \"/root/$package\"",
                         "第 2 步 · 首次连接询问 yes/no 时输入 yes",
                         "第 3 步 · 出现 Password: 提示时", "密码：%s",
                         "第 4 步 · 核对第 1 步命令末尾输出的 SHA-256",
                         "sftp://%s:%s@%s/%s", "勿用浏览器打开", "手动填表用地址：sftp://%s@%s/%s",
                         # Account name is recorded so verification can revoke it later.
                         "printf 'DOWNLOAD_USER=%s\\n' \"$user\" >> \"$CONFIG_DIR/client-verify.env\"",
                         # Revocation: called only after full PASS, strict name check, /root copy kept.
                         "revoke_temp_download_account()", "^pkg[a-f0-9]{6}$",
                         "配置包仍保留在 /root/ 下"):
            self.assertIn(required, text)
        # Platform-specific paste lines are gated on the chosen client platform.
        self.assertIn('if [ "$CLIENT_PLATFORM" != mac ]; then', text)
        # The SSH restriction must be in place before the account itself is created.
        self.assertLess(text.index('if ! install_pkg_dl_restriction; then'),
                        text.index('useradd -m -g pkgdl -s /bin/bash'))
        # The account is created only after the package is placed under /root.
        self.assertLess(text.index('install -m 600 "$WORK_DIR/$package" "/root/$package"'),
                        text.index('create_temp_download_account "$package"'))
        # Revocation runs inside verify_residential after the PASS banner.
        self.assertLess(text.index('全部通过：VPS 回环'), text.index('    revoke_temp_download_account'))
        # Revocation kills sessions before userdel (a lingering process blocks userdel -r).
        revoke_at = text.index('revoke_temp_download_account()')
        self.assertLess(text.index('loginctl terminate-user "$user"', revoke_at),
                        text.index('userdel -r "$user"', revoke_at))
        # Unsupported (non-root / non-Linux) environments fall back to guidance
        # instead of attempting account creation.
        result = bash('''
source "$1"
PUBLIC_IP=203.0.113.1
create_temp_download_account client.zip
''', ROOT / "lib/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("未创建临时下载账号", result.stdout)
        self.assertNotIn("临时密码", result.stdout)

    def test_pkg_dl_wrapper_whitelists_sftp_and_package_scp_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home" / "pkg1a2b3c"
            home.mkdir(parents=True)
            (home / "windows_gost_v3_pkg.zip").write_text("package fixture")
            mock = root / "bin"
            mock.mkdir()
            record = root / "record.txt"
            (mock / "scp").write_text('#!/bin/sh\necho "scp $*" >> "$RECORD"\n')
            sftp = mock / "sftp-server"
            sftp.write_text('#!/bin/sh\necho "sftp-server $*" >> "$RECORD"\n')
            for stub in mock.iterdir():
                stub.chmod(0o755)
            wrapper = root / "pkg-dl-command"
            bash('source "$1"\nrender_pkg_dl_wrapper "$2" > "$3"',
                 ROOT / "lib/deploy.sh", sftp, wrapper)
            wrapper.chmod(0o755)
            allowed = {"sftp": "sftp-server -R",
                       str(sftp): "sftp-server -R",  # subsystem cmd string (session.c passes Subsystem value)
                       str(sftp) + " ": "sftp-server -R",  # sshd >=9.6 assembles subsystem_args as "%s %s" -> trailing space
                       "internal-sftp": "sftp-server -R",
                       "scp -f windows_gost_v3_pkg.zip": "scp -f ",  # legacy scp sends a relative path
                       f"scp -f {home}/windows_gost_v3_pkg.zip": "scp -f ",
                       f"scp -f -d {home}/windows_gost_v3_pkg.zip": "scp -f ",
                       f"scp -f {home}/windows_gost_v3_pkg.zip ": "scp -f "}  # trailing space is split away
            denied = ["", "bash", f"scp -t {home}/windows_gost_v3_pkg.zip",
                      "scp -f /etc/passwd", f"scp -f {home}/../root/x",
                      f"scp -f {home}/.ssh/id", f"scp -f {home}/pkg.zip; id",
                      "scp -f *", "scp -f wind*",  # glob must not expand (set -f)
                      "cat /etc/passwd"]
            env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"],
                       HOME=str(home), RECORD=str(record))
            for command, expected in allowed.items():
                with self.subTest(allow=command):
                    result = subprocess.run(["sh", str(wrapper)], capture_output=True, text=True,
                                            env=dict(env, SSH_ORIGINAL_COMMAND=command))
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(expected, record.read_text())
            for command in denied:
                with self.subTest(deny=command):
                    result = subprocess.run(["sh", str(wrapper)], capture_output=True, text=True,
                                            env=dict(env, SSH_ORIGINAL_COMMAND=command))
                    self.assertNotEqual(result.returncode, 0, command)
                    self.assertIn("仅允许下载配置包", result.stderr)

    def test_install_pkg_dl_restriction_appends_and_rolls_back(self):
        script = '''
source "$1"
WORK_DIR="$2"
export SSHD_CONFIG_PATH="$3"
export PKG_DL_WRAPPER_PATH="$4"
install_pkg_dl_restriction && echo "RC=0" || echo "RC=1"
'''
        for mode in ("happy", "invalid_after_append", "reload_fails", "no_sshd"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                work = root / "work"
                work.mkdir()
                sshd_config = root / "sshd_config"
                original = "Port 22\nSubsystem sftp /usr/lib/openssh/sftp-server\n"
                sshd_config.write_text(original)
                wrapper = root / "pkg-dl-command"
                mock = root / "bin"
                mock.mkdir()
                # sshd -T prints the subsystem line (>=9.6 assembles it as "%s %s",
                # so with no extra args it ends with a space — mimic that); -t
                # rejects the config once our Match block is present, but only when
                # FAIL_WITH_MATCH asks for it (simulating sshd -t validation failure
                # in invalid_after_append).
                (mock / "sshd").write_text(
                    '#!/bin/sh\n'
                    '[ "$1" = -T ] && printf "subsystem sftp /bin/sh \\n" && exit 0\n'
                    'if [ "$1" = -t ] && [ "$FAIL_WITH_MATCH" = 1 ] && '
                    'grep -q "Match Group pkgdl" "$SSHD_CONFIG_PATH"; then exit 1; fi\n'
                    'exit 0\n')
                (mock / "getent").write_text('#!/bin/sh\nexit 1\n')
                (mock / "groupadd").write_text('#!/bin/sh\nexit 0\n')
                (mock / "systemctl").write_text(
                    '#!/bin/sh\ncase "$*" in reload*) exit %s;; esac\nexit 0\n'
                    % ("1" if mode == "reload_fails" else "0"))
                stubs = ["getent", "groupadd", "systemctl"] + ([] if mode == "no_sshd" else ["sshd"])
                for name in stubs:
                    (mock / name).chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"],
                           FAIL_WITH_MATCH="1" if mode == "invalid_after_append" else "0")
                result = bash(script, ROOT / "lib/deploy.sh", work, sshd_config, wrapper, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                config_now = sshd_config.read_text()
                if mode == "happy":
                    self.assertIn("RC=0", result.stdout)
                    self.assertTrue(wrapper.is_file())
                    self.assertTrue(wrapper.read_text().startswith("#!/bin/sh"))
                    # trailing space stripped before the executable gate
                    self.assertIn("SFTP_BIN=/bin/sh\n", wrapper.read_text())
                    self.assertIn("Match Group pkgdl", config_now)
                    self.assertIn("ForceCommand %s" % wrapper, config_now)
                    self.assertIn("PermitTTY no", config_now)
                    self.assertTrue(config_now.startswith("Port 22"))
                    self.assertTrue((work / "sshd_config.backup").is_file())
                else:
                    self.assertIn("RC=1", result.stdout)
                    # Failure paths restore the original config and remove the wrapper.
                    self.assertEqual(config_now, original)
                    self.assertFalse(wrapper.exists())

    def test_revoke_temp_download_account_after_verify_pass(self):
        script = '''
source "$1"
CONFIG_DIR="$2"
revoke_temp_download_account
'''
        for mode, id_body in (("existing", "exit 0"), ("gone", "exit 1")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = root / "etc"
                config.mkdir()
                (config / "client-verify.env").write_text(
                    "GOST_USER=user_test\nGOST_PASS=pass_test\nCLIENT_PLATFORM=windows\n"
                    "DOWNLOAD_USER=pkg1a2b3c\n")
                mock = root / "bin"
                mock.mkdir()
                record = root / "record.txt"
                (mock / "id").write_text("#!/bin/sh\n" + id_body + "\n")
                for name in ("userdel", "loginctl", "systemctl", "usermod"):
                    (mock / name).write_text('#!/bin/sh\necho "%s $*" >> "$RECORD"\n' % name)
                for stub in mock.iterdir():
                    stub.chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"],
                           RECORD=str(record))
                result = bash(script, ROOT / "lib/deploy.sh", config, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("CLEAN", result.stdout)
                # DOWNLOAD_USER is consumed; SOCKS credentials survive for future --verify runs.
                self.assertNotIn("DOWNLOAD_USER", (config / "client-verify.env").read_text())
                self.assertIn("GOST_USER=user_test", (config / "client-verify.env").read_text())
                # The persistent cleanup timer is disabled for this account.
                self.assertIn("systemctl disable --now pkg-dl-cleanup@pkg1a2b3c.timer", record.read_text())
                if mode == "existing":
                    log = record.read_text()
                    self.assertIn("-r pkg1a2b3c", log)
                    # Sessions are terminated BEFORE userdel (-r refuses while processes live).
                    self.assertLess(log.index("loginctl terminate-user"), log.index("userdel -r"))
                    self.assertIn("已删除临时下载账号 pkg1a2b3c", result.stdout)
                else:
                    self.assertIn("已不存在", result.stdout)

    def test_verify_residential_uses_local_probes_and_rejects_bad_state(self):
        script = '''
source "$1"
verify_residential gost windows user_test pass_test 203.0.113.1 0
printf 'SCRIPT_COMPLETED'
'''
        for mode, expect_rc, expected in (("healthy", 0, ["SCRIPT_COMPLETED", "PASS 匿名 SOCKS5 被拒绝",
                                                          "PASS 错误密码被拒绝", "198.51.100.7",
                                                          "PASS 正确凭据经住宅出口访问成功",
                                                          "配置包仍保留在 /root/ 下"]),
                                          ("public_bind", 1, ["FAIL SOCKS 映射监听地址异常：0.0.0.0:10001"]),
                                          ("open_proxy", 1, ["FAIL 匿名 SOCKS5 请求未被拒绝"])):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                mock = root / "bin"
                mock.mkdir()
                bind = "0.0.0.0" if mode == "public_bind" else "127.0.0.1"
                (mock / "ss").write_text(
                    '#!/bin/sh\ncase "$*" in\n*10001*) printf "LISTEN 0 0 %s:10001 0.0.0.0:*\\n" "$BIND" ;;\n'
                    '*33389*) printf "LISTEN 0 0 %s:33389 0.0.0.0:*\\n" "$BIND" ;;\nesac\n')
                # Healthy proxy: only the exact credentials succeed; open_proxy accepts everyone.
                (mock / "curl").write_text(
                    '#!/bin/sh\ncase " $* " in *" user_test:pass_test "*) printf "198.51.100.7\\n"; exit 0;; esac\n'
                    '[ "$OPEN_PROXY" = 1 ] || exit 7\nprintf "198.51.100.7\\n"\n')
                for stub in mock.iterdir():
                    stub.chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"],
                           BIND=bind, OPEN_PROXY="1" if mode == "open_proxy" else "")
                result = bash(script, ROOT / "lib/deploy.sh", env=env)
                self.assertEqual(result.returncode, expect_rc, result.stdout + result.stderr)
                for fragment in expected:
                    self.assertIn(fragment, result.stdout)

    def test_verify_flag_contract(self):
        text = (ROOT / "lib/deploy.sh").read_text()
        for required in ("--verify) action=verify", "client-verify.env", 'verify_residential "$SCHEME"',
                         "VERIFY_TIMEOUT_MIN", "sed -n 's/^GOST_USER=//p'", "--verify 不重新选择住宅机系统",
                         "验证通过将立即删除临时下载账号"):
            self.assertIn(required, text)
        # Credentials are persisted (root-only) before the download account is offered.
        self.assertLess(text.index('chmod 600 "$CONFIG_DIR/client-verify.env"'),
                        text.index('create_temp_download_account "$package"'))
        # First install offers to keep waiting; standalone re-runs are always possible.
        self.assertIn("是否现在等待住宅机安装并自动验证链路", text)
        self.assertIn("--verify", (ROOT / "install.sh").read_text())

    @unittest.skipUnless(shutil.which("zip") and shutil.which("unzip"), "zip/unzip not installed")
    def test_windows_offline_package_uses_pinned_templates_without_server_keys(self):
        for scheme in ("gost", "frp"):
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                work = root / "work"
                work.mkdir()
                certs = root / "certs"
                certs.mkdir()
                for name in ("ca.crt", "client.crt", "client.key", "ca.key", "server.key"):
                    (certs / name).write_text("test fixture, not a real key")
                gost = release_fixture(root, "gost", "v3.3.2")
                release_fixture(root, "servy", "v10.7")
                frp = release_fixture(root, "frpc", "v0.71.1")
                shutil.copyfile(gost if scheme == "gost" else frp, work / "core-release.json")
                tag = "v3.3.2" if scheme == "gost" else "v0.71.1"
                template = ROOT / ("01_Pure_GOST_v3/windows_client_gost_v3" if scheme == "gost"
                                   else "02_FRP_GOST/windows_client_frp_gost")
                mock = root / "bin"
                mock.mkdir()
                sevenzip = mock / "7z"
                sevenzip.write_text('''#!/bin/bash
set -euo pipefail
directory=${3#-o}
mkdir -p "$directory/runtime"
for file in servy-cli.exe Servy.exe Servy.Service.CLI.exe; do
    printf 'fixture' > "$directory/runtime/$file"
done
''')
                sevenzip.chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ["PATH"])
                env.pop("PACKAGE_MODE", None)
                result = bash('''
source "$1"
REPO_ROOT=$2
WORK_DIR=$3/work
FIXTURES=$3
SCHEME=$4
CORE_TAG=$5
PUBLIC_IP=203.0.113.1
AUTH_TOKEN=token_test
RELAY_USER=relay_test
RELAY_PASS=relay_secret
GOST_USER=user_test
GOST_PASS=socks_secret
release_info() {
    local fixture=servy-release.json
    [ "$1" != go-gost/gost ] || fixture=gost-release.json
    cp "$FIXTURES/$fixture" "$3"
    python3 -I "$REPO_ROOT/lib/release.py" tag "$3"
}
download_asset() {
    printf '%s\\n' "$3" >> "$WORK_DIR/downloads"
    printf fixture > "$4"
}
extract_asset() {
    mkdir "$2"
    if [[ "$1" = *frpc.zip ]]; then printf fixture > "$2/frpc.exe";
    else printf fixture > "$2/gost.exe"; fi
}
build_windows_package "$6" client.zip "$3/certs"
''', ROOT / "lib/deploy.sh", ROOT, root, scheme, tag, template, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((work / "downloads").exists())
                with zipfile.ZipFile(work / "client.zip") as archive:
                    names = archive.namelist()
                    self.assertIn("client.key", names)
                    self.assertIn("windows_components.ps1", names)
                    self.assertIn("diagnose_windows.ps1", names)
                    self.assertFalse(any(name.endswith(".bat") for name in names))
                    self.assertNotIn("ca.key", names)
                    self.assertNotIn("server.key", names)
                    manifest = json.loads(archive.read("components.json"))
                    self.assertEqual(manifest["mode"], "offline")
                    self.assertEqual(manifest["scheme"], scheme)
                    self.assertEqual(manifest["tunnelVersion"], tag)
                    self.assertIn("Package mode: offline", archive.read("VERSIONS.txt").decode())
                    self.assertIn("gost.exe", names)
                    self.assertIn("servy/runtime/Servy.Service.CLI.exe", names)
                    if scheme == "frp":
                        self.assertIn("frpc.exe", names)
                    setup_name = "setup_gost_v3.ps1" if scheme == "gost" else "setup_frp_gost.ps1"
                    setup = archive.read(setup_name).decode("utf-8-sig")
                    self.assertIn('$GostUser = "user_test"', setup)
                    self.assertIn('$GostPass = "socks_secret"', setup)
                    self.assertIn("账号：$GostUser", setup)
                    self.assertIn("密码：$GostPass", setup)
                    self.assertIn("[IO.File]::WriteAllText($SocksInfoPath,", setup)
                    # The readable credentials file is created on Windows, not by this package test.
                    self.assertNotIn("SOCKS5账号密码.txt", names)
                    for name in names:
                        if name.endswith(".ps1"):
                            data = archive.read(name)
                            self.assertTrue(data.startswith(b"\xef\xbb\xbf"), name)
                            self.assertNotIn(b"\n", data.replace(b"\r\n", b""), name)
                            self.assertIsNone(re.search(rb"\b[A-Z_]+_PLACEHOLDER\b", data), name)

    def test_packaging_missing_digest_aborts_before_component_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            gost = release_fixture(root, "gost", "v3.3.2")
            release_fixture(root, "servy", "v10.7", digest=None)
            shutil.copyfile(gost, work / "core-release.json")
            certs = root / "certs"
            certs.mkdir()
            for name in ("ca.crt", "client.crt", "client.key"):
                (certs / name).write_text("fixture")
            result = bash('''
source "$1"
REPO_ROOT=$2
WORK_DIR=$3/work
FIXTURES=$3
SCHEME=gost
CORE_TAG=v3.3.2
release_info() { cp "$FIXTURES/servy-release.json" "$3"; printf 'v10.7\\n'; }
download_asset() { printf SHOULD_NOT_DOWNLOAD; exit 97; }
build_windows_package "$REPO_ROOT/01_Pure_GOST_v3/windows_client_gost_v3" client.zip "$FIXTURES/certs"
printf SHOULD_NOT_INSTALL
''', ROOT / "lib/deploy.sh", ROOT, root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 digest missing", result.stderr)
            self.assertNotIn("SHOULD_NOT", result.stdout)
            self.assertFalse((work / "client.zip").exists())

    def test_gost_upgrade_reads_version_not_go_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "gost"
            binary.write_text('#!/bin/bash\nprintf "gost version 3.3.1 (go1.26.3 linux/amd64)\\n"\n')
            binary.chmod(0o755)
            candidate = root / "candidate"
            candidate.write_text('#!/bin/bash\nexit 0\n# new binary\n')
            candidate.chmod(0o755)
            (root / "config.yaml").write_text("services: []")
            (root / "work").mkdir()
            result = bash('''
source "$1"
REPO_ROOT=$2
BINARY=$3/gost
CORE_BINARY=$3/candidate
CONFIG=$3/config.yaml
WORK_DIR=$3/work
SCHEME=gost
SERVICE=gost
CORE_TAG=v3.3.2
UPGRADE_PENDING=0
trap cleanup_deploy EXIT
systemctl() { return 1; }
upgrade_binary
''', ROOT / "lib/deploy.sh", ROOT, root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertIn("new binary", binary.read_text())

    def test_atomic_upgrade_and_rollback(self):
        for mode in ("success", "restart-failure", "health-failure", "inactive", "invalid-config", "same", "downgrade"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "frps"
                candidate = root / "candidate"
                old = '#!/bin/bash\nprintf "0.71.0\\n"\n# old binary\n'
                binary.write_text(old)
                binary.chmod(0o755)
                candidate.write_text('#!/bin/bash\nif [ "$1" = verify ] && [ "$TEST_MODE" = invalid-config ]; then exit 2; fi\nprintf "0.71.1\\n"\n# new binary\n')
                candidate.chmod(0o755)
                (root / "frps.toml").write_text("# existing config\n")
                (root / "work").mkdir()
                env = dict(os.environ, TEST_MODE=mode)
                result = bash('''
source "$1"
REPO_ROOT=$2
BINARY=$3/frps
CORE_BINARY=$3/candidate
CONFIG=$3/frps.toml
WORK_DIR=$3/work
SERVICE=frps
SCHEME=frp
CORE_TAG=v0.71.1
[ "$TEST_MODE" != same ] || CORE_TAG=v0.71.0
[ "$TEST_MODE" != downgrade ] || CORE_TAG=v0.70.0
UPGRADE_PENDING=0
trap cleanup_deploy EXIT
systemctl() {
    case "$1" in
        is-active) [ "$TEST_MODE" != inactive ] ;;
        restart)
            printf restart >> "$TEST_LOG"
            if [ "$TEST_MODE" = restart-failure ] && grep -q 'new binary' "$BINARY"; then return 1; fi ;;
        *) return 1 ;;
    esac
}
# Test-only health check; do not sleep or touch the host service manager.
wait_service() { [ "$TEST_MODE" != health-failure ]; }
export TEST_LOG="$3/restarts"
upgrade_binary
''',
                              ROOT / "lib/deploy.sh", ROOT, root, env=env)
                expected_failure = mode in ("restart-failure", "health-failure", "invalid-config", "downgrade")
                self.assertEqual(result.returncode != 0, expected_failure, result.stdout + result.stderr)
                if not expected_failure:
                    self.assertEqual(result.stderr, "")
                should_replace = mode in ("success", "inactive")
                self.assertEqual("new binary" in binary.read_text(), should_replace)
                self.assertEqual((root / "frps.toml").read_text(), "# existing config\n")
                self.assertFalse(list(root.glob(".frps.*")))
                if mode in ("inactive", "same", "downgrade", "invalid-config"):
                    self.assertFalse((root / "restarts").exists())
                if mode in ("restart-failure", "health-failure"):
                    self.assertEqual((root / "restarts").read_text(), "restartrestart")


class WindowsTemplateTests(unittest.TestCase):
    def test_source_encoding_and_ps1_only_entries(self):
        ps1_files = list(ROOT.glob("*/windows_client*/*.ps1")) + [ROOT / "lib/windows_components.ps1"]
        self.assertEqual(len(ps1_files), 5)
        # PS1 is the sole entry point; batch launchers must not come back.
        self.assertEqual(list(ROOT.glob("*/windows_client*/**/*.bat")), [])
        for script in ps1_files:
            self.assertTrue(script.read_bytes().startswith(b"\xef\xbb\xbf"), str(script))

    def test_pure_gost_listener_chain_and_tls(self):
        text = (ROOT / "01_Pure_GOST_v3/windows_client_gost_v3/setup_gost_v3.ps1").read_text(encoding="utf-8-sig")
        self.assertEqual(len(re.findall(r"listener:\s*\n\s+type: rtcp\s*\n\s+chain: relay-chain", text)), 2)
        self.assertIn('addr: "${VpsServerIp}:9000"', text)
        self.assertNotIn("$VpsServerIp:9000", text)
        for field in ('addr: "127.0.0.1:10001"', 'addr: "127.0.0.1:33389"', "secure: true", 'serverName: "$VpsServerIp"'):
            self.assertIn(field, text)

    def test_frpc_settings(self):
        text = (ROOT / "02_FRP_GOST/windows_client_frp_gost/setup_frp_gost.ps1").read_text(encoding="utf-8-sig")
        self.assertIn('transport.wireProtocol = "v2"', text)
        self.assertIn('transport.tls.serverName = "$VpsServerIp"', text)
        self.assertIn("transport.tcpMux = true", text)
        self.assertEqual(text.count("transport.useEncryption = false"), 2)
        self.assertEqual(text.count("transport.useCompression = false"), 2)

    def test_socks_credentials_record_uses_configured_values(self):
        scripts = list(ROOT.glob("*/windows_client*/setup_*.ps1"))
        self.assertEqual(len(scripts), 2)
        for script in scripts:
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8-sig")
                self.assertIn("$SocksInfoPath = Join-Path $ToolsDir 'SOCKS5账号密码.txt'", text)
                match = re.search(r'\$SocksInfo = @"\n(.*?)\n"@', text, re.DOTALL)
                self.assertIsNotNone(match)
                record = match.group(1)
                self.assertIn("账号：$GostUser", record)
                self.assertIn("密码：$GostPass", record)
                self.assertEqual(re.findall(r"\$[A-Za-z_]\w*", record),
                                 ["$VpsServerIp", "$GostUser", "$GostPass"])
                for value in ("127.0.0.1:10000", "127.0.0.1:10001", "不对公网开放", "明文密码"):
                    self.assertIn(value, record)
                self.assertIn("$GostUserYaml = ConvertTo-Json -InputObject $GostUser -Compress", text)
                self.assertIn("$GostPassYaml = ConvertTo-Json -InputObject $GostPass -Compress", text)
                write_call = ('[IO.File]::WriteAllText($SocksInfoPath, '
                              '($SocksInfo -replace \'\\r?\\n\', "`r`n"), (New-Object Text.UTF8Encoding($true)))')
                self.assertEqual(text.count(write_call), 1)
                self.assertLess(text.index('[IO.File]::WriteAllText("$ToolsDir\\gost.yaml"'),
                                text.index(write_call))
                self.assertLess(text.index(write_call), text.index("Write-Host '[4/5]"))
                self.assertIn('Write-Host "SOCKS5 账号密码已保存：$SocksInfoPath', text)
                self.assertIn("$ErrorActionPreference = 'Stop'", text)

    def test_socks_credentials_location_and_uninstall_warning(self):
        for directory, tools_dir in (("01_Pure_GOST_v3/windows_client_gost_v3", r"C:\Tools\TikTokGostV3"),
                                     ("02_FRP_GOST/windows_client_frp_gost", r"C:\Tools\TikTokFrpGost")):
            with self.subTest(directory=directory):
                client = ROOT / directory
                instructions = (client / "README_住宅机安装说明.txt").read_text()
                self.assertIn(tools_dir + r"\SOCKS5账号密码.txt", instructions)
                self.assertIn("卸载默认保留整个运行目录", instructions)
                uninstall = next(client.glob("uninstall_*.ps1")).read_text(encoding="utf-8-sig")
                prompt = next(line for line in uninstall.splitlines() if "$Confirm = Read-Host" in line)
                self.assertIn("SOCKS5账号密码.txt", prompt)
                self.assertIn("请先备份所需凭据", prompt)
                self.assertIn("(y/N)", prompt)
                self.assertIn("if ($Confirm -ieq 'y')", uninstall)

    def test_component_preparation_precedes_service_mutation(self):
        for script in ROOT.glob("*/windows_client*/setup_*.ps1"):
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8-sig")
                preflight = text.index("Assert-ClientComponentManifest -PackageDir")
                elevation = text.index("-Verb RunAs -Wait -PassThru")
                prepare = text.index("Initialize-ClientComponents -PackageDir")
                ownership_call = text.rindex("Assert-OwnedService")
                self.assertLess(preflight, elevation)
                self.assertLess(elevation, prepare)
                self.assertLess(text.index("$OtherServyServices.Count -gt 0"), prepare)
                self.assertLess(prepare, ownership_call)
                self.assertLess(ownership_call, text.index("Stop-Service"))
                self.assertIn("Initialize-ClientComponents -PackageDir $CurrentDir", text)
                self.assertIn("Join-Path $ComponentRoot 'servy'", text)
                self.assertIn("Join-Path $CurrentDir $Name) -Destination $CertsDir", text)
                # Offline-only: no downloader staging lifecycle remains in the setups.
                self.assertNotIn("$Components", text)
                self.assertNotIn("Remove-ClientComponentStaging", text)

    def test_offline_helper_never_downloads_and_pins_manifest_sources(self):
        text = (ROOT / "lib/windows_components.ps1").read_text(encoding="utf-8-sig")
        for required in ("$Manifest.mode -cne 'offline'",
                         "$Component.url -cne $Url",
                         "$Component.version -cne $Manifest.tunnelVersion",
                         "[version]'3.3.2'", "[version]'0.71.1'", "[version]'10.7.0'",
                         "Assert-ClientComponentSource $PackageDir $Scheme"):
            self.assertIn(required, text)
        for forbidden in ("Invoke-Expression", "Invoke-WebRequest", "HttpWebRequest", "ServicePointManager",
                          "releases/latest", "api.github.com", "Start-Process", "Stop-Service",
                          "tar.exe", "7z.exe", "7zr.exe", "Expand-Archive"):
            self.assertNotIn(forbidden, text)
        body = text[text.index("function Initialize-ClientComponents("):]
        self.assertLess(body.index("Assert-ClientComponentManifest"), body.index("return [IO.Path]::GetFullPath"))

    def test_offline_helper_has_no_staging_lifecycle(self):
        text = (ROOT / "lib/windows_components.ps1").read_text(encoding="utf-8-sig")
        for forbidden in ("New-ClientComponentStaging", "Remove-ClientComponentStaging",
                          "ClientComponentStagingPaths", "Save-ClientAsset", "Get-ClientTarPath",
                          "Expand-ClientZip", "Expand-ClientServy", "Add-ClientArchiveMember"):
            self.assertNotIn(forbidden, text)
        for required in ("$Acl.SetAccessRuleProtection($true, $false)",
                         "function New-ClientPrivateDirectory([string]$Path)",
                         "[IO.Directory]::CreateDirectory($Path, (New-ClientPrivateAcl $true))",
                         "New-ClientPrivateDirectory $Path"):
            self.assertIn(required, text)
        self.assertNotIn("Remove-Item -LiteralPath $Path -Recurse", text)

    def test_windows_safety_guards(self):
        for script in ROOT.glob("*/windows_client*/*.ps1"):
            text = script.read_text(encoding="utf-8-sig")
            for forbidden in ("Add-MpPreference", "Stop-Process", "Invoke-WebRequest", "$P_HS://"):
                self.assertNotIn(forbidden, text, str(script))
            self.assertIn("-Verb RunAs -Wait -PassThru", text)
            self.assertIn("exit $Child.ExitCode", text)
            self.assertIn("Assert-OwnedService", text)
            if script.name.startswith("setup_"):
                self.assertIn("--enableHealth", text)
                self.assertLess(text.index("Stop-Service"), text.index("Copy-Item"))
                self.assertLess(text.index("PLACEHOLDER'"), text.index("-Verb RunAs"))


if __name__ == "__main__":
    unittest.main()
