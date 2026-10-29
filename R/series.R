## Query layer: sums -> series. Every "regionalization" is a cell vector;
## every statistic is arithmetic on summed sufficient statistics.

#' Weighted mean (and variance) time series for a cell selection.
#' cells = NULL means all cells (the global series).
series_stats <- function(sums_path, cells = NULL) {
  ds <- arrow::open_dataset(sums_path)
  if (!is.null(cells)) ds <- dplyr::filter(ds, cell %in% cells)
  out <- ds |>
    dplyr::group_by(date) |>
    dplyr::summarise(n = sum(n), sumw = sum(sumw),
                     sumwx = sum(sumwx), sumwx2 = sum(sumwx2)) |>
    dplyr::collect() |>
    dplyr::arrange(date)
  out$mean <- out$sumwx / out$sumw
  out$var <- pmax(0, out$sumwx2 / out$sumw - out$mean^2)
  out
}

#' Per-cell climatology-and-anomaly scaffold: mean per (cell, doy-window)
#' left to the caller via the same sums; convenience for per-cell means
#' over a date range (e.g. a baseline period).
cell_means <- function(sums_path, dates = NULL) {
  ds <- arrow::open_dataset(sums_path)
  if (!is.null(dates)) {
    ds <- dplyr::filter(ds, date >= min(dates), date <= max(dates))
  }
  ds |>
    dplyr::group_by(cell) |>
    dplyr::summarise(sumw = sum(sumw), sumwx = sum(sumwx)) |>
    dplyr::collect() |>
    dplyr::mutate(mean = sumwx / sumw)
}
