## Execution: the unit of work is a PLAN -- a table of tasks, one per
## date still to do -- and executors are interchangeable consumers of
## it. The filesystem is the resume state (file-per-date, atomic
## writes), never the scheduler: a plan can be run serially, by mirai
## daemons, split across a SLURM array, or written to parquet and
## consumed by any external runtime. Re-planning after any partial run
## yields exactly the remaining work.

#' The source recorded in a sums file -- dsn and band (classic) or dsn,
#' array and index (mdim) -- or NA when the file predates provenance
#' recording or can't be read. Compared with source_key().
recorded_source <- function(f) {
  tryCatch({
    m <- arrow::ParquetFileReader$create(f)$GetSchema()$metadata
    if (is.null(m$grist_dsn)) NA_character_
    else if (!is.null(m$grist_array))
      paste(m$grist_dsn, m$grist_array, m$grist_index, sep = "\r")
    else paste(m$grist_dsn, m$grist_band %||% "1", sep = "\r")
  }, error = function(e) NA_character_)
}

#' What each catalog row reads, as recorded in sums provenance. For the
#' mdim shape the index VALUE is the identity, never the resolved
#' position (positions shift when a store is rebuilt).
source_key <- function(files) {
  if (all(c("array", "index") %in% names(files)))
    paste(files$dsn, files$array, files$index, sep = "\r")
  else paste(files$dsn, files$band, sep = "\r")
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' The remaining work for a source: date, dsn, band, out, reason.
#'
#' A date is to do when its sums file is missing, or (changed = TRUE)
#' when the file records a different source than the catalog now gives
#' for that date -- e.g. the catalog switched it from a near-real-time
#' product to delayed-time, or from a provisional file to its final
#' version. Files written before provenance was recorded are trusted.
plan_dates <- function(source, out_path = file.path("sums", source$name),
                       changed = TRUE) {
  files <- source$files
  out <- file.path(out_path,
                   sprintf("%s.parquet", format(as.Date(files$date))))
  have <- file.exists(out)
  reason <- ifelse(have, "", "missing")
  if (changed && any(have)) {
    want <- source_key(files)
    rec <- vapply(out[have], recorded_source, "", USE.NAMES = FALSE)
    stale <- !is.na(rec) & rec != want[have]
    reason[which(have)[stale]] <- "changed"
  }
  todo <- nzchar(reason)
  pl <- data.frame(date = as.Date(files$date), dsn = files$dsn,
                   band = files$band, out = out, reason = reason)
  if (!is.null(files$view)) {
    pl$array <- files$array; pl$index <- files$index; pl$view <- files$view
  } else {
    pl$array <- NA_character_; pl$index <- NA_character_; pl$view <- NA_character_
  }
  pl[todo, ]
}

#' A source with an empty catalog (same columns), for shipping to
#' workers that are always given their row explicitly.
slim_source <- function(source) {
  source$files <- source$files[0L, , drop = FALSE]
  source
}

#' Run a plan: serial, or parallel via mirai when workers > 1.
#' Failures write nothing and are reported, never fatal; rerun to
#' continue. Returns the plan it ran (invisibly).
#'
#' chunk (optional): run the plan in pieces of at most this many dates,
#' with fresh workers for each piece (daemons started and stopped per
#' chunk). Bounds per-process memory growth in the read path: the first
#' full sea ice backfill (trend.ice, mdim reads over remote netCDF) grew
#' steadily per date until OOM; recycling every 1000 dates kept it flat.
#' NULL (default) runs the whole plan with one set of workers.
backfill <- function(source, registry, workers = 1L,
                     mapping_path = file.path("mapping", source$name),
                     out_path = file.path("sums", source$name),
                     chunk = NULL) {
  if (!is.null(chunk)) {
    chunk <- as.integer(chunk)
    stopifnot(length(chunk) == 1L, !is.na(chunk), chunk > 0L)
  }
  pl <- plan_dates(source, out_path)
  message(sprintf("[%s] %i of %i dates to do (%i missing, %i source changed; %i workers%s)",
                  source$name, nrow(pl), nrow(source$files),
                  sum(pl$reason == "missing"), sum(pl$reason == "changed"),
                  workers,
                  if (is.null(chunk)) "" else sprintf(", chunks of %i", chunk)))
  if (nrow(pl) == 0) return(invisible(pl))
  pieces <- if (is.null(chunk)) list(seq_len(nrow(pl))) else
    split(seq_len(nrow(pl)), ceiling(seq_len(nrow(pl)) / chunk))

  do_one <- function(dsn, date, band, array, index, view, source, registry,
                     mapping_path, out_path) {
    na2null <- function(x) if (is.na(x)) NULL else x
    res <- try(accumulate_date(dsn, date, source, registry, band = band,
                               overwrite = TRUE,
                               mapping_path = mapping_path,
                               out_path = out_path,
                               array = na2null(array), index = na2null(index),
                               view = na2null(view)), silent = TRUE)
    if (inherits(res, "try-error")) message(sprintf("FAIL %s", format(date)))
    invisible(NULL)
  }

  ## workers get the source WITHOUT its catalog: each task is handed its
  ## own row (dsn, date, band / array, index, view), and the catalog rides
  ## along in .args of every queued task -- a 17531-row mdim catalog is a
  ## few MB, times every queued task, held by the host (an OOM at 96 GB in
  ## the first sea ice backfill; one worker itself is flat at ~350 MB)
  source <- slim_source(source)
  if (workers > 1L) on.exit(mirai::daemons(0), add = TRUE)
  for (k in seq_along(pieces)) {
    pk <- pl[pieces[[k]], , drop = FALSE]
    if (length(pieces) > 1L)
      message(sprintf("[%s] chunk %i / %i (%i dates)", source$name, k,
                      length(pieces), nrow(pk)))
    if (workers > 1L) {
      mirai::daemons(workers)
      mirai::everywhere(library(grist))
      res <- mirai::mirai_map(pk[c("dsn", "date", "band", "array", "index", "view")], do_one,
        .args = list(source = source, registry = registry,
                     mapping_path = mapping_path,
                     out_path = out_path))[mirai::.progress]
      mirai::daemons(0)
    } else {
      for (i in seq_len(nrow(pk))) {
        do_one(pk$dsn[i], pk$date[i], pk$band[i], pk$array[i], pk$index[i],
               pk$view[i], source, registry, mapping_path, out_path)
        if (i %% 500 == 0) message(sprintf("%i / %i", i, nrow(pk)))
      }
    }
    gc()
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
