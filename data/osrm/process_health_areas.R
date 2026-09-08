rm(list = ls())

# Pairwise car travel time and road distance between GRID3 health areas.
#
# Health-area version of process.R. Two things differ from the health-zone run
# beyond the input layer:
#
#   * Rows are keyed by `grid3id`, which is unique across all 9720 areas, so no
#     name disambiguation is needed (unlike `Nom` for zones, where Bili and
#     Lubunga repeat across provinces).
#   * 9720 areas means 94.5M origin-destination pairs. At the largest tile the
#     public server accepts (100x100) that is ~9.6k calls and ~21-27 hours of
#     wall clock, measured. Dropping to 20x20 tiles would make it ~236k calls
#     and 27 days, because the server throttles per request rather than per
#     pair — so CHUNK_SIZE matters far more than it looks. A square matrix
#     would also be ~700 MB per metric and ~1.5 GB in memory. So results are
#     written as a gzipped long table, one part file per block of origins, and
#     the script is resumable — rerunning skips blocks whose part file already
#     exists, so a day-long run need not survive in one sitting.
#
# The long-format, gzipped output does not follow the repo's
# `<dataset>__<metric>__<resolution>.matrix.csv` contract, and lives in a
# processed/ subdirectory so tools.qa (which scans processed/ non-recursively
# for files) does not try to validate it.
#
# Usage (from the repository root):
#
#   Rscript data/osrm/process_health_areas.R
#
# Tunable via environment variables:
#
#   OSRM_CHUNK_SIZE   origins/destinations per API call (default 100, the
#                     most the public server accepts: its table limit is 200
#                     coordinates, and 110x110 is rejected with HTTP 400)
#   OSRM_SLEEP        seconds between calls (default 1; public API courtesy)
#   OSRM_MAX_RETRIES  retries per failed batch, exponential backoff (default 4)

# -------------------- 1. Install and Load Packages ----------------------------
if(!require("sf")) install.packages("sf")
if(!require("osrm")) install.packages("osrm")
if(!require("tictoc")) install.packages("tictoc") # Optional: to time the process
if(!require("here")) install.packages("here")

library(sf)
library(osrm)
library(tictoc)
library(here)

wd <- here()
setwd(wd)

env_num <- function(name, default) {
  value <- Sys.getenv(name, unset = NA)
  if (is.na(value) || value == "") return(default)
  parsed <- suppressWarnings(as.numeric(value))
  if (is.na(parsed)) stop(sprintf("%s must be numeric, got '%s'", name, value))
  parsed
}

CHUNK_SIZE  <- env_num("OSRM_CHUNK_SIZE", 100)
SLEEP_SECS  <- env_num("OSRM_SLEEP", 1)
MAX_RETRIES <- env_num("OSRM_MAX_RETRIES", 4)

out_dir <- "data/osrm/processed/health_areas"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

manifest_path <- file.path(out_dir, "health_area_ids.csv")
out_columns <- c("origin_grid3id", "destination_grid3id",
                 "travel_time_min", "road_distance_km")


# ---------------------------- 2. Load Data ------------------------------------
shapefile_name <- "data/grid3_healthareas/GRID3_COD_health_areas_v9_0.shp"

areas_sf <- tryCatch({
  st_read(shapefile_name, quiet = TRUE) |>
    st_make_valid()
}, error = function(e) {
  stop(sprintf("Error reading %s: %s", shapefile_name, conditionMessage(e)))
})

# grid3id is the join key throughout: assert it really is one before we key
# ~9.6k API calls and a directory of part files on it.
if (!"grid3id" %in% names(areas_sf)) {
  stop("Layer has no grid3id column; cannot key health areas.")
}
if (anyNA(areas_sf$grid3id) || any(areas_sf$grid3id == "")) {
  stop("grid3id has missing or empty values.")
}
if (anyDuplicated(areas_sf$grid3id)) {
  dupes <- unique(areas_sf$grid3id[duplicated(areas_sf$grid3id)])
  stop(sprintf("grid3id is not unique (%d duplicated values, e.g. %s).",
               length(dupes), paste(head(dupes, 3), collapse = ", ")))
}

# Sort by grid3id so row order — and therefore part-file boundaries — is stable
# across runs, which is what makes resuming safe.
areas_sf <- areas_sf[order(areas_sf$grid3id), ]


# ------------------------- 3. Prepare Centroids -------------------------------
# The API requires coordinates in degrees, not meters.
areas_sf_4326 <- st_transform(areas_sf, crs = 4326)

# Use point_on_surface to ensure the point is actually inside the polygon
# (st_centroid can sometimes fall outside for boomerang-shaped areas)
centroids_sf <- st_point_on_surface(areas_sf_4326)
centroids_sf$ID_Code <- centroids_sf$grid3id

total_areas <- nrow(centroids_sf)
ids <- centroids_sf$ID_Code


# --------------------- 4. Manifest and resume validation ----------------------
coords <- st_coordinates(centroids_sf)
manifest <- data.frame(
  row        = seq_len(total_areas),
  grid3id    = ids,
  airesante  = centroids_sf$airesante,
  zonesante  = centroids_sf$zonesante,
  province   = centroids_sf$province,
  lon        = coords[, "X"],
  lat        = coords[, "Y"],
  stringsAsFactors = FALSE
)

# Part files only mean anything relative to the row order that produced them.
# If the layer has changed since the last run, previously written parts are
# misaligned and silently reusing them would corrupt the output.
if (file.exists(manifest_path)) {
  previous <- read.csv(manifest_path, colClasses = "character")
  if (!identical(previous$grid3id, ids)) {
    n_common <- min(nrow(previous), total_areas)
    first_diff <- which(previous$grid3id[seq_len(n_common)] != ids[seq_len(n_common)])
    stop(sprintf(paste0(
      "Existing %s does not match the current layer's health areas.\n",
      "  previous: %d rows, current: %d rows, %d id(s) differ\n",
      "  first difference at row %s: %s -> %s\n",
      "Part files from the earlier run are misaligned. Clear %s and rerun."),
      manifest_path, nrow(previous), total_areas,
      length(first_diff) + abs(nrow(previous) - total_areas),
      if (length(first_diff)) first_diff[1] else "(none; row count differs)",
      if (length(first_diff)) previous$grid3id[first_diff[1]] else "-",
      if (length(first_diff)) ids[first_diff[1]] else "-",
      out_dir))
  }
} else {
  write.csv(manifest, manifest_path, row.names = FALSE)
}


# --------------------------- 5. Setup Batches ---------------------------------
# Requests are split so each call sends CHUNK_SIZE origins x CHUNK_SIZE
# destinations, i.e. 2 * CHUNK_SIZE coordinates in the URL. At the default 100
# that is 200, exactly the public server's table limit — see the header.
indices <- seq(1, total_areas, by = CHUNK_SIZE)
n_chunks <- length(indices)

# One part file per block of origins, named by the row range it covers.
part_path <- function(start, end) {
  file.path(out_dir, sprintf(
    "osrm__travel_time_road_distance__healthareas.part-%06d-%06d.csv.gz",
    start, end))
}
block_ends <- pmin(indices + CHUNK_SIZE - 1, total_areas)
expected_parts <- basename(mapply(part_path, indices, block_ends))

# Guard against mixing runs with different chunk sizes, whose part boundaries
# would overlap.
existing_parts <- list.files(out_dir, pattern = "\\.csv\\.gz$")
unexpected <- setdiff(existing_parts, expected_parts)
if (length(unexpected) > 0) {
  stop(sprintf(paste0(
    "%s holds %d part file(s) that do not match OSRM_CHUNK_SIZE=%d, e.g. %s\n",
    "They come from a run with different chunking. Clear the directory or ",
    "rerun with the original chunk size."),
    out_dir, length(unexpected), CHUNK_SIZE, unexpected[1]))
}

# The OD matrix is square — the same areas on both axes, chunked identically —
# so the loop below is n_chunks blocks of origins x n_chunks batches of
# destinations. Each origin block therefore costs n_chunks API calls (one per
# destination chunk), and a full run costs n_chunks^2.
done_blocks   <- sum(expected_parts %in% existing_parts)
blocks_left   <- n_chunks - done_blocks
calls_left    <- blocks_left * n_chunks

# Measured on the public API in 2026-09 over ~35 calls: cost is dominated by
# the server's rate limiting, not by routing. The first call of a session
# returns in ~0.3s and every later one pins to 8-9s regardless of tile size —
# which is why CHUNK_SIZE is set as high as the server allows. The per-block
# ETA printed below is measured and supersedes this estimate.
PER_CALL_LOW  <- 7
PER_CALL_HIGH <- 9

message(sprintf("Health areas: %d (keyed by grid3id)", total_areas))
message(sprintf("Origin blocks: %d of %d already complete", done_blocks, n_chunks))
message(sprintf("API calls remaining: ~%s", format(calls_left, big.mark = ",")))
message(sprintf("Rough runtime remaining: %.0f-%.0f hours (%.1f-%.1f days)",
                calls_left * (SLEEP_SECS + PER_CALL_LOW) / 3600,
                calls_left * (SLEEP_SECS + PER_CALL_HIGH) / 3600,
                calls_left * (SLEEP_SECS + PER_CALL_LOW) / 86400,
                calls_left * (SLEEP_SECS + PER_CALL_HIGH) / 86400))
message("Resumable: rerun the script to continue from the last complete block.")
message(sprintf("Writing to %s/", out_dir))


# ---------------------- 6. Route one batch, with retries ----------------------
route_batch <- function(src, dst) {
  for (attempt in seq_len(MAX_RETRIES + 1)) {
    res <- tryCatch(
      osrmTable(
        src = src,
        dst = dst,
        measure = c("duration", "distance"),
        osrm.profile = "car"
      ),
      error = function(e) e
    )

    if (!inherits(res, "error")) return(res)

    if (attempt > MAX_RETRIES) {
      message(sprintf("    giving up after %d attempts: %s",
                      attempt, conditionMessage(res)))
      return(NULL)
    }
    # Public API rate limiting (429) is the usual cause over a run this long,
    # so back off rather than leaving the whole batch NA on first failure.
    backoff <- max(SLEEP_SECS, 1) * 2^attempt
    message(sprintf("    batch failed (%s); retry %d/%d in %.0fs",
                    conditionMessage(res), attempt, MAX_RETRIES, backoff))
    Sys.sleep(backoff)
  }
}


# ------------------------- 7. Loop over blocks --------------------------------
tic("Total processing time") # Start timer

na_cells <- 0
computed <- 0
run_start <- Sys.time()

# Outer loop: one strip of CHUNK_SIZE origins per iteration. Skip it if its
# part file exists, otherwise fill two CHUNK_SIZE x total_areas matrices,
# reshape them to long rows and write one gzipped part.
# Inner loop: sweep across the columns, asking OSRM for one
# CHUNK_SIZE x CHUNK_SIZE tile at a time and pasting it into those matrices.
# So the outer loop chooses the rows, the inner loop fills them in. Results are
# committed once per strip, so a crash costs at most one strip's work.
for (block in seq_len(n_chunks)) {
  i <- indices[block]
  i_end <- block_ends[block]
  src_idx <- i:i_end
  src_batch <- centroids_sf[src_idx, ]
  path <- part_path(i, i_end)

  if (file.exists(path)) {
    cat(sprintf("Block %d/%d (rows %d-%d): already done, skipping\n",
                block, n_chunks, i, i_end))
    next
  }

  # Durations and distances for this block of origins against every
  # destination. At the default chunk size that is 100 x 9720 doubles, ~8 MB
  # each, so memory stays flat however many blocks we get through.
  dur_block  <- matrix(NA_real_, nrow = length(src_idx), ncol = total_areas)
  dist_block <- matrix(NA_real_, nrow = length(src_idx), ncol = total_areas)

  cat(sprintf("Block %d/%d (rows %d-%d): %d batches\n",
              block, n_chunks, i, i_end, n_chunks))

  for (j in indices) {
    j_end <- min(j + CHUNK_SIZE - 1, total_areas)
    dst_idx <- j:j_end
    dst_batch <- centroids_sf[dst_idx, ]

    res <- route_batch(src_batch, dst_batch)

    if (!is.null(res)) {
      expected_dim <- c(length(src_idx), length(dst_idx))
      if (identical(dim(res$durations), expected_dim)) {
        dur_block[, dst_idx]  <- res$durations
        dist_block[, dst_idx] <- res$distances
      } else {
        message(sprintf(
          "    unexpected result shape for cols %d-%d (%s, wanted %s); left NA",
          j, j_end, paste(dim(res$durations), collapse = "x"),
          paste(expected_dim, collapse = "x")))
      }
    }

    # Essential for public API to avoid '429 Too Many Requests'
    Sys.sleep(SLEEP_SECS)
  }

  # Melt to long format. as.vector() reads column-major, so destinations vary
  # slowest and origins fastest — matching the rep() patterns below.
  block_rows <- data.frame(
    origin_grid3id      = rep(ids[src_idx], times = total_areas),
    destination_grid3id = rep(ids, each = length(src_idx)),
    travel_time_min     = round(as.vector(dur_block), 2),
    road_distance_km    = round(as.vector(dist_block) / 1000, 3),
    stringsAsFactors = FALSE
  )
  na_cells <- na_cells + sum(is.na(block_rows$travel_time_min))

  # Write to a temporary file and rename, so a part file only ever exists once
  # it is complete: that is what the resume check above relies on.
  tmp_path <- paste0(path, ".tmp")
  con <- gzfile(tmp_path, open = "wt")
  write.table(block_rows, con, sep = ",", row.names = FALSE,
              col.names = FALSE, na = "", qmethod = "double")
  close(con)
  if (!file.rename(tmp_path, path)) {
    stop(sprintf("Could not finalise %s", path))
  }

  computed <- computed + 1
  elapsed <- as.numeric(difftime(Sys.time(), run_start, units = "hours"))
  remaining <- sum(!file.exists(mapply(part_path, indices, block_ends)))
  cat(sprintf("  wrote %s (%s rows); %.2fh elapsed, ~%.1fh left\n",
              basename(path), format(nrow(block_rows), big.mark = ","),
              elapsed, elapsed / computed * remaining))
}

toc() # End timer


# ---------------------------- 8. Summary --------------------------------------
parts <- sort(list.files(out_dir, pattern = "\\.csv\\.gz$", full.names = TRUE))
total_pairs <- as.numeric(total_areas) * total_areas

message(sprintf("Part files: %d of %d", length(parts), n_chunks))
message(sprintf("Pairs expected: %s", format(total_pairs, big.mark = ",", scientific = FALSE)))
message(sprintf("Unrouted (NA) pairs this run: %s", format(na_cells, big.mark = ",")))
message(sprintf("On-disk size: %.1f GB",
                sum(file.size(parts)) / 1024^3))

if (length(parts) < n_chunks) {
  message("Run incomplete — rerun the script to continue from the missing blocks.")
} else {
  message("Processing complete. Preview of the first part file:")
  preview <- read.csv(gzfile(parts[1]), header = FALSE,
                      col.names = out_columns, nrows = 5)
  print(preview)
}

message(sprintf(paste0(
  "Columns (no header row in part files): %s\n",
  "Read one part with:\n",
  "  read.csv(gzfile(path), header = FALSE, col.names = c(%s))"),
  paste(out_columns, collapse = ", "),
  paste(sprintf('"%s"', out_columns), collapse = ", ")))
