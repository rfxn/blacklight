"""Operator-triggered synthesizer CLI — Day 4 G4.

Usage: python -m curator.synthesize CASE-2026-0007
Loads case YAML, runs synthesizer (Opus 4.7), publishes manifest. Exit 0 on
success with 'manifest v{N}' on stdout.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

from curator.case_schema import load_case
from curator.manifest import publish
from curator.synthesizer import synthesize

log = logging.getLogger("synthesize-cli")


def _check_preconditions() -> None:
    if os.environ.get("BL_SKIP_LIVE") == "1":
        return
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.stderr.write(
            "ANTHROPIC_API_KEY not set and BL_SKIP_LIVE not set — refusing to proceed\n"
        )
        sys.exit(1)


def _load_case_or_exit(case_id: str, cases_dir: Path):
    p = cases_dir / f"{case_id}.yaml"
    if not p.is_file():
        sys.stderr.write(f"[synthesize] case not found: {p}\n")
        sys.exit(2)
    try:
        return load_case(str(p))
    except Exception as exc:
        sys.stderr.write(f"[synthesize] malformed case {p}: {exc}\n")
        sys.exit(2)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="[%(name)s] %(message)s")
    parser = argparse.ArgumentParser(prog="curator.synthesize")
    parser.add_argument("case_id", help="Case ID, e.g. CASE-2026-0007")
    args = parser.parse_args()

    _check_preconditions()

    storage = Path(os.environ.get("BL_STORAGE", "curator/storage"))
    cases_dir = storage / "cases"
    case = _load_case_or_exit(args.case_id, cases_dir)

    cap = case.capability_map
    log.info("capability_map: observed=%d, inferred=%d, likely_next=%d",
             len(cap.observed), len(cap.inferred), len(cap.likely_next))
    if not cap.observed and not cap.inferred:
        log.info("capability_map empty; publishing 0-rule manifest")

    log.info("invoking synthesizer (Opus 4.7)...")
    result = synthesize(cap, case)
    log.info("synthesizer returned %d rules, %d suggested, %d exceptions",
             len(result.rules), len(result.suggested_rules), len(result.exceptions))

    log.info("publishing manifest...")
    new_version = publish(result, storage_dir=storage)
    print(f"manifest v{new_version}")


if __name__ == "__main__":
    main()
