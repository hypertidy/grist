## Dense pixel -> registry-index mapping for a source's native grid.
## One file per latitude band: rows, idx (int index into registry), w
## (cos-lat weight). Position in the band read IS pixel identity; no
## pixel ids are stored. A metadata stamp records the grid signature so
## the daily job can refuse a mismatched mapping.

build_mapping <- function(source, registry, band_rows = 512L,
                          path = file.path("mapping", source$name)) {
  dm <- source$grid$dimension
  ex <- source$grid$extent
  level <- registry$level[1]
  dir.create(path, recursive = TRUE, showWarnings = FALSE)

  lons <- vaster::x_from_col(dm, 1:dm[1], extent = ex)
  ## s2 wants -180..180; OISST is 0..360
  lons <- ifelse(lons > 180, lons - 360, lons)
  lats <- vaster::y_from_row(dm, 1:dm[2], extent = ex)

  bands <- split(1:dm[2], ceiling(seq_len(dm[2]) / band_rows))
  for (b in seq_along(bands)) {
    rows <- bands[[b]]
    tok <- unlist(lapply(rows, function(r) {
      as.character(s2::s2_cell_parent(
        s2::as_s2_cell(s2::s2_geog_point(lons, rep(lats[r], dm[1]))), level))
    }))
    idx <- match(tok, registry$cell)
    stopifnot(!anyNA(idx))
    w <- rep(cos(lats[rows] * pi / 180), each = dm[1])
    saveRDS(list(rows = rows, idx = idx, w = w),
            file.path(path, sprintf("band_%04i.rds", b)), compress = FALSE)
    message(sprintf("[%s] band %i / %i", source$name, b, length(bands)))
  }

  meta <- list(source = source$name, level = level,
               dimension = dm, extent = ex, band_rows = band_rows,
               n_bands = length(bands), built = format(Sys.time(), tz = "UTC"))
  saveRDS(meta, file.path(path, "meta.rds"))
  invisible(meta)
}

check_mapping <- function(source, path = file.path("mapping", source$name)) {
  meta <- readRDS(file.path(path, "meta.rds"))
  stopifnot(identical(meta$dimension, source$grid$dimension),
            isTRUE(all.equal(meta$extent, source$grid$extent)))
  meta
}
