## Dense pixel -> registry-index mapping for a source's native grid.
## One file per band of rows: rows, idx (int index into registry), w
## (pixel area weight). Position in the band read IS pixel identity; no
## pixel ids are stored. A metadata stamp records the grid signature so
## the daily job can refuse a mismatched mapping.
##
## Geographic grids (lon/lat): w = cos(lat), relative area, as in the
## reference deployment (unchanged).
## Projected grids (e.g. polar stereographic): pixel centres are taken to
## lon/lat with the grid's CRS, and w = the pixel's area on the sphere in
## km2 (s2 polygon of the four corners), so sumw is covered area and, for
## a concentration, sumwx is the area it implies (sea ice area).

build_mapping <- function(source, registry, band_rows = 512L,
                          path = file.path("mapping", source$name)) {
  dm <- source$grid$dimension
  ex <- source$grid$extent
  level <- registry$level[1]
  projected <- isTRUE(source$grid$projected)
  dir.create(path, recursive = TRUE, showWarnings = FALSE)

  xs <- vaster::x_from_col(dm, 1:dm[1], extent = ex)
  ys <- vaster::y_from_row(dm, 1:dm[2], extent = ex)
  if (!projected) {
    ## s2 wants -180..180; OISST is 0..360
    xs <- ifelse(xs > 180, xs - 360, xs)
  } else {
    need_gdalraster()
    resx <- (ex[2] - ex[1]) / dm[1]
    resy <- (ex[4] - ex[3]) / dm[2]
  }

  bands <- split(1:dm[2], ceiling(seq_len(dm[2]) / band_rows))
  for (b in seq_along(bands)) {
    rows <- bands[[b]]
    if (!projected) {
      lon <- rep(xs, length(rows)); lat <- rep(ys[rows], each = dm[1])
      w <- cos(lat * pi / 180)
    } else {
      px <- rep(xs, length(rows)); py <- rep(ys[rows], each = dm[1])
      ll <- to_lonlat(cbind(px, py), source$grid$projection)
      lon <- ll[, 1]; lat <- ll[, 2]
      w <- pixel_area_km2(px, py, resx, resy, source$grid$projection)
    }
    ok <- is.finite(lon) & is.finite(lat)
    tok <- rep(NA_character_, length(lon))
    tok[ok] <- as.character(s2::s2_cell_parent(
      s2::as_s2_cell(s2::s2_geog_point(lon[ok], lat[ok])), level))
    idx <- match(tok, registry$cell)
    stopifnot(!anyNA(idx[ok]))
    ## a pixel outside the CRS's valid area can never contribute
    if (any(!ok)) { idx[!ok] <- 1L; w[!ok] <- 0 }
    saveRDS(list(rows = rows, idx = idx, w = w),
            file.path(path, sprintf("band_%04i.rds", b)), compress = FALSE)
    message(sprintf("[%s] band %i / %i", source$name, b, length(bands)))
  }

  meta <- list(source = source$name, level = level,
               dimension = dm, extent = ex, band_rows = band_rows,
               n_bands = length(bands), projected = projected,
               weight = if (projected) "area_km2" else "coslat",
               built = format(Sys.time(), tz = "UTC"))
  saveRDS(meta, file.path(path, "meta.rds"))
  invisible(meta)
}

#' Projected x, y (matrix) to lon, lat (OGC:CRS84 is lon/lat order
#' whatever the axis-order setting).
to_lonlat <- function(xy, wkt) {
  gdalraster::transform_xy(xy, srs_from = wkt, srs_to = "OGC:CRS84")
}

#' Area (km2) on the sphere of projected pixels, from their four corners.
pixel_area_km2 <- function(px, py, resx, resy, wkt) {
  n <- length(px)
  hx <- resx / 2; hy <- resy / 2
  cx <- c(rbind(px - hx, px + hx, px + hx, px - hx))
  cy <- c(rbind(py - hy, py - hy, py + hy, py + hy))
  ll <- to_lonlat(cbind(cx, cy), wkt)
  a <- rep(NA_real_, n)
  ok <- rowSums(matrix(is.finite(ll[, 1]) & is.finite(ll[, 2]), n, 4L, byrow = TRUE)) == 4L
  if (any(ok)) {
    k <- rep(ok, each = 4L)
    poly <- s2::s2_make_polygon(ll[k, 1], ll[k, 2],
                                feature_id = rep(which(ok), each = 4L),
                                oriented = FALSE)
    a[ok] <- s2::s2_area(poly) / 1e6
  }
  a
}

check_mapping <- function(source, path = file.path("mapping", source$name)) {
  meta <- readRDS(file.path(path, "meta.rds"))
  stopifnot(identical(meta$dimension, source$grid$dimension),
            isTRUE(all.equal(meta$extent, source$grid$extent)))
  meta
}
