# grist

Mergeable sufficient statistics on S2 cells from daily grids. This is
the engine extracted from [trend.sst](https://github.com/mdsumner/trend.sst),
which remains the reference deployment; this package is the invariant
middle that new deployments (sea level anomaly, ice, ocean colour, ...)
share, while each host repository owns its own product knowledge:
catalogs, schedules, buckets, baselines, regions, and site.

## The model

Every source is summarized onto the same discrete global grid: S2
cells at a chosen level (level 5 in the reference deployment). For
each cell, each day, four numbers are accumulated over the
contributing pixels: count `n`, summed spherical-area weight `sumw`,
and the weighted sums `sumwx` and `sumwx2` of the value and its
square. One Parquet file per date; failures write nothing; reruns
continue.

    mean     = sumwx / sumw
    variance = sumwx2 / sumw - mean^2

The sums are mergeable: statistics of any union of cells, days, or
both come from adding rows first and taking the ratio once. A region
is a cell selection, not a new computation. The design has deep prior
art in NASA ocean colour's L3bin scheme (weighted sums and sums of
squares per equal-area bin, since SeaWiFS 1997); see the
[restored binning-scheme page](https://hypertidy.github.io/L3bin/articles/l3bins.html).

## The contract

A source is a name, a catalog, a grid and (optionally) a transform:

    stat_source(name, files, grid = NULL, transform = "identity")

- `name`: the slug that keys `mapping/<name>/` and `sums/<name>/`
- `files`: a catalog, one row per date (see "Catalog contract" below).
- `grid`: the native grid signature (dimension, extent), stamped from
  the first catalog entry unless supplied. Supply it explicitly when a
  driver does not report a correct extent.
- `transform` (optional, default `"identity"`): a named value transform
  applied before summing, from `grist_transforms`. `"log10"` is for
  lognormal quantities such as chlorophyll-a: the sums are then of
  log10(x), so cell means are geometric means. `"unit_interval"` keeps
  fractions in [0, 1] and drops everything else (the NSIDC CDR's flag
  values); `"percent_unit"` takes a percentage in [0, 100] to a fraction. Each sums file records
  its transform (Parquet metadata `grist_transform`); a different
  transform is a different source, with its own name.

The grid signature is the contract between the mapping and the daily
reads: `accumulate_date()` refuses to run against a mismatched
mapping. Pixels are never warped or resampled; each is assigned whole
to the cell containing its centre, by a dense positional mapping built
once per grid.

## Catalog contract

The catalog is the boundary between grist and whatever provides the
data. grist does not list files, reformat bytes, or build indexes: it
reads catalogs that providers emit, as one more output alongside VRT,
Icechunk, kerchunk or STAC. One row selects exactly one 2D field for
one date. A row has one of two shapes, distinguished by which columns
are present:

| shape | columns | read through | use for |
|---|---|---|---|
| classic | `date`, `dsn`, `band` (optional, default 1) | GDAL classic raster API | one file per date (COG, netCDF via `vrt://`), or a classic view with the band selected in the dsn |
| mdim | `date`, `dsn`, `array`, `index` | GDAL multidimensional API | a multidimensional VRT over source files (e.g. written by `gdal mdim mosaic`), or a Zarr store: open `array`, slice by `index`, read 2D |

- `date`: the date the field represents (Date or ISO string).
- `dsn`: a GDAL data source name. Any recipe GDAL can open is valid.
- `band` (classic): 1-based band index.
- `array` (mdim): the array name within the dataset, e.g. `temp`.
- `index` (mdim): a coordinate VALUE for every non-spatial dimension,
  as `dim=value` pairs separated by commas, e.g.
  `time=2005-01-01,st_ocean=2.5`. grist resolves each value to a
  position against the dimension's indexing variable when it opens the
  array, so rows stay valid when a store is rebuilt or extended and its
  positions shift. Time values are ISO dates matched at day resolution
  against the decoded time axis; numeric values match the coordinate
  within a relative tolerance of 1e-6. No match, or more than one, is an
  error, never a guess. Integer positions are deliberately not part of
  the contract: a position is only true for one build of a store. The
  two remaining dimensions must be the spatial ones.

Rules:

- Each row must resolve to a single 2D field on the source's grid
  signature; selecting depth, ensemble member or variable is the
  catalog's job, not grist's.
- A classic dsn that exposes thousands of bands (a time-as-bands view
  of an array store) is pathological through the warp path: band
  labelling on every open and per-process block caches. Select the band
  inside the dsn (`vrt://<dsn>?bands=i`, then `band = 1`) or use the
  mdim shape. The mdim shape is the general route for array stores;
  `vrt://?bands=` is a workaround for classic stacks.
- At scale, set per-worker GDAL limits: `GDAL_CACHEMAX=256` (the default
  is a share of node memory per process),
  `GDAL_LOAD_EXTRA_DIM_METADATA_DELAY=0`, `GDAL_PAM_ENABLED=NO`, and
  workers equal to allocated CPUs.

The mdim shape is read with gdalraster (`mdim_info()` to resolve index
values once per (dsn, array) at `stat_source()` time, `mdim_as_classic()`
with a view expression for each date). The values are scaled by the
array's scale/offset and its nodata becomes NA before any transform, and
a store with increasing y (south-up) is read so that row 1 is always the
top of the grid. Provenance for an mdim row is (dsn, array, index VALUE),
never the resolved position. First users: the NSIDC CDR and Bremen ASI
sea ice concentration indexes (grist catalogs published beside each
index on source.coop).

## Grids: geographic and projected

The mapping assigns each pixel whole to the cell containing its centre.

- Geographic (lon/lat) grids: weight cos(latitude), a relative area, as
  in the reference deployment.
- Projected grids (e.g. polar stereographic): pixel centres are taken to
  lon/lat with the grid's CRS and the weight is the pixel's area on the
  sphere in km2 (s2 area of its four corners). sumw is then covered
  area, and for a concentration sumwx is the area it implies (sea ice
  area, km2). Needs gdalraster for the transform.

The weight kind is recorded in the mapping's metadata (`coslat` or
`area_km2`). Means are unaffected by the unit; sums of sumw across sources
with different weight kinds are not comparable.

## Onboarding ritual for a NEW source

Non-negotiable, in order, before any backfill:

1. `stat_source()` and inspect the stamped grid (dimension, extent,
   axis direction) against the product documentation.
2. `build_registry(level)`; `build_mapping(source, registry)`.
3. Oracle date: `accumulate_date()` one date, then (a) map the cell
   means and LOOK at them (land where land should be, no hemisphere
   flip, no lon wrap error), and (b) verify one regional mean against
   an independently computed value from the same file.
4. Only then `backfill()`.

Array-store sources are exactly where a silent latitude flip or axis
transpose would live; the ritual is the guard.

## Execution: plans, not processes

The unit of work is a plan -- `plan_dates(source)` returns a table of
(date, dsn, band, out) for the dates still to do -- and executors are
interchangeable consumers of it. `backfill()` runs a plan serially or
via mirai daemons; a plan written to Parquet can equally drive a SLURM
array or any external runtime in any language. The filesystem is the
resume state (file-per-date, atomic writes), never the scheduler:
re-planning after any partial run yields exactly the remaining work.

Each sums file records the source it was computed from (`dsn` and
`band`, in the Parquet key-value metadata). `plan_dates()` treats a
date as still to do when its file is missing OR when the catalog now
gives a different source for that date. So a catalog that interleaves
a near-real-time product with delayed-time data, or provisional files
with their final versions, gets exactly the handed-over dates
recomputed on the next run, with no manual deletion of trailing days.
Files written before provenance was recorded are trusted as they are.

## What host repositories own

- the source constructor and catalog build (product knowledge)
- deployment: batch scripts, object-store destination, `write_manifest()`
  called after each push so the bucket describes itself
- analysis conventions: baselines, regions, variables
- presentation: status/explorer/method pages
- validation choices: which oracles, which tolerances

## Acknowledgments

This work uses resources of the Pawsey Supercomputing Research Centre,
with funding from the Australian Government and the Government of
Western Australia. The reference deployment (trend.sst) was developed
and runs on Pawsey systems, and its derived data are served from
Pawsey object storage.
