"""Validate the OSRM health-area travel-time/distance part files.

The health-area product deliberately sits outside the repo's `.matrix.csv`
contract (94.5M pairs, written as gzipped long-format parts under
`processed/health_areas/`), so `tools.qa` skips it. This is its checker.

It verifies, in order:

1.  **Manifest** — 9720 rows, unique non-empty `grid3id`, coordinates in DRC.
2.  **Part coverage** — one part per block of origins, ranges contiguous and
    covering every manifest row exactly once, no leftover `.tmp` files.
3.  **Structure** — per part: row count, origin ids equal to that block's
    manifest slice, destination ids equal to the whole manifest, no duplicate
    pairs, and the documented layout (origin varies fastest, destination
    slowest). Reading each gzip member end-to-end also validates its CRC.
4.  **Values** — diagonal exactly zero, no negatives, and no half-written pairs
    (a time without a distance or vice versa).
5.  **Unrouted pairs** — separates genuinely isolated areas (unroutable in
    nearly every direction, e.g. Idjwi island) from rectangular all-NA blocks,
    which indicate an API tile that exhausted its retries and needs re-running.
6.  **Geometry** — flags snap collisions, where OSRM's Table service snaps two
    distinct areas onto the same node of the largest connected road component
    and reports ~0 km between areas that are kilometres apart. Also reports
    road distances shorter than the great-circle distance, detour ratios and
    implied speeds.

CLI:
    nix-shell --run 'python3 data/osrm/check_health_areas.py'
    nix-shell --run 'python3 data/osrm/check_health_areas.py --report qa/reports/osrm_health_areas.md'

Requires pandas/numpy, which `shell.nix` provides via geopandas.

Exit code is non-zero if any check fails (CI gate). Snap collisions and
optimistic speeds are reported as warnings: they are properties of the public
OSRM instance, not of this pipeline, and cannot be fixed by re-running.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd

COLUMNS = ["origin_grid3id", "destination_grid3id", "travel_time_min", "road_distance_km"]
PART_RE = re.compile(r"\.part-(\d{6})-(\d{6})\.csv\.gz$")

DEFAULT_DIR = Path(__file__).resolve().parent / "processed" / "health_areas"
MANIFEST_NAME = "health_area_ids.csv"

# Rough DRC bounding box, to catch a manifest built from the wrong layer.
DRC_BBOX = (11.0, -14.0, 32.0, 6.0)  # min_lon, min_lat, max_lon, max_lat

# An area unroutable to/from at least this share of the country is treated as
# genuinely isolated rather than as a routing failure.
ISOLATED_FRACTION = 0.5

# Two distinct areas closer than this by road are assumed to have snapped onto
# the same network node.
SNAP_COLLISION_KM = 0.05

# Implied average speed above this is not plausible for the DRC road network.
MAX_PLAUSIBLE_KMH = 120.0

EARTH_RADIUS_KM = 6371.0088


def great_circle_km(lon1, lat1, lon2, lat2) -> np.ndarray:
    """Haversine distance in kilometres, elementwise over array-likes."""
    lat1, lat2 = np.radians(np.asarray(lat1, float)), np.radians(np.asarray(lat2, float))
    dlat = lat2 - lat1
    dlon = np.radians(np.asarray(lon2, float) - np.asarray(lon1, float))
    a = np.sin(dlat / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * np.arcsin(np.sqrt(a))


@dataclass
class Report:
    """Accumulates findings; any failure flips the exit code."""

    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    lines: list[str] = field(default_factory=list)

    def section(self, title: str) -> None:
        self.lines.append(f"\n## {title}\n")

    def ok(self, msg: str) -> None:
        self.lines.append(f"- PASS  {msg}")

    def fail(self, msg: str) -> None:
        self.failures.append(msg)
        self.lines.append(f"- FAIL  {msg}")

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        self.lines.append(f"- WARN  {msg}")

    def note(self, msg: str) -> None:
        self.lines.append(f"        {msg}")


@dataclass
class PartResult:
    """Everything one worker extracts from a single part file."""

    name: str
    lo: int
    hi: int
    rows: int
    problems: list[str]
    diag_expected: int
    diag_present: int
    diag_nonzero: int
    diag_na: int
    na_total: int
    na_mixed: int
    negative: int
    zero_time_positive_km: int
    fast: int
    na_pairs: np.ndarray  # (n, 2) int32 of manifest row indices, 0-based
    snap_pairs: np.ndarray  # (n, 2) int32, distinct areas under SNAP_COLLISION_KM
    shorter_pairs: np.ndarray  # (n, 2) int32, road distance below great-circle
    dist_sum: float
    dist_n: int
    max_time: float
    max_dist: float
    detour_hist: np.ndarray
    speed_hist: np.ndarray


DETOUR_BINS = np.array([0, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0, 10.0, np.inf])
SPEED_BINS = np.array([0, 10, 20, 30, 40, 50, 60, 70, 80, 100, np.inf])

# Set once per worker by _init_worker, to avoid shipping the manifest per task.
_CTX: dict = {}


def _init_worker(ids: list[str], lon: np.ndarray, lat: np.ndarray) -> None:
    _CTX["index"] = {gid: i for i, gid in enumerate(ids)}
    _CTX["ids"] = ids
    _CTX["lon"] = lon
    _CTX["lat"] = lat


def scan_part(path: Path) -> PartResult:
    """Read one part file and return its structural and value findings."""
    index, ids = _CTX["index"], _CTX["ids"]
    lon, lat = _CTX["lon"], _CTX["lat"]
    n_areas = len(ids)

    match = PART_RE.search(path.name)
    lo, hi = int(match.group(1)), int(match.group(2))
    block = ids[lo - 1 : hi]
    block_size = len(block)

    df = pd.read_csv(path, header=None, names=COLUMNS)
    problems: list[str] = []

    if len(df) != block_size * n_areas:
        problems.append(f"row count {len(df):,} != {block_size * n_areas:,}")

    origins = df.origin_grid3id.to_numpy()
    dests = df.destination_grid3id.to_numpy()

    if set(origins) != set(block):
        problems.append("origin ids do not match this block's manifest rows")
    if set(dests) != set(ids):
        problems.append("destination ids do not match the full manifest")
    if df.duplicated(["origin_grid3id", "destination_grid3id"]).any():
        problems.append("duplicate (origin, destination) pairs")

    # Documented layout: origin varies fastest, destination slowest.
    if len(df) == block_size * n_areas:
        if list(origins[:block_size]) != block:
            problems.append("origins do not vary fastest in manifest order")
        if list(dests[::block_size]) != ids:
            problems.append("destinations do not vary slowest in manifest order")

    # Map ids to manifest rows once; everything below works on integer indices.
    oi = np.fromiter((index[g] for g in origins), dtype=np.int32, count=len(df))
    di = np.fromiter((index[g] for g in dests), dtype=np.int32, count=len(df))

    time = df.travel_time_min.to_numpy(float)
    dist = df.road_distance_km.to_numpy(float)
    time_na, dist_na = np.isnan(time), np.isnan(dist)
    na = time_na | dist_na

    self_pair = oi == di
    diag_na = int((self_pair & na).sum())
    diag_nonzero = int((self_pair & ~na & ((time != 0) | (dist != 0))).sum())

    routed = ~na & ~self_pair
    r_time, r_dist = time[routed], dist[routed]
    r_oi, r_di = oi[routed], di[routed]

    gc = great_circle_km(lon[r_oi], lat[r_oi], lon[r_di], lat[r_di])
    with np.errstate(divide="ignore", invalid="ignore"):
        detour = np.where(gc > 1.0, r_dist / gc, np.nan)
        speed = np.where(r_time > 0, r_dist / (r_time / 60.0), np.nan)

    snap = r_dist < SNAP_COLLISION_KM
    shorter = (r_dist < gc * 0.99) & (gc > 1.0)
    fast = int(np.nansum(speed > MAX_PLAUSIBLE_KMH))

    return PartResult(
        name=path.name,
        lo=lo,
        hi=hi,
        rows=len(df),
        problems=problems,
        diag_expected=block_size,
        diag_present=int(self_pair.sum()),
        diag_nonzero=diag_nonzero,
        diag_na=diag_na,
        na_total=int(na.sum()),
        na_mixed=int((time_na ^ dist_na).sum()),
        negative=int(((r_time < 0) | (r_dist < 0)).sum()),
        zero_time_positive_km=int(((r_time == 0) & (r_dist > 0)).sum()),
        fast=fast,
        na_pairs=np.stack([oi[na], di[na]], axis=1).astype(np.int32),
        snap_pairs=np.stack([r_oi[snap], r_di[snap]], axis=1).astype(np.int32),
        shorter_pairs=np.stack([r_oi[shorter], r_di[shorter]], axis=1).astype(np.int32),
        dist_sum=float(r_dist.sum()),
        dist_n=int(routed.sum()),
        max_time=float(np.nanmax(time)) if routed.any() else float("nan"),
        max_dist=float(np.nanmax(dist)) if routed.any() else float("nan"),
        detour_hist=np.histogram(detour[~np.isnan(detour)], bins=DETOUR_BINS)[0],
        speed_hist=np.histogram(speed[~np.isnan(speed)], bins=SPEED_BINS)[0],
    )


def check_manifest(path: Path, rep: Report) -> pd.DataFrame:
    rep.section("Manifest")
    manifest = pd.read_csv(path)
    required = {"row", "grid3id", "airesante", "zonesante", "province", "lon", "lat"}
    missing = required - set(manifest.columns)
    if missing:
        rep.fail(f"{path.name} is missing columns: {', '.join(sorted(missing))}")
        return manifest

    rep.ok(f"{path.name}: {len(manifest):,} rows, columns as documented")

    dupes = manifest.grid3id[manifest.grid3id.duplicated()].unique()
    if len(dupes):
        rep.fail(f"grid3id is not unique ({len(dupes)} duplicated, e.g. {dupes[0]})")
    else:
        rep.ok(f"grid3id unique across all {len(manifest):,} rows")

    if manifest.grid3id.isna().any() or (manifest.grid3id.astype(str).str.strip() == "").any():
        rep.fail("grid3id contains empty values")

    if list(manifest.row) != list(range(1, len(manifest) + 1)):
        rep.fail("manifest `row` is not 1..N in order")
    else:
        rep.ok("manifest `row` is 1..N in order")

    lon_min, lat_min, lon_max, lat_max = DRC_BBOX
    outside = manifest[
        ~manifest.lon.between(lon_min, lon_max) | ~manifest.lat.between(lat_min, lat_max)
    ]
    if len(outside):
        rep.fail(f"{len(outside)} representative points fall outside the DRC bounding box")
    else:
        rep.ok("all representative points fall inside the DRC bounding box")

    return manifest


def check_coverage(part_dir: Path, n_areas: int, rep: Report) -> list[Path]:
    rep.section("Part coverage")
    parts = sorted(part_dir.glob("*.csv.gz"), key=lambda p: int(PART_RE.search(p.name).group(1)))

    leftovers = list(part_dir.glob("*.tmp"))
    if leftovers:
        rep.fail(f"{len(leftovers)} leftover .tmp file(s): a run was interrupted mid-write")
    else:
        rep.ok("no leftover .tmp files")

    if not parts:
        rep.fail(f"no part files found in {part_dir}")
        return parts

    ranges = [(int(m.group(1)), int(m.group(2))) for m in (PART_RE.search(p.name) for p in parts)]
    expected_row = 1
    gaps = []
    for lo, hi in ranges:
        if lo != expected_row:
            gaps.append(f"expected row {expected_row}, part starts at {lo}")
        expected_row = hi + 1
    if gaps:
        rep.fail(f"part ranges are not contiguous: {'; '.join(gaps[:5])}")
    elif expected_row - 1 != n_areas:
        rep.fail(f"parts cover rows 1-{expected_row - 1}, manifest has {n_areas}")
    else:
        rep.ok(f"{len(parts)} parts cover rows 1-{n_areas} contiguously, no gaps or overlaps")

    return parts


def classify_unrouted(
    na_pairs: np.ndarray, manifest: pd.DataFrame, chunk: int, rep: Report
) -> None:
    """Split NA pairs into genuinely isolated areas and failed API tiles."""
    rep.section("Unrouted pairs")
    n_areas = len(manifest)
    if not len(na_pairs):
        rep.ok("no unrouted pairs")
        return

    total_pairs = n_areas * n_areas
    rep.ok(
        f"{len(na_pairs):,} unrouted pairs "
        f"({100 * len(na_pairs) / total_pairs:.2f}% of {total_pairs:,})"
    )

    out_counts = np.bincount(na_pairs[:, 0], minlength=n_areas)
    in_counts = np.bincount(na_pairs[:, 1], minlength=n_areas)
    threshold = n_areas * ISOLATED_FRACTION
    isolated = np.where((out_counts > threshold) & (in_counts > threshold))[0]

    if len(isolated):
        rep.note(
            f"{len(isolated)} area(s) are unroutable in >{ISOLATED_FRACTION:.0%} of directions, "
            "consistent with genuine isolation from the car network:"
        )
        info = manifest.iloc[isolated]
        for zone, grp in info.groupby("zonesante", sort=True):
            rep.note(
                f"  {len(grp):3d} in {zone} ({grp.province.iloc[0]}): "
                f"{', '.join(sorted(grp.airesante)[:4])}"
                + (" ..." if len(grp) > 4 else "")
            )

    # Anything left is a routing failure rather than a property of the network.
    isolated_set = set(isolated.tolist())
    mask = ~(
        np.isin(na_pairs[:, 0], list(isolated_set)) | np.isin(na_pairs[:, 1], list(isolated_set))
    )
    unexplained = na_pairs[mask]
    if not len(unexplained):
        rep.ok("every unrouted pair involves a genuinely isolated area")
        return

    # Failed tiles are rectangular: one block of origins x one chunk of
    # destinations, all NA. Group by tile and report the full ones.
    tiles = pd.DataFrame(
        {
            "origin_block": unexplained[:, 0] // chunk,
            "dest_chunk": unexplained[:, 1] // chunk,
        }
    ).value_counts()

    rep.fail(
        f"{len(unexplained):,} unrouted pairs are NOT explained by isolated areas, "
        f"spanning {len(tiles)} tile(s) of {chunk}x{chunk}"
    )
    rep.note("these are API tiles that exhausted their retries; re-run the affected parts:")
    for (origin_block, dest_chunk), count in tiles.items():
        o_lo, o_hi = origin_block * chunk + 1, min((origin_block + 1) * chunk, n_areas)
        d_lo, d_hi = dest_chunk * chunk + 1, min((dest_chunk + 1) * chunk, n_areas)
        full = " (entire tile)" if count == (o_hi - o_lo + 1) * (d_hi - d_lo + 1) else ""
        rep.note(
            f"  origins {o_lo}-{o_hi} x destinations {d_lo}-{d_hi}: {count:,} pairs{full}"
        )
        rep.note(
            f"    rm processed/health_areas/"
            f"osrm__travel_time_road_distance__healthareas.part-{o_lo:06d}-{o_hi:06d}.csv.gz"
        )


def report_snap_collisions(snap_pairs: np.ndarray, manifest: pd.DataFrame, rep: Report) -> None:
    """Cluster areas that OSRM collapsed onto a shared road-network node."""
    rep.section("Snap collisions")
    if not len(snap_pairs):
        rep.ok("no distinct areas report a near-zero road distance")
        return

    parent: dict[int, int] = {}

    def find(x: int) -> int:
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b in snap_pairs:
        ra, rb = find(int(a)), find(int(b))
        if ra != rb:
            parent[ra] = rb

    clusters: dict[int, list[int]] = {}
    for node in list(parent):
        clusters.setdefault(find(node), []).append(node)

    lon, lat = manifest.lon.to_numpy(), manifest.lat.to_numpy()
    spans = []
    for members in clusters.values():
        idx = np.array(members)
        span = max(
            float(great_circle_km(lon[a], lat[a], lon[b], lat[b]))
            for a in idx
            for b in idx
        )
        spans.append((span, members))
    spans.sort(reverse=True, key=lambda s: s[0])

    rep.warn(
        f"{len(snap_pairs):,} pairs of distinct areas report <{SNAP_COLLISION_KM * 1000:.0f} m "
        f"by road, covering {len(parent)} areas in {len(clusters)} cluster(s)"
    )
    rep.note(
        "OSRM's Table service snaps to the largest connected road component, so an area whose "
        "nearest road is a disconnected fragment is measured from a node far away. Every "
        "distance for these areas is suspect, not just the near-zero ones."
    )
    rep.note(f"widest true separation reported as ~0 km: {spans[0][0]:.1f} km")
    for span, members in spans[:5]:
        names = manifest.iloc[members]
        rep.note(
            f"  {len(members)} areas spanning {span:.1f} km "
            f"[{names.province.iloc[0]} / {names.zonesante.iloc[0]}]: "
            f"{', '.join(sorted(names.airesante)[:4])}" + (" ..." if len(members) > 4 else "")
        )


def histogram_lines(hist: np.ndarray, bins: np.ndarray, total: int, unit: str) -> list[str]:
    out = []
    for lo, hi, count in zip(bins[:-1], bins[1:], hist):
        hi_s = "inf" if np.isinf(hi) else f"{hi:g}"
        share = 100 * count / total if total else 0.0
        out.append(f"  {lo:>5g} - {hi_s:>5s} {unit}: {count:14,d}  ({share:5.2f}%)")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--dir", type=Path, default=DEFAULT_DIR, help=f"part directory (default: {DEFAULT_DIR})"
    )
    parser.add_argument(
        "--chunk",
        type=int,
        default=100,
        help="OSRM_CHUNK_SIZE the run used, for locating failed tiles (default: 100)",
    )
    parser.add_argument("--workers", type=int, default=8, help="parallel readers (default: 8)")
    parser.add_argument("--report", type=Path, help="also write the report to this file")
    args = parser.parse_args(argv)

    rep = Report()
    part_dir: Path = args.dir
    manifest_path = part_dir / MANIFEST_NAME
    if not manifest_path.exists():
        print(f"FAIL  no manifest at {manifest_path}", file=sys.stderr)
        return 1

    manifest = check_manifest(manifest_path, rep)
    if rep.failures:
        print("\n".join(rep.lines))
        return 1

    ids = manifest.grid3id.tolist()
    n_areas = len(ids)
    parts = check_coverage(part_dir, n_areas, rep)
    if not parts:
        print("\n".join(rep.lines))
        return 1

    lon = manifest.lon.to_numpy(float)
    lat = manifest.lat.to_numpy(float)
    with Pool(args.workers, initializer=_init_worker, initargs=(ids, lon, lat)) as pool:
        results = pool.map(scan_part, parts)

    rep.section("Structure")
    flagged = [r for r in results if r.problems]
    for r in flagged:
        rep.fail(f"{r.name}: {'; '.join(r.problems)}")
    if not flagged:
        rep.ok(
            f"all {len(results)} parts: row counts, id sets, uniqueness and row order as documented"
        )

    total_rows = sum(r.rows for r in results)
    if total_rows != n_areas * n_areas:
        rep.fail(f"total rows {total_rows:,} != {n_areas * n_areas:,} expected")
    else:
        rep.ok(f"total rows {total_rows:,} = {n_areas}^2")

    rep.section("Values")
    diag_present = sum(r.diag_present for r in results)
    diag_nonzero = sum(r.diag_nonzero for r in results)
    diag_na = sum(r.diag_na for r in results)
    if diag_present != n_areas:
        rep.fail(f"{diag_present:,} self-pairs present, expected {n_areas:,}")
    elif diag_nonzero:
        rep.fail(f"{diag_nonzero:,} self-pairs are non-zero")
    elif diag_na:
        rep.fail(f"{diag_na:,} self-pairs are unrouted (should be 0,0)")
    else:
        rep.ok(f"all {n_areas:,} self-pairs are exactly 0 minutes, 0 km")

    for label, count, hard in (
        ("negative values", sum(r.negative for r in results), True),
        ("half-written pairs (one metric present, one missing)", sum(r.na_mixed for r in results), True),
        ("routed pairs with zero time but positive distance", sum(r.zero_time_positive_km for r in results), False),
        (f"routed pairs implying over {MAX_PLAUSIBLE_KMH:.0f} km/h", sum(r.fast for r in results), False),
    ):
        if not count:
            rep.ok(f"no {label}")
        elif hard:
            rep.fail(f"{count:,} {label}")
        else:
            rep.warn(f"{count:,} {label}")

    na_pairs = np.concatenate([r.na_pairs for r in results]) if results else np.empty((0, 2), int)
    classify_unrouted(na_pairs, manifest, args.chunk, rep)

    snap_pairs = np.concatenate([r.snap_pairs for r in results])
    report_snap_collisions(snap_pairs, manifest, rep)

    rep.section("Geometry and plausibility")
    shorter = sum(len(r.shorter_pairs) for r in results)
    routed = sum(r.dist_n for r in results)
    if shorter:
        rep.warn(
            f"{shorter:,} routed pairs ({100 * shorter / routed:.2f}%) have a road distance "
            "shorter than the straight-line distance, which is geometrically impossible"
        )
    else:
        rep.ok("no road distance falls below the great-circle distance")

    rep.note(f"routed non-self pairs: {routed:,}")
    rep.note(f"mean road distance: {sum(r.dist_sum for r in results) / routed:,.1f} km")
    rep.note(f"max road distance: {max(r.max_dist for r in results):,.1f} km")
    rep.note(f"max travel time: {max(r.max_time for r in results):,.1f} min")

    detour = sum(r.detour_hist for r in results)
    rep.note("detour ratio (road km / great-circle km):")
    rep.lines.extend(histogram_lines(detour, DETOUR_BINS, int(detour.sum()), "x"))

    speed = sum(r.speed_hist for r in results)
    rep.note("implied average speed:")
    rep.lines.extend(histogram_lines(speed, SPEED_BINS, int(speed.sum()), "km/h"))

    rep.section("Summary")
    rep.lines.append(f"- {len(rep.failures)} failure(s), {len(rep.warnings)} warning(s)")
    for msg in rep.failures:
        rep.lines.append(f"  FAIL  {msg}")
    for msg in rep.warnings:
        rep.lines.append(f"  WARN  {msg}")

    text = "\n".join(rep.lines)
    print(text)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(f"# OSRM health-area QA\n{text}\n")
        print(f"\nwrote {args.report}")

    return 1 if rep.failures else 0


if __name__ == "__main__":
    sys.exit(main())
