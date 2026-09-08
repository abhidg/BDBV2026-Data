# testthat tests for process_health_areas.R.
#
# Run from the repository root:
#
#   nix-shell --run 'Rscript data/osrm/test_process_health_areas.R'
#
# These run offline by default: osrmTable() is stubbed, so no OSRM API calls
# are made and the suite takes about a minute (most of it reading the 267 MB
# shapefile once per scenario). To additionally hit the live public API with a
# handful of calls:
#
#   OSRM_TEST_LIVE=1 nix-shell --run 'Rscript data/osrm/test_process_health_areas.R'
#
# The script under test is not modified and carries no test hooks. Instead each
# scenario copies it to a temporary file, rewrites the output directory and
# injects a subset plus a stub, then runs that copy as a subprocess. A
# subprocess is required because the script begins with rm(list = ls()), which
# would wipe this file's own state if it were sourced in-process.

library(testthat)
library(here)

# Running this file directly re-enters it through test_file(), so that every
# test runs under a reporter rather than halting at the first failure, while
# the process still exits non-zero. The sentinel stops that recursing.
if (!nzchar(Sys.getenv("OSRM_TEST_INNER"))) {
  self <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])
  Sys.setenv(OSRM_TEST_INNER = "1")
  results <- test_file(normalizePath(self), reporter = "summary",
                       stop_on_failure = FALSE)
  tally <- as.data.frame(results)
  quit(save = "no",
       status = if (sum(tally$failed, tally$error) > 0) 1L else 0L)
}

setwd(here())

SCRIPT  <- "data/osrm/process_health_areas.R"
RSCRIPT <- file.path(R.home("bin"), "Rscript")
COLS    <- c("origin_grid3id", "destination_grid3id",
             "travel_time_min", "road_distance_km")
N       <- 50   # areas per scenario; at chunk 20 this gives blocks of 20/20/10

# The stub encodes each pair's global row indices in the value it returns:
#
#   duration_minutes = origin_row * 1000 + destination_row
#
# It recovers those global rows by matching grid3id, so it does not depend on
# how the script happens to batch. Every cell in the output can then be checked
# against its own coordinates, which catches any misalignment in the tile
# pasting or the melt to long format — not just at boundaries but everywhere.
# The encoding is integer-valued so it survives the script's rounding (2 dp on
# minutes, 3 dp on km after a division by 1000).
STUB <- '
osrmTable <- function(src, dst, measure, osrm.profile) {
  o <- match(src$grid3id, ids)
  d <- match(dst$grid3id, ids)
  v <- outer(o, d, function(a, b) a * 1000 + b)
  list(durations = matrix(v, nrow(src), nrow(dst)),
       distances = matrix(v * 1000, nrow(src), nrow(dst)))
}
'

# Copy the script, point it at `out` and splice in `inject` at the point where
# centroids_sf exists but nothing has been routed yet.
prepare <- function(out, n_areas, inject) {
  src <- readLines(SCRIPT, warn = FALSE)
  anchor <- grep("^total_areas <- nrow\\(centroids_sf\\)$", src)
  expect_length(anchor, 1)          # guards against the script being restructured
  dir_line <- grep('^out_dir <- "', src)
  expect_length(dir_line, 1)

  src[dir_line] <- sprintf('out_dir <- "%s"', out)
  patched <- append(
    src,
    c(sprintf("centroids_sf <- centroids_sf[1:%d, ]", n_areas), inject),
    after = anchor - 1
  )
  tmp <- tempfile(fileext = ".R")
  writeLines(patched, tmp)
  tmp
}

run_script <- function(out, n_areas, inject, env) {
  path <- prepare(out, n_areas, inject)
  res <- suppressWarnings(
    system2(RSCRIPT, path, stdout = TRUE, stderr = TRUE, env = env))
  list(output = paste(res, collapse = "\n"), status = attr(res, "status"))
}

new_out_dir <- function(name) {
  path <- file.path(tempdir(), name)
  unlink(path, recursive = TRUE)
  dir.create(path, recursive = TRUE)
  path
}

read_parts <- function(out) {
  parts <- sort(list.files(out, pattern = "\\.csv\\.gz$", full.names = TRUE))
  if (length(parts) == 0) return(NULL)
  do.call(rbind, lapply(parts, function(p)
    read.csv(gzfile(p), header = FALSE, col.names = COLS,
             colClasses = c("character", "character", "numeric", "numeric"))))
}

n_parts <- function(out) length(list.files(out, pattern = "\\.csv\\.gz$"))

manifest_ids <- function(out) {
  read.csv(file.path(out, "health_area_ids.csv"), colClasses = "character")$grid3id
}

STUB_ENV <- c("OSRM_CHUNK_SIZE=20", "OSRM_SLEEP=0")


# ---- A complete run ---------------------------------------------------------
out_main <- new_out_dir("scenario_main")
run_main <- run_script(out_main, N, STUB, STUB_ENV)
parts_main <- read_parts(out_main)

test_that("a complete run finishes and writes one part per origin block", {
  expect_null(run_main$status)
  expect_equal(n_parts(out_main), 3)
  expect_true(file.exists(file.path(out_main, "health_area_ids.csv")))
  expect_match(run_main$output, "Part files: 3 of 3", fixed = TRUE)
})

test_that("the output covers every ordered pair exactly once", {
  expect_equal(nrow(parts_main), N^2)
  expect_equal(sum(duplicated(parts_main[, 1:2])), 0)
  expect_setequal(unique(parts_main$origin_grid3id), manifest_ids(out_main))
  expect_setequal(unique(parts_main$destination_grid3id), manifest_ids(out_main))
})

test_that("every cell's value matches the pair it is labelled with", {
  # Inverts the stub's encoding: derive what each row should hold from its own
  # two id columns, and compare against what was written. Independent of row
  # order and of how rows are split across part files.
  ids <- manifest_ids(out_main)
  expected <- match(parts_main$origin_grid3id, ids) * 1000 +
    match(parts_main$destination_grid3id, ids)

  expect_equal(parts_main$travel_time_min, expected)
  expect_equal(parts_main$road_distance_km, expected)
})

test_that("no pair is left unrouted when every call succeeds", {
  expect_equal(sum(is.na(parts_main$travel_time_min)), 0)
  expect_equal(sum(is.na(parts_main$road_distance_km)), 0)
  expect_match(run_main$output, "Unrouted (NA) pairs this run: 0", fixed = TRUE)
})


# ---- Resume -----------------------------------------------------------------
deleted <- list.files(out_main, pattern = "part-000021-000040", full.names = TRUE)
stopifnot(length(deleted) == 1)
invisible(file.remove(deleted))
run_resumed <- run_script(out_main, N, STUB, STUB_ENV)
parts_resumed <- read_parts(out_main)

test_that("resuming recomputes only the blocks whose part file is missing", {
  expect_null(run_resumed$status)
  expect_match(run_resumed$output, "Origin blocks: 2 of 3 already complete",
               fixed = TRUE)
  expect_match(run_resumed$output, "Block 1/3 .*already done")
  expect_match(run_resumed$output, "Block 3/3 .*already done")
  expect_length(gregexpr("wrote osrm__", run_resumed$output)[[1]], 1)
})

test_that("a resumed run reproduces the uninterrupted output", {
  key <- function(d) d[order(d$origin_grid3id, d$destination_grid3id), ]
  expect_equal(key(parts_resumed), key(parts_main), ignore_attr = TRUE)
})


# ---- Guard: chunk size changed ----------------------------------------------
run_rechunked <- run_script(out_main, N, STUB,
                            c("OSRM_CHUNK_SIZE=25", "OSRM_SLEEP=0"))

test_that("a changed chunk size aborts instead of mixing part files", {
  expect_false(is.null(run_rechunked$status))
  expect_gt(run_rechunked$status, 0)
  expect_match(run_rechunked$output, "do not match OSRM_CHUNK_SIZE=25",
               fixed = TRUE)
  expect_equal(n_parts(out_main), 3)   # existing parts untouched
})


# ---- Guard: layer changed ---------------------------------------------------
out_stale <- new_out_dir("scenario_stale")
invisible(run_script(out_stale, N, STUB, STUB_ENV))
stale_manifest <- file.path(out_stale, "health_area_ids.csv")
lines <- readLines(stale_manifest)
lines[3] <- sub("^([^,]*,)[^,]*", "\\1as_TAMPERED", lines[3])
writeLines(lines, stale_manifest)
run_stale <- run_script(out_stale, N, STUB, STUB_ENV)

test_that("a layer that no longer matches the manifest aborts", {
  expect_false(is.null(run_stale$status))
  expect_gt(run_stale$status, 0)
  expect_match(run_stale$output, "does not match the current layer", fixed = TRUE)
})

test_that("the manifest mismatch names the offending row and id", {
  expect_match(run_stale$output, "first difference at row 2", fixed = TRUE)
  expect_match(run_stale$output, "as_TAMPERED", fixed = TRUE)
})


# ---- Live public API (opt-in) -----------------------------------------------
test_that("routing against the live public OSRM API works end to end", {
  skip_if_not(nzchar(Sys.getenv("OSRM_TEST_LIVE")),
              "set OSRM_TEST_LIVE=1 to include the live API test")

  out_live <- new_out_dir("scenario_live")
  run_live <- run_script(out_live, 5, "",
                         c("OSRM_CHUNK_SIZE=3", "OSRM_SLEEP=1"))
  expect_null(run_live$status)

  live <- read_parts(out_live)
  expect_equal(nrow(live), 25)

  self_pairs <- live[live$origin_grid3id == live$destination_grid3id, ]
  expect_equal(nrow(self_pairs), 5)
  expect_true(all(self_pairs$travel_time_min == 0))
  expect_true(all(self_pairs$road_distance_km == 0))

  expect_true(all(is.finite(live$travel_time_min)))
  expect_true(all(live$travel_time_min >= 0))
})
