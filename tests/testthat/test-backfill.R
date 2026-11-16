## backfill(chunk =): the serial path with accumulate_date stubbed, so no
## reads happen; checks every date is attempted exactly once, in order,
## with and without chunking, and that a bad chunk is rejected.

test_that("chunked and unchunked backfill attempt every date once", {
  skip_if_not_installed("arrow")
  files <- data.frame(date = as.Date("2020-01-01") + 0:6,
                      dsn = sprintf("f%i", 1:7), band = 1L)
  src <- list(name = "stub", files = files, grid = list(), transform = "identity",
              shape = "classic")
  for (ch in list(NULL, 3L, 100L)) {
    seen <- character()
    local_mocked_bindings(accumulate_date = function(dsn, date, ...) {
      seen <<- c(seen, format(as.Date(date))); invisible(NULL)
    })
    out <- tempfile()
    suppressMessages(backfill(src, registry = NULL, workers = 1L, chunk = ch,
                              out_path = out))
    expect_equal(seen, format(files$date))
  }
})

test_that("chunk must be a positive integer", {
  src <- list(name = "stub", files = data.frame(date = Sys.Date(), dsn = "f", band = 1L))
  expect_error(backfill(src, registry = NULL, chunk = 0L))
  expect_error(backfill(src, registry = NULL, chunk = NA))
})
