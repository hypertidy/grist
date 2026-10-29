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

A source is three things:

    stat_source(name, files, grid = NULL)

- `name`: the slug that keys `mapping/<name>/` and `sums/<name>/`
- `files`: a catalog with columns `date`, `dsn`, and optionally `band`
  (default 1). This covers file-per-date collections (dsn varies) and
  array stores with time-as-bands (one dsn, band = time index), e.g.
  GDAL-readable Zarr with single-timestep chunks.
- `grid`: the native grid signature (dimension, extent), stamped from
  the first catalog entry unless supplied. Supply it explicitly when a
  driver does not report a correct extent.

The grid signature is the contract between the mapping and the daily
reads: `accumulate_date()` refuses to run against a mismatched
mapping. Pixels are never warped or resampled; each is assigned whole
to the cell containing its centre, by a dense positional mapping built
once per grid.

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
