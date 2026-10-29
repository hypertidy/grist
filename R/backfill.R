## Execution: the unit of work is a PLAN -- a table of tasks, one per
## date still to do -- and executors are interchangeable consumers of
## it. The filesystem is the resume state (file-per-date, atomic
## writes), never the scheduler: a plan can be run serially, by mirai
## daemons, split across a SLURM array, or written to parquet and
## consumed by any external runtime. Re-planning after any partial run
## yields exactly the remaining work.

#' The remaining work for a source: date, dsn, band, out.
plan_dates <- function(source, out_path = file.path("sums", source$name)) {
  files <- source$files
  out <- file.path(out_path,
                   sprintf("%s.parquet", format(as.Date(files$date))))
  todo <- !file.exists(out)
  data.frame(date = as.Date(files$date), dsn = files$dsn,
             band = files$band, out = out)[todo, ]
}

#' Run a plan: serial, or parallel via mirai when workers > 1.
#' Failures write nothing and are reported, never fatal; rerun to
#' continue. Returns the plan it ran (invisibly).
backfill <- function(source, registry, workers = 1L,
                     mapping_path = file.path("mapping", source$name),
                     out_path = file.path("sums", source$name)) {
  pl <- plan_dates(source, out_path)
  message(sprintf("[%s] %i of %i dates to do (%i workers)",
                  source$name, nrow(pl), nrow(source$files), workers))
  if (nrow(pl) == 0) return(invisible(pl))

  do_one <- function(dsn, date, band, source, registry,
                     mapping_path, out_path) {
    res <- try(accumulate_date(dsn, date, source, registry, band = band,
                               mapping_path = mapping_path,
                               out_path = out_path), silent = TRUE)
    if (inherits(res, "try-error")) message(sprintf("FAIL %s", format(date)))
    invisible(NULL)
  }

  if (workers > 1L) {
    mirai::daemons(workers)
    on.exit(mirai::daemons(0), add = TRUE)
    mirai::everywhere(library(grist))
    res <- mirai::mirai_map(pl[c("dsn", "date", "band")], do_one,
      .args = list(source = source, registry = registry,
                   mapping_path = mapping_path,
                   out_path = out_path))[mirai::.progress]
  } else {
    for (i in seq_len(nrow(pl))) {
      do_one(pl$dsn[i], pl$date[i], pl$band[i], source, registry,
             mapping_path, out_path)
      if (i %% 500 == 0) message(sprintf("%i / %i", i, nrow(pl)))
    }
  }

  ## pulse check: never fatal -- a backfill that completed must not be
  ## failed by its own diagnostics
  p <- try({
    s <- series_stats(out_path)
    message(sprintf("[%s] %i dates in sums; global mean %.2f .. %.2f",
                    source$name, nrow(s), min(s$mean), max(s$mean)))
  }, silent = TRUE)
  if (inherits(p, "try-error"))
    message("pulse check failed (non-fatal): ", attr(p, "condition")$message)
  invisible(pl)
}
