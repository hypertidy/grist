## mdim catalog shape and projected grids: the parts that need no GDAL
## multidim reads are tested here; the real read path is checked by each
## host repo's oracle date (README: onboarding ritual).

test_that("index strings parse, malformed ones fail", {
  expect_equal(parse_index("time=2005-01-01,st_ocean=2.5"),
               c(time = "2005-01-01", st_ocean = "2.5"))
  expect_error(parse_index("time"), "malformed")
})

test_that("CF time decodes at day resolution", {
  expect_equal(cf_dates(c(0, 1.5), "days since 1978-10-25"),
               as.Date(c("1978-10-25", "1978-10-26")))
  expect_equal(cf_dates(24 * 3, "hours since 1900-01-01 00:00:00"),
               as.Date("1900-01-04"))
  expect_equal(cf_dates(86400, "seconds since 1970-01-01T00:00:00Z"),
               as.Date("1970-01-02"))
  expect_error(cf_dates(1, "metres"), "CF time")
})

test_that("coordinate matching is exact or an error", {
  d <- as.Date("2000-01-01") + 0:9
  expect_equal(match_coord(c("2000-01-03", "2000-01-01"), d, "time"), c(2L, 0L))
  expect_error(match_coord("1999-12-31", d, "time"), "matches 0")
  expect_error(match_coord("2000-01-02", c(d, d[2]), "time"), "matches 2")
  z <- c(2.5, 7.5, 12.5000001)
  expect_equal(match_coord("12.5", z, "st_ocean"), 2L)
})

test_that("views resolve once per (dsn, array) and keep spatial dims open", {
  calls <- 0L
  coord <- function(dsn, dim) { calls <<- calls + 1L; as.Date("2020-01-01") + 0:4 }
  dims <- function(dsn, array) c("time", "y", "x")
  files <- data.frame(date = as.Date("2020-01-02") + 0:2, dsn = "a.vrt",
                      array = "conc", index = sprintf("time=%s", as.Date("2020-01-02") + 0:2))
  v <- resolve_views(files, coord = coord, dims = dims)
  expect_equal(v, c("[1,:,:]", "[2,:,:]", "[3,:,:]"))
  expect_equal(calls, 1L)
  files$index[2] <- "level=3"
  expect_error(resolve_views(files, coord = coord, dims = dims), "not dimensions")
  dims4 <- function(dsn, array) c("time", "depth", "y", "x")
  files$index[2] <- files$index[1]
  expect_error(resolve_views(files, coord = coord, dims = dims4), "all but two")
})

test_that("bottom-up storage reads as top-down rows, scaled, nodata NA", {
  ## a 3 x 4 grid stored bottom-up: storage row 1 is the SOUTHERN row
  stored <- matrix(c(1:12), 3, 4)            # x fastest, storage rows 1..4
  stored[2, 4] <- 255                         # nodata, in the top grid row
  fake <- list(
    read = function(band, xoff, yoff, xsize, ysize, out_xsize, out_ysize)
      as.vector(stored[, (yoff + 1):(yoff + ysize), drop = FALSE]),
    getNoDataValue = function(b) 255, getScale = function(b) 0.5,
    getOffset = function(b) 0)
  grid <- list(dimension = c(3L, 4L), flip_y = TRUE)
  top <- read_rows_mdim(fake, 1:2, grid)      # grid rows 1:2 = storage rows 4:3
  expect_equal(top, c(10, NA, 12, 7, 8, 9) * 0.5)
  grid$flip_y <- FALSE
  expect_equal(read_rows_mdim(fake, 1:2, grid), c(1:6) * 0.5)
})

test_that("provenance keys: mdim by index value, classic by band", {
  expect_equal(source_key(data.frame(dsn = "a", band = 2L)), "a\r2")
  f <- data.frame(dsn = "a", array = "z", index = "time=2020-01-01",
                  view = "[3,:,:]", band = 1L)
  expect_equal(source_key(f), "a\rz\rtime=2020-01-01")
})

test_that("sea ice transforms drop flags and out-of-range values", {
  expect_equal(grist_transforms$unit_interval(c(0, 0.15, 1, 2.51, -0.1, NA)),
               c(0, 0.15, 1, NA, NA, NA))
  expect_equal(grist_transforms$percent_unit(c(0, 15, 100, 120, NA)),
               c(0, 0.15, 1, NA, NA))
})

test_that("projected CRS detection", {
  expect_true(is_projected('PROJCRS["NSIDC Sea Ice Polar Stereographic South", BASEGEOGCRS[]]'))
  expect_true(is_projected('PROJCS["WGS 84 / Antarctic Polar Stereographic"]'))
  expect_false(is_projected('GEOGCRS["WGS 84"]'))
  expect_false(is_projected(""))
  expect_false(is_projected(NA_character_))
})

test_that("pixel areas on the sphere: NSIDC 25 km south polar grid", {
  skip_if_not_installed("sf")
  local_mocked_bindings(to_lonlat = function(xy, wkt)
    sf::sf_project(wkt, "OGC:CRS84", xy, keep = TRUE, warn = FALSE))
  wkt <- "EPSG:3412"
  ## true scale at 70S: a pixel there is ~625 km2; nearer the pole the
  ## projection enlarges less so the true area is larger than 625
  px <- c(0, 0); py <- c(-2200000, -500000)
  a <- pixel_area_km2(px, py, 25000, 25000, wkt)
  lat <- to_lonlat(cbind(px, py), wkt)[, 2]
  expect_true(abs(lat[1] + 70.2) < 0.5)
  expect_equal(a[1], 625, tolerance = 0.02)
  expect_gt(a[2], a[1])
  ## the full grid: total area within a few % of the sphere's area south
  ## of the grid's coverage is not testable cheaply, so test smoothness:
  ## a 3 x 3 neighbourhood varies by well under 1%
  g <- expand.grid(x = c(-25000, 0, 25000), y = c(-1000000, -975000, -950000))
  aa <- pixel_area_km2(g$x, g$y, 25000, 25000, wkt)
  expect_lt(diff(range(aa)) / mean(aa), 0.01)
})

test_that("dimension names from either JSON form", {
  tab <- data.frame(name = c("time", "y", "x"), full_name = c("/time", "/y", "/x"),
                    size = c(17531, 332, 316))
  expect_equal(dims_from_json(tab), c("time", "y", "x"))
  expect_equal(dims_from_json(c("/time", "/y", "/x")), c("time", "y", "x"))
  expect_equal(dims_from_json(list(list(name = "time"), list(name = "y"))), c("time", "y"))
})

test_that("partial grids override the stamp; WKT passes through", {
  expect_false(is_full_grid(NULL))
  expect_false(is_full_grid(list(projection = "EPSG:3412")))
  expect_true(is_full_grid(list(dimension = c(2L, 2L), extent = c(0, 1, 0, 1))))
  w <- 'PROJCRS["x"]'
  expect_identical(as_wkt(w), w)
  expect_identical(as_wkt(""), "")
  expect_identical(as_wkt(NA_character_), "")
})

test_that("workers get a slim source: same columns, no rows", {
  src <- list(name = "x", files = data.frame(date = Sys.Date() + 0:9, dsn = "a",
                                             array = "z", index = "i", view = "[0,:,:]"))
  sl <- slim_source(src)
  expect_equal(nrow(sl$files), 0L)
  expect_equal(names(sl$files), names(src$files))
  expect_lt(object.size(sl), object.size(src))
})
