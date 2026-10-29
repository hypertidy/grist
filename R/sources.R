## Sources: a source is a name, a catalog of (date, dsn[, band]), and
## the native grid signature (dimension, extent) that the mapping is
## built against. The grid signature is the contract between mapping
## and daily reads: accumulate_date() refuses to run if they disagree.
##
## The catalog shape covers both file-per-date collections (dsn varies,
## band = 1) and array stores with time-as-bands (one dsn, band = time
## index), e.g. GDAL-readable Zarr with single-timestep chunks.

grid_from_dsn <- function(dsn, band = 1L) {
  info <- vapour::vapour_raster_info(dsn)
  list(dimension = info$dimension, extent = info$extent,
       projection = info$projection)
}

#' Construct a source from a catalog.
#'
#' files must have columns date and dsn; an optional band column
#' (integer, default 1) selects the band read for that date. grid is
#' stamped from the first catalog entry unless supplied -- supply it
#' explicitly when the driver does not report a correct extent (some
#' array stores), and ALWAYS verify a new source with an oracle date
#' before any backfill (see README: onboarding ritual).
stat_source <- function(name, files, grid = NULL) {
  stopifnot(is.character(name), nchar(name) > 0,
            all(c("date", "dsn") %in% names(files)))
  if (is.null(files$band)) files$band <- 1L
  files <- files[c("date", "dsn", "band")]
  if (is.null(grid)) grid <- grid_from_dsn(files$dsn[1], files$band[1])
  stopifnot(length(grid$dimension) == 2L, length(grid$extent) == 4L)
  list(name = name, files = files, grid = grid)
}

#' Read a contiguous block of rows (GDAL order, row 1 = top) of one
#' band at native resolution: a window read, no reprojection.
read_rows <- function(dsn, rows, grid, band = 1L) {
  dm <- grid$dimension
  ex <- grid$extent
  resx <- (ex[2] - ex[1]) / dm[1]
  resy <- (ex[4] - ex[3]) / dm[2]
  ymax <- ex[4] - (min(rows) - 1) * resy
  ymin <- ex[4] - max(rows) * resy
  vapour::gdal_raster_data(dsn,
    target_ext = c(ex[1], ex[2], ymin, ymax),
    target_res = c(resx, resy),
    bands = band,
    resample = "near")[[1]]
}
