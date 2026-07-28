"""Shared helpers for assembling UnRaid plugin artifacts."""

from __future__ import annotations

import base64
import io
import json
import tarfile
from pathlib import Path


def build_txz(
    *,
    src: Path,
    version: str,
    out_dir: Path,
    package_name: str,
    files: list[tuple[str, str, int]],
    slack_desc: str,
) -> Path:
    """Build a Slackware-compatible .txz package from source files."""
    txz_name = f"{package_name}-{version}-x86_64-1.txz"
    txz_path = out_dir / txz_name

    dirs_needed: set[str] = set()
    for _, arc_path, _ in files:
        parts = arc_path.split("/")
        for i in range(1, len(parts)):
            dirs_needed.add("/".join(parts[:i]))

    with tarfile.open(str(txz_path), "w:xz") as tar:
        for directory in sorted(dirs_needed):
            info = tarfile.TarInfo(name=directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info)

        for src_name, arc_path, mode in files:
            src_file = src / src_name
            data = src_file.read_bytes()
            info = tarfile.TarInfo(name=arc_path)
            info.size = len(data)
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info, io.BytesIO(data))

        desc = slack_desc.encode()
        info = tarfile.TarInfo(name="install/slack-desc")
        info.size = len(desc)
        info.mode = 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        tar.addfile(info, io.BytesIO(desc))

    return txz_path


def assemble_plg(plugin_dir: Path, version: str, output: str | None = None) -> None:
    """Assemble a .plg from a manifest.json in the given plugin directory.

    The manifest.json must contain:
      - template: path to .plg.template (relative to plugin_dir)
      - output:   output filename (default)
      - substitutions: dict of __PLACEHOLDER__ -> source filename (relative to plugin_dir)
      - constants (optional): dict of __PLACEHOLDER__ -> literal string
      - txz (optional): dict with name, placeholder, slack_desc, files[]

    Each txz.files entry: {src, dest, mode} where mode is an octal string like "0755".

    Constants are applied last, so they resolve inside inlined file content as
    well as in the template itself.
    """
    manifest_path = plugin_dir / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"manifest.json not found in {plugin_dir}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    template_path = plugin_dir / manifest["template"]
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")

    out_file = Path(output) if output else plugin_dir / manifest["output"]
    content = template_path.read_text(encoding="utf-8")
    content = content.replace("__VERSION__", version)

    # Optional: build txz and embed as base64
    txz_cfg = manifest.get("txz")
    if txz_cfg:
        src_dir = plugin_dir / Path(manifest["template"]).parent
        files = [(f["src"], f["dest"], int(f["mode"], 8)) for f in txz_cfg["files"]]
        txz_path = build_txz(
            src=src_dir,
            version=version,
            out_dir=out_file.parent or Path("."),
            package_name=txz_cfg["name"],
            files=files,
            slack_desc=txz_cfg["slack_desc"],
        )
        txz_b64 = base64.b64encode(txz_path.read_bytes()).decode()
        txz_path.unlink()
        content = content.replace(txz_cfg["placeholder"], txz_b64)
        print(f"Embedded txz: {len(txz_b64)} bytes base64")

    # Inline substitutions
    for placeholder, filename in manifest.get("substitutions", {}).items():
        filepath = plugin_dir / filename
        if not filepath.exists():
            raise FileNotFoundError(f"Source file not found: {filepath}")
        content = content.replace(placeholder, filepath.read_text(encoding="utf-8").rstrip("\n"))

    # Literal constants (plugin URL, support URL, ...)
    for placeholder, value in manifest.get("constants", {}).items():
        content = content.replace(placeholder, str(value))

    leftover = sorted({m for m in ("__PLUGIN_URL__", "__SUPPORT_URL__") if m in content})
    if leftover:
        raise ValueError(f"Unresolved placeholder(s) in {out_file.name}: {', '.join(leftover)}")

    out_file.write_text(content, encoding="utf-8")
    print(f"Assembled: {out_file} (plugin version {version})")
