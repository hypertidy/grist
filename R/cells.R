## S2 cell universe, registry, and region selection.
## Cell ids live as character tokens at the R boundary, always: bare
## s2_cell doubles must never be grouped, matched, or sorted (NaN-payload
## ids collapse under base double semantics).

#' All S2 cells at a level, by exact child recursion from the 6 faces.
s2_cells_at_level <- function(level) {
  faces <- s2::s2_cell_parent(s2::as_s2_cell(
    s2::s2_geog_point(c(0, 90, 0, 180, -90, 0),
                      c(0, 0, 90, 0, 0, -90))), 0L)
  cells <- faces
  for (l in seq_len(level)) {
    cells <- c(s2::s2_cell_child(cells, 0L), s2::s2_cell_child(cells, 1L),
               s2::s2_cell_child(cells, 2L), s2::s2_cell_child(cells, 3L))
  }
  stopifnot(length(as.character(cells)) == 6L * 4L^level,
            !anyDuplicated(as.character(cells)))
  cells
}

#' Full-universe registry at a level: every cell, sorted by token.
#' Tokens at a single level share a length, so character sort == id sort.
build_registry <- function(level = 5L) {
  cells <- s2_cells_at_level(level)
  tok <- sort(as.character(cells))
  cells <- s2::s2_cell(tok)
  cen <- s2::s2_cell_center(cells)
  data.frame(cell = tok,
             lon = s2::s2_x(cen), lat = s2::s2_y(cen),
             area_km2 = s2::s2_cell_area_approx(cells) / 1e6,
             level = level)
}

#' Cells whose center lies in a latitude band (e.g. -60, 60).
cells_latband <- function(registry, lat_min, lat_max) {
  registry$cell[registry$lat >= lat_min & registry$lat <= lat_max]
}

#' Cells at the registry level intersecting a geography (region polygon).
cells_covering <- function(registry, geog) {
  level <- registry$level[1]
  cov <- s2::s2_covering_cell_ids(geog, min_level = level,
                                  max_level = level, max_cells = 100000L)
  tok <- as.character(s2::s2_cell_union_normalize(cov)[[1]])
  tok[tok %in% registry$cell]
}
