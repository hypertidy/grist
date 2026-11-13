## The mdim catalog shape: rows of (date, dsn, array, index), read through
## the GDAL multidimensional API (gdalraster). index gives a coordinate
## VALUE for every non-spatial dimension ("time=1978-10-25", several
## separated by commas); values are resolved to positions against each
## dimension's indexing variable ONCE per (dsn, array) when the source is
## constructed, so rows stay valid when a store is rebuilt or extended.
## Exact match or error: no match, or more than one, is never a guess.
##
## The two dimensions not named in index are the spatial ones, in array
## order (y then x, the usual layout). The classic view's geotransform
## decides orientation: a store with increasing y (south-up) is read
## bottom-up so that row 1 is always the top of the grid.

need_gdalraster <- function() {
  if (!requireNamespace("gdalraster", quietly = TRUE))
    stop("the mdim catalog shape needs the gdalraster package", call. = FALSE)
}

#' Parse "a=1,b=x" into a named character vector.
parse_index <- function(index) {
  parts <- strsplit(index, ",", fixed = TRUE)[[1]]
  kv <- strsplit(parts, "=", fixed = TRUE)
  ok <- vapply(kv, length, 0L) == 2L
  if (!all(ok)) stop(sprintf("malformed index '%s' (want dim=value[,dim=value])", index),
                     call. = FALSE)
  stats::setNames(trimws(vapply(kv, `[`, "", 2L)), trimws(vapply(kv, `[`, "", 1L)))
}

#' Decode CF-style time values ("days since 1978-01-01") to Date.
cf_dates <- function(values, units) {
  m <- regmatches(units, regexec("^\\s*(\\w+)\\s+since\\s+(.+)$", units))[[1]]
  if (length(m) != 3L) stop(sprintf("not a CF time unit: '%s'", units), call. = FALSE)
  secs <- c(seconds = 1, second = 1, s = 1, minutes = 60, minute = 60,
            hours = 3600, hour = 3600, h = 3600, days = 86400, day = 86400, d = 86400)
  f <- secs[[tolower(m[2])]]
  if (is.null(f)) stop(sprintf("unsupported time step '%s'", m[2]), call. = FALSE)
  origin <- as.POSIXct(sub("Z$", "", sub("T", " ", m[3])), tz = "UTC",
                       tryFormats = c("%Y-%m-%d %H:%M:%OS", "%Y-%m-%d %H:%M", "%Y-%m-%d"))
  as.Date(origin + as.numeric(values) * f, tz = "UTC")
}

#' Position (0-based) of each wanted value in a coordinate, exact or error.
#' Dates match at day resolution; numbers within relative tolerance 1e-6.
match_coord <- function(wanted, coord, dim) {
  vapply(wanted, function(w) {
    if (inherits(coord, "Date")) {
      hit <- which(coord == as.Date(w))
    } else {
      wv <- as.numeric(w)
      hit <- which(abs(coord - wv) <= 1e-6 * pmax(abs(wv), 1e-12))
    }
    if (length(hit) != 1L)
      stop(sprintf("index %s=%s matches %i coordinate values (want exactly 1)",
                   dim, w, length(hit)), call. = FALSE)
    hit - 1L
  }, 0L, USE.NAMES = FALSE)
}

mdim_json <- function(dsn, array, detailed = FALSE) {
  need_gdalraster()
  jsonlite::fromJSON(gdalraster::mdim_info(dsn, array_name = array, detailed = detailed,
                                           pretty = FALSE, cout = FALSE),
                     simplifyVector = TRUE)
}

#' The coordinate values of a dimension (Date for CF time), from its
#' indexing variable (an array of the same name).
mdim_coord <- function(dsn, dim) {
  j <- mdim_json(dsn, dim, detailed = TRUE)
  v <- unlist(j$values)
  if (is.null(v)) stop(sprintf("no values for coordinate '%s' in %s", dim, dsn), call. = FALSE)
  u <- j$unit %||% (j$attributes$units %||% "")
  if (is.list(u) || length(u) > 1) u <- as.character(unlist(u))[1]
  if (grepl("since", u)) cf_dates(v, u) else as.numeric(v)
}

#' Dimension names (no group path) of an array, in array order.
mdim_dims <- function(dsn, array) {
  dims_from_json(mdim_json(dsn, array)$dimensions)
}

#' The dimensions entry of gdalmdiminfo JSON is either full names
#' ("/time", ...) or, as gdalraster returns it, a table of objects with
#' name, full_name, size, type: names in array order either way.
dims_from_json <- function(d) {
  if (is.data.frame(d)) d <- if (!is.null(d$name)) d$name else d$full_name
  else if (is.list(d)) d <- vapply(d, function(x)
    if (is.list(x)) (x$name %||% x$full_name) else as.character(x), "")
  sub(".*/", "", as.character(d))
}

#' Resolve every catalog row's index to a view expression, once per
#' (dsn, array). Returns the view column, e.g. "[1234,:,:]".
resolve_views <- function(files, coord = mdim_coord, dims = mdim_dims) {
  key <- paste(files$dsn, files$array, sep = "\r")
  out <- character(nrow(files))
  for (k in unique(key)) {
    i <- which(key == k)
    dsn <- files$dsn[i[1]]; arr <- files$array[i[1]]
    dn <- dims(dsn, arr)
    idx <- lapply(files$index[i], parse_index)
    named <- unique(unlist(lapply(idx, names)))
    bad <- setdiff(named, dn)
    if (length(bad)) stop(sprintf("index names %s not dimensions of %s (%s)",
                                  paste(bad, collapse = ","), arr,
                                  paste(dn, collapse = ",")), call. = FALSE)
    if (length(setdiff(dn, named)) != 2L)
      stop(sprintf("array %s: index must fix all but two dimensions (has %s, fixes %s)",
                   arr, paste(dn, collapse = ","), paste(named, collapse = ",")),
           call. = FALSE)
    pos <- matrix(NA_integer_, length(i), length(dn), dimnames = list(NULL, dn))
    for (d in named) {
      cv <- coord(dsn, d)
      pos[, d] <- match_coord(vapply(idx, function(x) x[[d]], ""), cv, d)
    }
    out[i] <- apply(pos, 1L, function(p)
      sprintf("[%s]", paste(ifelse(is.na(p), ":", p), collapse = ",")))
  }
  out
}

#' Open one catalog row as a 2D classic view (y, x).
mdim_open <- function(dsn, array, view) {
  need_gdalraster()
  gdalraster::mdim_as_classic(dsn, array, idx_xdim = 1L, idx_ydim = 0L,
                              view_expr = view)
}

#' Grid signature of an mdim row: dimension, extent, projection, and
#' whether storage is bottom-up (positive geotransform y step).
grid_from_mdim <- function(dsn, array, view) {
  ds <- mdim_open(dsn, array, view)
  on.exit(ds$close())
  gt <- ds$getGeoTransform()
  dm <- as.integer(ds$dim()[1:2])
  bb <- ds$bbox()
  list(dimension = dm, extent = c(bb[1], bb[3], bb[2], bb[4]),
       projection = ds$getProjection(), flip_y = gt[6] > 0)
}

#' Read rows (row 1 = top of the grid) of an open mdim view (mdim_open()), scaled and with
#' nodata as NA. A bottom-up store is read from the matching rows and
#' reversed, so the result is always top-down row-major like read_rows().
read_rows_mdim <- function(ds, rows, grid) {
  dm <- grid$dimension
  nr <- length(rows)
  flip <- isTRUE(grid$flip_y)
  yoff <- if (flip) dm[2] - max(rows) else min(rows) - 1L
  v <- ds$read(band = 1L, xoff = 0L, yoff = yoff, xsize = dm[1], ysize = nr,
               out_xsize = dm[1], out_ysize = nr)
  nd <- ds$getNoDataValue(1L)
  if (!is.na(nd)) v[v == nd] <- NA
  sc <- ds$getScale(1L); of <- ds$getOffset(1L)
  if (!is.na(sc) && sc != 1) v <- v * sc
  if (!is.na(of) && of != 0) v <- v + of
  if (flip) {
    m <- matrix(v, dm[1], nr)
    v <- as.vector(m[, nr:1, drop = FALSE])
  }
  v
}
