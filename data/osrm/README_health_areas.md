# OSRM road travel time and distance at health-area grain

Pairwise **driving** travel times and road distances between all **9720 GRID3 health areas** in the Democratic Republic of the Congo (DRC), routed via the [OSRM](http://project-osrm.org/) engine (OpenStreetMap road network).

This is the finer-grained companion to the health-zone matrices described in [README.md](README.md). The zone product covers 519 health zones as square `.matrix.csv` files; this one covers 9720 health areas and, because that is 94.5M origin–destination pairs, uses a different output format entirely. Read this file rather than `README.md` if you are working with health areas.

------------------------------------------------------------------------

## Why the format differs

At zone grain the OD matrix is 519 × 519 and fits comfortably in a CSV. At area grain it is 9720 × 9720 = **94,478,400 pairs**, which as square matrices would be ~700 MB per metric and ~1.5 GB in memory. So the output is instead a **gzipped long table, split into one part file per block of origins**, and the script is resumable.

This deliberately does **not** follow the repo's `<dataset>__<metric>__<resolution>.matrix.csv` contract. The outputs live in a `processed/` subdirectory so that `tools.qa` — which scans `processed/` non-recursively for files — does not attempt to validate them.

------------------------------------------------------------------------

## Files

| File | Description |
|----|----|
| `process_health_areas.R` | Build the matrices via the public OSRM Table API |
| `processed/health_areas/health_area_ids.csv` | Row-order manifest: `row`, `grid3id`, `airesante`, `zonesante`, `province`, `lon`, `lat` (9720 rows, ~784 KB) |
| `processed/health_areas/osrm__travel_time_road_distance__healthareas.part-NNNNNN-NNNNNN.csv.gz` | 98 gzipped part files, one per block of 100 origins, named by the row range covered (~1.0 GB total) |

**Outputs are not committed.** `data/osrm/processed/health_areas/` is gitignored — ~1.0 GB that is regenerable in about a day. See [.gitignore](../../.gitignore) for the rule and the LFS alternative if these ever need distributing.

**Dimensions:** 9720 × 9720 health areas (94,478,400 pairs).\
**Coverage:** National — 26 provinces, 517 health zones.\
**Temporal scope:** Static snapshot (single routing run; not a time series).

------------------------------------------------------------------------

## Source geometry

`data/grid3_healthareas/GRID3_COD_health_areas_v9_0.shp` — 9720 polygons, WGS84 (EPSG:4326).

**Citation:** Center for Integrated Earth System Information (CIESIN), Columbia University; Ministère de la Santé Publique, Hygiène et Prévention, DRC; and GRID3 (2026). *GRID3 COD — Health Areas v9.0.* New York: Columbia University. <https://doi.org/10.7916/hv5g-p227>

**Licence:** Creative Commons Attribution 4.0 International (CC BY 4.0). Published 2026-08-13; supersedes v8.0. Full metadata in `../grid3_healthareas/GRID3_COD_health_areas_v9_0.shp.xml`.

------------------------------------------------------------------------

## Join key: `grid3id`

Rows and columns are keyed by **`grid3id`**, not by name. This differs from the zone product, which keys on `Nom`.

`grid3id` is the only single attribute in the layer that uniquely identifies every health area:

| Column | Distinct values (of 9720) |
|----|----|
| `grid3id` | **9720 — unique** |
| `as_uid` | 9666 |
| `airesante` | 8659 (756 names are shared by more than one area) |

So there is no name-disambiguation step, unlike the zone pipeline which suffixes duplicate `Nom` values with their province. The script asserts uniqueness, non-emptiness and presence of `grid3id` before starting, since ~9.6k API calls and a directory of part files are keyed on it.

Note that `grid3id` mixes 12 prefix conventions upstream (`as_`, `GRID3_`, `BU_`, `KSPH_`, …) and varies from 13 to 19 characters. This is cosmetic — the values are still unique — but treat the column as an opaque string, never parse it.

------------------------------------------------------------------------

## Method

1.  **Areas** — Load the shapefile and `st_make_valid()`.
2.  **Sort by `grid3id`** — Row order is made deterministic so that part-file boundaries are stable across runs. This is what makes resuming safe.
3.  **Representative points** — Reproject to WGS84 and take `st_point_on_surface()` for each polygon, so the routing origin/destination lies inside the area (centroids can fall outside irregular polygons).
4.  **Manifest** — Write `health_area_ids.csv` recording the row order, and on a resume compare it against the current layer; a mismatch aborts rather than reusing misaligned part files.
5.  **Routing** — Query the public OSRM Table API (`osrm` R package, `osrm.profile = "car"`) in 100 × 100 tiles.
6.  **Retries** — A failed tile is retried up to 4 times with exponential backoff before being left as `NA`.
7.  **Export** — After each block of 100 origins, the strip is reshaped to long format and written as one gzipped part, via a `.tmp` file and an atomic rename.

**Units**

-   Travel time: **minutes** (as returned by `osrmTable()`), rounded to 2 dp.
-   Distance: OSRM returns metres; divided by 1000 before saving (**kilometres**), rounded to 3 dp.

------------------------------------------------------------------------

## CSV format

Part files have **no header row**. Columns, in order:

| Column | Description |
|----|----|
| `origin_grid3id` | `grid3id` of the origin health area |
| `destination_grid3id` | `grid3id` of the destination health area |
| `travel_time_min` | Car travel time in minutes |
| `road_distance_km` | Car road distance in kilometres |

-   **Dense:** every ordered pair appears, including self-pairs and unroutable pairs. An unrouted pair is an empty field (`NA` when read), so "no route found" stays distinguishable from "not attempted".
-   **Diagonal:** `0` for both metrics where origin equals destination.
-   **Symmetry:** not guaranteed. One-way systems, turn restrictions and OSRM's directed graph yield genuinely different values in each direction — a spot-check found 1875.60 min one way and 1877.70 min the other for the same pair. Treat the table as directed unless you explicitly symmetrise.
-   **Ordering within a part:** destination varies slowest, origin fastest.

**Example (reading one part in R):**

``` r
library(here)

cols <- c("origin_grid3id", "destination_grid3id",
          "travel_time_min", "road_distance_km")
dir <- here("data/osrm/processed/health_areas")

part <- read.csv(gzfile(file.path(dir, "osrm__travel_time_road_distance__healthareas.part-000001-000100.csv.gz")),
                 header = FALSE, col.names = cols)
```

**Reading everything** is 94.5M rows and will not fit comfortably in memory as a data frame — filter per part instead:

``` r
parts <- list.files(dir, pattern = "\\.csv\\.gz$", full.names = TRUE)

# Travel times out of one origin, across all parts
one_origin <- do.call(rbind, lapply(parts, function(p) {
  d <- read.csv(gzfile(p), header = FALSE, col.names = cols)
  d[d$origin_grid3id == "as_00088F4F93", ]
}))
```

To attach names or provinces, join `health_area_ids.csv` on `grid3id`.

------------------------------------------------------------------------

## Regenerating outputs

From the **repository root** (the script uses `here()`, so it resolves the root from anywhere in the repo):

``` bash
nix-shell --run 'Rscript data/osrm/process_health_areas.R'
```

**Requirements:** R packages `sf`, `osrm`, `tictoc`, `here`; network access to the OSRM API. All are provided by [shell.nix](../../shell.nix).

**Runtime: ~21–27 hours** (9,604 API calls; measured at 9.06 s/call). For a run this long, detach it:

``` bash
nohup nix-shell --run 'Rscript data/osrm/process_health_areas.R' > osrm_health_areas.log 2>&1 &
```

**Resuming.** A part file is written to `.tmp` and renamed only once complete, so its existence means "done". Re-running the identical command skips finished blocks and picks up where it stopped, losing at most the strip in flight (~15 min). Two guards abort rather than produce a corrupt mixture:

-   the `grid3id` manifest no longer matches the layer (the shapefile changed), or
-   existing part names do not match the current `OSRM_CHUNK_SIZE` (chunking changed).

In both cases, clear `processed/health_areas/` and start over.

**Environment variables**

| Variable | Default | Meaning |
|----|----|----|
| `OSRM_CHUNK_SIZE` | 100 | Origins/destinations per API call |
| `OSRM_SLEEP` | 1 | Seconds between calls |
| `OSRM_MAX_RETRIES` | 4 | Retries per failed tile, exponential backoff |

------------------------------------------------------------------------

## Why `OSRM_CHUNK_SIZE` is 100

The public OSRM server **throttles per request, not per pair.** Measured over ~35 calls in September 2026: the first call of a session returns in ~0.3 s, and every subsequent call takes 8–9 s *regardless of tile size*. Tile size therefore drives the entire runtime:

| `OSRM_CHUNK_SIZE` | API calls | Wall clock |
|----|----|----|
| 20 | 236,196 | ~27 days |
| 50 | 38,025 | ~4 days |
| **100** | **9,604** | **~21–27 hours** |

100 is the ceiling, not a preference: the server's table limit is **200 coordinates**, so 100 origins + 100 destinations is the largest request it accepts. 110 × 110 is rejected with HTTP 400. Do not raise it.

**A local OSRM instance** would remove the throttle entirely and cut this to an estimated 1–4 hours, since you also control `--max-table-size` and could use far larger tiles. `nixpkgs` provides `osrm-backend`, and the DRC Geofabrik extract is ~416 MB, so setup is roughly 30–60 minutes of preprocessing. It would also make runs **reproducible** against a pinned OSM snapshot, which the public API cannot offer. This has not been set up; the current outputs come from the public API.

------------------------------------------------------------------------

## Data quality and limitations

| Issue | Detail |
|----|----|
| **Modelled, not observed** | Times and distances are road-network estimates, not measured travel. |
| **Car profile only** | No walking, ferry-specific, or seasonal/impassable-road logic. Much DRC travel is not by car, and the road network is sparse in places. |
| **Unroutable areas** | Areas the car network does not reach — islands especially — yield `NA`. The zone-grain product has this for Idjwi (island in Lake Kivu); expect the health areas within it, and other lake and forest areas, to behave the same. |
| **Public API is a moving target** | Re-running may give different values as OSM data and the public instance change. There is no snapshot pinning; a local instance would fix this. |
| **`point_on_surface` in lon/lat** | Computed in EPSG:4326, which emits an sf warning. Retained for consistency with the zone pipeline; the effect is negligible at health-area size. |
| **517 zones, not 519** | The health-areas layer names 517 distinct `zonesante` values, while `data/shapefiles/DRC_Health_zones.shp` has 519 zones. Do not assume the two layers' zone sets are identical when aggregating areas up to zones. |
| **Not comparable to the zone matrices** | The zone product was routed in 2026-03 against a different OSM snapshot. Do not mix grains quantitatively without regenerating both on one snapshot. |
| **Mixed `date` values** | The source layer's `date` field holds 2024, 2025 and 2026, so area boundaries are of mixed vintage. |

------------------------------------------------------------------------

## Verification

The pipeline was checked on a live 250-area subset (62,500 pairs) before the full run:

-   Row count exactly 250², no duplicate `(origin, destination)` pairs, all 250 ids present on both axes.
-   Diagonal exactly zero for both metrics; no unrouted pairs.
-   Five cells cross-checked against independent single-pair API queries and matched to the rounded digit — chosen to span tile and block boundaries, where an indexing error would surface.
-   Resume, chunk-size guard and manifest guard exercised against a stubbed API.

------------------------------------------------------------------------

## Provenance

-   **Geometry:** `data/grid3_healthareas/GRID3_COD_health_areas_v9_0.shp` (GRID3 COD Health Areas v9.0, CC BY 4.0).
-   **Routing engine:** [OSRM](http://project-osrm.org/) via the [`osrm`](https://cran.r-project.org/package=osrm) R package (`osrmTable`, `car` profile), public API.
-   **Road network:** OpenStreetMap contributors, ODbL 1.0 (<https://www.openstreetmap.org/copyright>). OSRM engine: BSD-2-Clause.
-   **Zone-grain equivalent and `metadata.yaml`:** [README.md](README.md).

For project-wide data conventions, see [`data/README.md`](../README.md).
