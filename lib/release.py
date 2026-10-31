#!/usr/bin/env python3
"""Release metadata, archive and template checks; run with python3 -I."""
import argparse
import hashlib
import ipaddress
import json
import re
import shutil
import tarfile
import zipfile
from pathlib import Path, PurePosixPath


def release_asset(metadata, repo, name):
    release = json.loads(Path(metadata).read_text(encoding="utf-8"))
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", tag):
        raise ValueError("Expected a stable release with a numeric version")
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if len(assets) != 1:
        raise ValueError(f"Release must contain exactly one asset named {name}")
    asset = assets[0]
    url = asset.get("browser_download_url", "")
    digest = asset.get("digest", "")
    if url != f"https://github.com/{repo}/releases/download/{tag}/{name}":
        raise ValueError("Asset URL does not belong to the expected upstream release")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Upstream SHA-256 digest missing; refusing an unverified download")
    return url, digest[7:]


def windows_manifest(output, scheme, tunnel_version, gost_metadata, servy_metadata, frp_metadata=None):
    # Offline-only packages: components are embedded after VPS-side verification.
    if scheme not in ("gost", "frp"):
        raise ValueError("Invalid Windows package scheme")
    if (scheme == "frp") != (frp_metadata is not None):
        raise ValueError("FRP metadata is required only for the FRP package")
    components = []
    sources = [("gost", "go-gost/gost", gost_metadata, "gost_{version}_windows_amd64.zip", (3, 3, 2)),
               ("servy", "aelassas/servy", servy_metadata, "servy-{version}-net48-x64-portable.7z", (10, 7, 0))]
    if scheme == "frp":
        sources.append(("frpc", "fatedier/frp", frp_metadata, "frp_{version}_windows_amd64.zip", (0, 71, 1)))
    for component, repo, metadata, pattern, minimum in sources:
        tag = json.loads(Path(metadata).read_text(encoding="utf-8"))["tag_name"]
        if not isinstance(tag, str) or not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", tag):
            raise ValueError("Invalid component release tag")
        # release_asset also rejects draft/prerelease metadata and requires an official URL/digest.
        asset = pattern.format(version=tag.lstrip("v"))
        url, digest = release_asset(metadata, repo, asset)
        parts = tuple(int(part) for part in tag.lstrip("v").split("."))
        if parts + (0,) * (3 - len(parts)) < minimum:
            raise ValueError(f"Unsupported {component} version: {tag}")
        if component == ("gost" if scheme == "gost" else "frpc") and tag != tunnel_version:
            raise ValueError("Windows tunnel client must match the VPS core release")
        components.append({"id": component, "repo": repo, "version": tag, "asset": asset,
                           "url": url, "sha256": digest})
    manifest = {"schemaVersion": 1, "mode": "offline", "scheme": scheme, "architecture": "amd64",
                "tunnelVersion": tunnel_version, "components": components}
    Path(output).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def macos_manifest(output, scheme, tunnel_version, gost_metadata, frp_metadata=None):
    # Offline-only packages: components are embedded after VPS-side verification.
    if scheme not in ("gost", "frp"):
        raise ValueError("Invalid macOS package scheme")
    if (scheme == "frp") != (frp_metadata is not None):
        raise ValueError("FRP metadata is required only for the FRP package")
    sources = [("gost", "go-gost/gost", gost_metadata, "gost", (3, 3, 2))]
    if scheme == "frp":
        sources.append(("frpc", "fatedier/frp", frp_metadata, "frp", (0, 71, 1)))
    components = []
    for component, repo, metadata, prefix, minimum in sources:
        tag = json.loads(Path(metadata).read_text(encoding="utf-8"))["tag_name"]
        if not isinstance(tag, str) or not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", tag):
            raise ValueError("Invalid component release tag")
        parts = tuple(int(part) for part in tag.lstrip("v").split("."))
        if parts + (0,) * (3 - len(parts)) < minimum:
            raise ValueError(f"Unsupported {component} version: {tag}")
        if component == ("gost" if scheme == "gost" else "frpc") and tag != tunnel_version:
            raise ValueError("macOS tunnel client must match the VPS core release")
        for architecture in ("amd64", "arm64"):
            asset = f"{prefix}_{tag.lstrip('v')}_darwin_{architecture}.tar.gz"
            url, digest = release_asset(metadata, repo, asset)
            components.append({"id": component, "architecture": architecture, "repo": repo,
                               "version": tag, "asset": asset, "url": url, "sha256": digest})
    manifest = {"schemaVersion": 1, "platform": "macos", "mode": "offline", "scheme": scheme,
                "architectures": ["amd64", "arm64"], "tunnelVersion": tunnel_version,
                "components": components}
    Path(output).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def verify(filename, expected):
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Invalid SHA-256 digest")
    h = hashlib.sha256()
    with open(filename, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    if h.hexdigest() != expected:
        raise ValueError(f"SHA-256 mismatch: {Path(filename).name}")


def archive_path(destination, name):
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts or "\\" in name or re.match(r"^[A-Za-z]:", name):
        raise ValueError(f"Unsafe archive path: {name}")
    return destination.joinpath(*relative.parts)


def extract(filename, destination):
    root = Path(destination)
    if not root.is_dir() or any(root.iterdir()):
        raise ValueError("Extract into a new, empty directory")
    if zipfile.is_zipfile(filename):
        with zipfile.ZipFile(filename) as archive:
            for member in archive.infolist():
                target = archive_path(root, member.filename)
                mode = member.external_attr >> 16
                if (mode & 0o170000) == 0o120000:
                    raise ValueError("Archive symlinks are not allowed")
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(member) as src, target.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
    else:
        with tarfile.open(filename, "r:gz") as archive:
            for member in archive:
                target = archive_path(root, member.name)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as src, target.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
                else:
                    raise ValueError("Archive links and special files are not allowed")


def inject(directory, values):
    # Templates contain only generated alphanumeric secrets and a validated IPv4.
    allowed = {"VPS_PUBLIC_IP", "TOKEN", "RELAY_USER", "RELAY_PASS", "GOST_USER", "GOST_PASS"}
    replacements = {}
    for item in values:
        key, value = item.split("=", 1)
        if key not in allowed:
            raise ValueError(f"Unknown template value: {key}")
        if key == "VPS_PUBLIC_IP":
            ipaddress.IPv4Address(value)
        elif not re.fullmatch(r"[A-Za-z0-9_]+", value):
            raise ValueError(f"Unsafe template value: {key}")
        replacements[key + "_PLACEHOLDER"] = value
    # macOS scripts remain LF; connection data is never sourced as shell code.
    for filename in [*Path(directory).glob("*.sh"), *Path(directory).glob("*.conf")]:
        text = filename.read_text(encoding="utf-8")
        for key, value in replacements.items():
            text = text.replace(key, value)
        if re.search(r"\b[A-Z_]+_PLACEHOLDER\b", text):
            raise ValueError(f"Unresolved template placeholder in {filename.name}")
        filename.write_text(text.replace("\r\n", "\n"), encoding="utf-8")
    for filename in Path(directory).glob("*.ps1"):
        text = filename.read_text(encoding="utf-8-sig")
        for key, value in replacements.items():
            text = text.replace(key, value)
        if re.search(r"\b[A-Z_]+_PLACEHOLDER\b", text):
            raise ValueError(f"Unresolved template placeholder in {filename.name}")
        # Windows PowerShell 5.1 needs a BOM for Chinese UTF-8 source.
        filename.write_bytes(b"\xef\xbb\xbf" + text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    for filename in Path(directory).glob("*.bat"):
        text = filename.read_text(encoding="utf-8-sig")
        filename.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["asset", "manifest", "macos-manifest", "verify", "extract", "inject", "ipv4", "tag", "compare"])
    parser.add_argument("values", nargs="*")
    args = parser.parse_args()
    if args.action == "asset":
        print("\n".join(release_asset(*args.values)))
    elif args.action == "manifest":
        windows_manifest(*args.values)
    elif args.action == "macos-manifest":
        macos_manifest(*args.values)
    elif args.action == "verify":
        verify(*args.values)
    elif args.action == "extract":
        extract(*args.values)
    elif args.action == "inject":
        inject(args.values[0], args.values[1:])
    elif args.action == "ipv4":
        print(ipaddress.IPv4Address(args.values[0]))
    elif args.action == "tag":
        data = json.loads(Path(args.values[0]).read_text(encoding="utf-8"))
        tag = data["tag_name"]
        if data.get("draft") or data.get("prerelease") or not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", tag):
            raise ValueError("Invalid stable release tag")
        print(tag)
    elif args.action == "compare":
        def version(text):
            if not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", text):
                raise ValueError(f"Invalid version: {text}")
            parts = tuple(int(part) for part in text.lstrip("v").split("."))
            return parts + (0,) * (3 - len(parts))
        current, target = map(version, args.values)
        print((target > current) - (target < current))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
