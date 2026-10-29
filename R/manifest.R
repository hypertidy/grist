## Bucket-truth manifest: run by the backfill job AFTER the sums push,
## then copied to the bucket root, so manifest.json always describes
## what the bucket actually holds, written by the machine that wrote
## it. Host-repo status pages fetch it live and contrast it with their
## own baked state.

write_manifest <- function(root = ".") {
  one <- function(p) {
    f <- list.files(p, "\\.parquet$", full.names = TRUE)
    if (!length(f)) return(NULL)
    d <- sort(as.Date(gsub("\\.parquet$", "", basename(f))))
    info <- file.info(f)
    list(n = length(f),
         first = format(min(d)), last = format(max(d)),
         gaps = length(setdiff(seq(min(d), max(d), by = "1 day"), d)),
         bytes = sum(info$size),
         newest_write = format(max(info$mtime), "%Y-%m-%dT%H:%M:%SZ",
                               tz = "UTC"))
  }
  srcs <- list.dirs(file.path(root, "sums"), recursive = FALSE)
  m <- list(
    generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    host = Sys.info()[["nodename"]],
    gdal = tryCatch(vapour::vapour_gdal_version(), error = function(e) NA),
    sums = setNames(lapply(srcs, one), basename(srcs)))
  m$sums <- m$sums[!vapply(m$sums, is.null, TRUE)]
  jsonlite::write_json(m, file.path(root, "manifest.json"),
                       auto_unbox = TRUE, pretty = TRUE, na = "null")
  message(sprintf("manifest.json: %s",
                  paste(sprintf("%s %i dates to %s", names(m$sums),
                                vapply(m$sums, `[[`, 0L, "n"),
                                vapply(m$sums, `[[`, "", "last")),
                        collapse = "; ")))
  invisible(m)
}
