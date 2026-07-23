#!/usr/bin/env python3
"""Check whether R2/local Talos image catalog is complete (fast-path gate).

Exit codes:
  0 — always (even when not ready); readiness is in outputs / stdout JSON
  2 — usage / hard failure reading inputs

Examples:
  python3 scripts/check-talos-image-catalog.py \\
    --accounts-yaml tofu/shared/accounts.yaml \\
    --catalog-yaml /tmp/talos-images.yaml \\
    --schematic tofu/shared/schematics/cluster.yaml \\
    --talos-version v1.13.6 \\
    --github-output

  # emit only ready=true|false on stdout
  python3 scripts/check-talos-image-catalog.py ... --quiet
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from talos_image_catalog import evaluate_paths  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--accounts-yaml", type=Path, required=True)
    p.add_argument("--catalog-yaml", type=Path, required=True)
    p.add_argument("--schematic", type=Path, required=True)
    p.add_argument("--talos-version", type=str, required=True)
    p.add_argument("--force", action="store_true")
    p.add_argument(
        "--github-output",
        action="store_true",
        help="Append ready/need_images/reason lines to $GITHUB_OUTPUT",
    )
    p.add_argument(
        "--quiet",
        action="store_true",
        help="Print only ready=true|false",
    )
    p.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="Print full report as JSON",
    )
    args = p.parse_args()

    if not args.accounts_yaml.is_file():
        print(f"::error::accounts yaml not found: {args.accounts_yaml}", file=sys.stderr)
        return 2
    if not args.schematic.is_file():
        print(f"::error::schematic not found: {args.schematic}", file=sys.stderr)
        return 2

    try:
        report = evaluate_paths(
            accounts_yaml=args.accounts_yaml,
            catalog_yaml=args.catalog_yaml,
            schematic_path=args.schematic,
            talos_version=args.talos_version,
            force=args.force,
        )
    except Exception as e:
        print(f"::error::catalog check failed: {e}", file=sys.stderr)
        return 2

    ready = bool(report["ready"])
    need_images = not ready
    reasons = report.get("reasons") or []
    reason = "; ".join(reasons) if reasons else "catalog complete"

    if args.github_output:
        out = os.environ.get("GITHUB_OUTPUT")
        if not out:
            print("::error::GITHUB_OUTPUT not set", file=sys.stderr)
            return 2
        with open(out, "a") as f:
            f.write(f"ready={'true' if ready else 'false'}\n")
            f.write(f"need_images={'true' if need_images else 'false'}\n")
            f.write(f"schematic_match={'true' if report.get('schematic_match') else 'false'}\n")
            f.write(f"expected_schematic_id={report.get('expected_schematic_id', '')}\n")
            f.write(f"stored_schematic_id={report.get('stored_schematic_id', '')}\n")
            # Single-line reason for notices (no newlines).
            safe = reason.replace("\n", " ").replace("\r", " ")
            f.write(f"reason={safe}\n")
            f.write(
                "missing_gcp="
                + ",".join(report.get("missing_gcp") or [])
                + "\n"
            )
            f.write(
                "missing_oracle="
                + ",".join(report.get("missing_oracle") or [])
                + "\n"
            )

    if args.quiet:
        print(f"ready={'true' if ready else 'false'}")
    elif args.as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        status = "READY (skip image sync)" if ready else "NOT READY (run image sync)"
        print(f"::notice::talos image catalog: {status}")
        print(f"::notice::reason: {reason}")
        if report.get("missing_gcp"):
            print(f"::notice::missing_gcp: {','.join(report['missing_gcp'])}")
        if report.get("missing_oracle"):
            print(f"::notice::missing_oracle: {','.join(report['missing_oracle'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
