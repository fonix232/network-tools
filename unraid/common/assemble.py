#!/usr/bin/env python3
"""
Generic UnRaid plugin assembler.

Reads manifest.json from the plugin directory and assembles a .plg file.
Works for all plugins — inline CDATA, embedded txz, or both.

Usage:
    python3 ../common/assemble.py --version 2026.05.17
    python3 ../common/assemble.py --version 2026.05.17 --plugin-dir ../gnupg2
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from common.assemble_lib import assemble_plg


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Plugin version (e.g. 2026.05.17)")
    parser.add_argument("--plugin-dir", default=".", help="Plugin directory containing manifest.json")
    parser.add_argument("--output", default=None, help="Output .plg path (overrides manifest)")
    args = parser.parse_args()

    plugin_dir = Path(args.plugin_dir).resolve()
    try:
        assemble_plg(plugin_dir, args.version, args.output)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
