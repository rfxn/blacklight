"""Idempotent sim-tar builder for the Day-5 demo replay (P37).

Reads the Phase-36 staged exhibits at ``exhibits/fleet-01/host-{1,4,5,7}*``
and packages each into a bl-report-shaped ``.tar.gz`` under
``tests/fixtures/sim/``. The four resulting tarballs feed
``demo/time_compression.py`` (P38), which posts them to the curator's
inbox at sim-day boundaries.

Determinism contract: re-running the builder produces byte-identical
``.tar.gz`` files. Achieved by

  1. fixed gzip header mtime via ``gzip.GzipFile(mtime=...)`` — without
     this, gzip embeds the current time into the header,
  2. fixed tar member mtime/uid/gid/uname/gname/mode on every entry,
  3. deterministic build order (the PLAN list is the canonical order; no
     directory iteration with platform-dependent order),
  4. no implicit directory entries — files are added directly with
     embedded path, sidestepping ``tarfile.TarFile.add()`` recursion
     differences across Python versions.

Usage:

    python tests/fixtures/sim/build_sim_tars.py

Prints one line per tar built. Exit non-zero on missing source exhibit.
"""
from __future__ import annotations

import gzip
import io
import json
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path

# repo root = .../blacklight; this file is .../blacklight/tests/fixtures/sim/build_sim_tars.py
REPO_ROOT = Path(__file__).resolve().parents[3]
EXHIBITS = REPO_ROOT / "exhibits" / "fleet-01"
OUT_DIR = Path(__file__).resolve().parent

# 2025-01-01T00:00:00Z — predates all exhibit content; safe stable epoch.
FIXED_MTIME = 1735689600

# Manifest collected_at must be deterministic too — embed a fixed sim-build
# timestamp distinct from FIXED_MTIME so the manifest reads sensibly.
MANIFEST_COLLECTED_AT = "2026-04-25T00:00:00Z"
TOOL_VERSION = "bl-report 0.2.0-sim"

# path_map mirrors what a real bl-report run produces (see
# tests/fixtures/report-host-2-sample.tar.gz). Hunters rglob under fs/ and
# logs/ so the map is informational, but parse_envelope validates its shape.
PATH_MAP = {
    "fs/var/www/html": "/var/www/html",
    "logs/var/log/apache2": "/var/log/apache2",
}


@dataclass(frozen=True)
class SimSpec:
    host_id: str
    sim_day: int
    src_dir: str          # under EXHIBITS
    php_arcname: str | None  # archive path under fs/, or None for clean-fs hosts
    log_arcname: str         # archive path under logs/
    report_id: str


# Order is canonical; do not sort. Drives both build sequence and the P38
# beat ordering downstream.
PLAN: tuple[SimSpec, ...] = (
    SimSpec(
        host_id="host-4", sim_day=5, src_dir="host-4-polyshell-second",
        php_arcname="fs/var/www/html/pub/media/catalog/product/cache/.bin/a.php",
        log_arcname="logs/var/log/apache2/access.log",
        report_id="rpt-host4-day5",
    ),
    SimSpec(
        host_id="host-7", sim_day=7, src_dir="host-7-polyshell-third",
        php_arcname="fs/var/www/html/pub/media/import/.tmp/a.php",
        log_arcname="logs/var/log/apache2/access.log",
        report_id="rpt-host7-day7",
    ),
    SimSpec(
        host_id="host-1", sim_day=10, src_dir="host-1-anticipatory",
        # host-1 is anticipatory: no on-disk PHP — the access.log alone
        # carries the cred-harvest-probe + 403-block evidence.
        php_arcname=None,
        log_arcname="logs/var/log/apache2/access.log",
        report_id="rpt-host1-day10",
    ),
    SimSpec(
        host_id="host-5", sim_day=14, src_dir="host-5-skimmer",
        php_arcname="fs/var/www/html/pub/media/catalog/product/.cache/skimmer.php",
        log_arcname="logs/var/log/apache2/access.log",
        report_id="rpt-host5-day14",
    ),
)


def _add_file(tf: tarfile.TarFile, arcname: str, data: bytes) -> None:
    ti = tarfile.TarInfo(name=arcname)
    ti.size = len(data)
    ti.mtime = FIXED_MTIME
    ti.uid = 0
    ti.gid = 0
    ti.uname = ""
    ti.gname = ""
    ti.mode = 0o644
    tf.addfile(ti, io.BytesIO(data))


def _resolve_php(src: Path, spec: SimSpec) -> bytes | None:
    if spec.php_arcname is None:
        return None
    php_files = sorted(src.glob("*.php"))
    if len(php_files) != 1:
        raise RuntimeError(
            f"{spec.host_id}: expected exactly 1 .php in {src}, found {len(php_files)}"
        )
    return php_files[0].read_bytes()


def _build_one(spec: SimSpec) -> Path:
    src = EXHIBITS / spec.src_dir
    if not src.is_dir():
        raise FileNotFoundError(f"missing exhibit dir: {src}")
    out = OUT_DIR / f"{spec.host_id}-day{spec.sim_day}.tar.gz"

    manifest = {
        "collected_at": MANIFEST_COLLECTED_AT,
        "host_id": spec.host_id,
        "path_map": PATH_MAP,
        "report_id": spec.report_id,
        "tool_version": TOOL_VERSION,
    }
    manifest_bytes = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")

    php_bytes = _resolve_php(src, spec)
    log_path = src / "access.log"
    if not log_path.is_file():
        raise FileNotFoundError(f"{spec.host_id}: missing access.log at {log_path}")
    log_bytes = log_path.read_bytes()

    buf = io.BytesIO()
    # mtime=FIXED_MTIME on the gzip header is the single most common source
    # of non-determinism here — without it, gzip embeds time.time().
    with gzip.GzipFile(filename="", fileobj=buf, mode="wb", mtime=FIXED_MTIME) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tf:
            _add_file(tf, "manifest.json", manifest_bytes)
            if spec.php_arcname is not None and php_bytes is not None:
                _add_file(tf, spec.php_arcname, php_bytes)
            _add_file(tf, spec.log_arcname, log_bytes)

    out.write_bytes(buf.getvalue())
    return out


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for spec in PLAN:
        path = _build_one(spec)
        print(f"built: {path.name} ({path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
