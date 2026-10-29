## Daily accumulation: read band rows, grouped sums, one parquet per
## date. Schema per row: cell (token), date, n, sumw, sumwx, sumwx2.
## Sums are associative: any union of cells over any dates aggregates
## exactly downstream. NA pixels contribute nothing (fin guard), so the
## dense mapping is correct without any culling.

accumulate_date <- function(dsn, date, source, registry, band = 1L,
                            mapping_path = file.path("mapping", source$name),
                            out_path = file.path("sums", source$name)) {
  dir.create(out_path, recursive = TRUE, showWarnings = FALSE)
  out <- file.path(out_path, sprintf("%s.parquet", format(as.Date(date))))
  if (file.exists(out)) return(invisible(out))

  meta <- check_mapping(source, mapping_path)
  nreg <- nrow(registry)
  acc <- matrix(0, nreg, 4L,
                dimnames = list(NULL, c("n", "sumw", "sumwx", "sumwx2")))

  vapour::vapour_set_config("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  ## a hung network read must become a caught error, never a stalled
  ## worker: two multi-hour whole-job stalls in the reference deployment
  ## (trend.sst) traced to reads with no timeout (2026-08 at 92 workers,
  ## 2026-10 at 42)
  vapour::vapour_set_config("GDAL_HTTP_CONNECTTIMEOUT", "30")
  vapour::vapour_set_config("GDAL_HTTP_TIMEOUT", "120")
  vapour::vapour_set_config("GDAL_HTTP_MAX_RETRY", "3")
  vapour::vapour_set_config("GDAL_HTTP_RETRY_DELAY", "5")
  for (b in seq_len(meta$n_bands)) {
    m <- readRDS(file.path(mapping_path, sprintf("band_%04i.rds", b)))
    v <- read_rows(dsn, m$rows, source$grid, band = band)
    stopifnot(length(v) == length(m$idx))
    fin <- is.finite(v)
    x <- ifelse(fin, v, 0)
    s <- rowsum(cbind(as.double(fin), m$w * fin, m$w * x, m$w * x * x),
                m$idx)
    ii <- as.integer(rownames(s))
    acc[ii, ] <- acc[ii, ] + s
  }

  touched <- acc[, "n"] > 0
  d <- data.frame(cell = registry$cell[touched],
                  date = as.Date(date),
                  n = acc[touched, "n"],
                  sumw = acc[touched, "sumw"],
                  sumwx = acc[touched, "sumwx"],
                  sumwx2 = acc[touched, "sumwx2"])
  ## registry is token-sorted so d already is; atomic write
  tmp <- tempfile(tmpdir = out_path, fileext = ".tmp")
  arrow::write_parquet(d, tmp)
  file.rename(tmp, out)
  invisible(out)
}
