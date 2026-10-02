"""Shared helpers for assembling UnRaid plugin artifacts."""

from __future__ import annotations

import base64
import io
import json
import tarfile
from pathlib import Path

# unraid/common/assemble_lib.py -> repository root
REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_PIN_FILE = "versions.env"


def read_version_pins(pin_file: Path) -> dict[str, str]:
    """Parse `KEY=value` lines out of a versions.env-style pin file.

    Blank lines, comment lines and trailing `# renovate: ...` annotations are
    ignored, so the value is whatever sits between `=` and the first `#`.
    """
    pins: dict[str, str] = {}
    for line in pin_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, rest = line.partition("=")
        value = rest.split("#", 1)[0].strip()
        if value:
            pins[key.strip()] = value
    return pins


def resolve_version_pins(pin_cfg: dict) -> dict[str, str]:
    """Resolve a manifest `version_pins` block to placeholder -> value.

    Manifest shape:
        "version_pins": {
          "file": "versions.env",                       # optional, repo-relative
          "pins": {"__KOMODO_VERSION__": "KOMODO_VERSION"}
        }
    """
    pin_file = REPO_ROOT / pin_cfg.get("file", DEFAULT_PIN_FILE)
    if not pin_file.exists():
        raise FileNotFoundError(f"Version pin file not found: {pin_file}")

    pins = read_version_pins(pin_file)
    resolved: dict[str, str] = {}
    for placeholder, var_name in pin_cfg.get("pins", {}).items():
        if var_name not in pins:
            raise ValueError(f"No pin for {var_name} in {pin_file}")
        resolved[placeholder] = pins[var_name]
    return resolved


def apply_replacements(text: str, replacements: dict[str, str], where: str) -> str:
    """Replace every placeholder, then verify none survived."""
    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)
    leftover = sorted(p for p in replacements if p in text)
    if leftover:
        raise ValueError(f"Unresolved placeholder(s) in {where}: {', '.join(leftover)}")
    return text


def build_txz(
    *,
    src: Path,
    version: str,
    out_dir: Path,
    package_name: str,
    files: list[tuple[str, str, int, bool]],
    slack_desc: str,
    replacements: dict[str, str] | None = None,
) -> Path:
    """Build a Slackware-compatible .txz package from source files.

    Each entry in `files` is (src_name, arc_path, mode, substitute). Files
    flagged for substitution get `replacements` applied to their text; every
    other file is packed byte for byte.
    """
    txz_name = f"{package_name}-{version}-x86_64-1.txz"
    txz_path = out_dir / txz_name

    dirs_needed: set[str] = set()
    for _, arc_path, _, _ in files:
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

        for src_name, arc_path, mode, substitute in files:
            src_file = src / src_name
            if substitute and replacements:
                data = apply_replacements(
                    src_file.read_text(encoding="utf-8"), replacements, arc_path
                ).encode()
            else:
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
      - version_pins (optional): dict of __PLACEHOLDER__ -> variable name in the
        repo-root versions.env (see resolve_version_pins)
      - txz (optional): dict with name, placeholder, slack_desc, files[]

    Each txz.files entry: {src, dest, mode, substitute?} where mode is an octal
    string like "0755" and substitute opts the file into placeholder expansion
    (txz members are otherwise packed verbatim).

    Constants and version pins are applied last, so they resolve inside inlined
    file content as well as in the template itself.
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

    # Upstream version pins (single source of truth: repo-root versions.env)
    pin_cfg = manifest.get("version_pins")
    pin_values = resolve_version_pins(pin_cfg) if pin_cfg else {}
    for placeholder, value in pin_values.items():
        print(f"Version pin: {placeholder} = {value}")

    # Optional: build txz and embed as base64
    txz_cfg = manifest.get("txz")
    if txz_cfg:
        src_dir = plugin_dir / Path(manifest["template"]).parent
        files = [
            (f["src"], f["dest"], int(f["mode"], 8), bool(f.get("substitute", False)))
            for f in txz_cfg["files"]
        ]
        txz_path = build_txz(
            src=src_dir,
            version=version,
            out_dir=out_file.parent or Path("."),
            package_name=txz_cfg["name"],
            files=files,
            slack_desc=txz_cfg["slack_desc"],
            replacements=pin_values,
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

    # __VERSION__ may also appear inside inlined file content, not just the template
    content = content.replace("__VERSION__", version)

    # Literal constants (plugin URL, support URL, ...)
    for placeholder, value in manifest.get("constants", {}).items():
        content = content.replace(placeholder, str(value))

    # Version pins resolve last, inside inlined file content as well
    content = apply_replacements(content, pin_values, out_file.name)

    leftover = sorted({m for m in ("__PLUGIN_URL__", "__SUPPORT_URL__") if m in content})
    if leftover:
        raise ValueError(f"Unresolved placeholder(s) in {out_file.name}: {', '.join(leftover)}")

    out_file.write_text(content, encoding="utf-8")
    print(f"Assembled: {out_file} (plugin version {version})")
