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
#' Two catalog shapes (see README, "Catalog contract"):
#'   classic: date, dsn[, band]           read with GDAL's classic API
#'   mdim:    date, dsn, array, index     read with the multidim API
#' grid is stamped from the first catalog entry; a supplied grid (or
#' any part of one, e.g. list(projection = "EPSG:3412") for a store
#' that does not carry its CRS) overrides the stamped entries. A
#' projection given as an authority code or PROJ string is expanded to
#' WKT. ALWAYS verify a new source with an oracle date before any
#' backfill (see README: onboarding ritual).
#' transform names an entry of grist_transforms (default "identity").
#' For the mdim shape every row's index is resolved to positions once,
#' here (column view); an index that does not resolve exactly is an
#' error.
stat_source <- function(name, files, grid = NULL, transform = "identity") {
  stopifnot(is.character(name), nchar(name) > 0,
            all(c("date", "dsn") %in% names(files)),
            transform %in% names(grist_transforms))
  files <- as.data.frame(files)
  shape <- if (all(c("array", "index") %in% names(files))) "mdim" else "classic"

  if (shape == "classic") {
    if (!"band" %in% names(files)) files$band <- 1L
    files <- files[c("date", "dsn", "band")]
    if (!is_full_grid(grid)) grid <- utils::modifyList(grid_from_dsn(files$dsn[1], files$band[1]), as.list(grid))
  } else {
    files <- files[c("date", "dsn", "array", "index")]
    files$view <- resolve_views(files)
    files$band <- 1L
    if (!is_full_grid(grid)) grid <- utils::modifyList(grid_from_mdim(files$dsn[1], files$array[1], files$view[1]), as.list(grid))
  }
  stopifnot(length(grid$dimension) == 2L, length(grid$extent) == 4L)
  grid$projection <- as_wkt(grid$projection)
  grid$projected <- is_projected(grid$projection)
  list(name = name, files = files, grid = grid, transform = transform,
       shape = shape)
}

is_full_grid <- function(grid) {
  !is.null(grid) && all(c("dimension", "extent") %in% names(grid))
}

#' A CRS as WKT: WKT is kept, an authority code or PROJ string is
#' expanded (needs gdalraster), empty stays empty.
as_wkt <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x) || !nzchar(x)) return("")
  if (grepl("^\\s*(PROJ|GEOG|GEOD|COMPOUND|BOUND|VERT|ENGCRS|GEOCCS)", x, perl = TRUE)) return(x)
  need_gdalraster()
  gdalraster::srs_to_wkt(x)
}

#' TRUE for a projected CRS (WKT), FALSE for geographic or none.
is_projected <- function(wkt) {
  !is.null(wkt) && length(wkt) == 1L && !is.na(wkt) &&
    grepl("^\\s*PROJ(CRS|CS|ECTEDCRS)\\b", wkt, perl = TRUE)
}

#' Value transforms applied to each pixel before it is summed.
#'
#' Named, not arbitrary functions, so a sums file can record which one
#' it was computed with (Parquet metadata grist_transform). A source's
#' transform is part of what its sums mean: changing it is a new source
#' (a new name), not a recompute. Values the transform makes non-finite
#' (log10 of zero or a negative) are dropped like any NA pixel.
#'
#' identity  the value as read
#' log10     for lognormal quantities such as chlorophyll-a: sums of
#'           log10(x) and its square give geometric means and log-space
#'           variances
#' unit_interval  a fraction in [0, 1] (sea ice concentration as stored
#'           by the NSIDC CDR); anything outside, such as the CDR's flag
#'           values (pole hole, land, coast, lake, missing: 2.51..2.55
#'           after scaling), is dropped
#' percent_unit  a percentage in [0, 100] (e.g. Bremen ASI) as a fraction
#'           in [0, 1]; anything outside is dropped
grist_transforms <- list(
  identity = function(v) v,
  log10 = function(v) suppressWarnings(log10(v)),
  unit_interval = function(v) { v[!is.na(v) & (v < 0 | v > 1)] <- NA; v },
  percent_unit = function(v) { v[!is.na(v) & (v < 0 | v > 100)] <- NA; v / 100 }
)

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
