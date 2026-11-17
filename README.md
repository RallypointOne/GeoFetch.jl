# GeoFetch

GeoFetch builds local [Zarr](https://zarr.dev) stores from remote weather and
geoscience datasets. You describe what you want as a small pipeline — a data
source, optional selections, and a destination — and GeoFetch downloads only the
pieces it needs and writes them into a single store with labelled dimensions.

```
Source | Select / Rechunk | Store
```

Building a pipeline does no I/O; `execute` is the one call that downloads and
writes.

[Documentation](https://rallypointone.github.io/GeoFetch.jl/)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/RallypointOne/GeoFetch.jl")
```

The registered v0.1.0 predates the pipeline API described here, so install from
the repository for now.

## Supported sources

| Preset  | Dataset                                                        | Access                                  | Auth |
|---------|----------------------------------------------------------------|-----------------------------------------|------|
| `OISST` | NOAA Optimum Interpolation SST v2.1, daily, 0.25° global       | NetCDF files over HTTPS (NCEI)          | none |
| `GFS`   | NOAA Global Forecast System forecasts, 0.25° / 0.5° / 1° global | GRIB2 messages by byte range (AWS)      | none |
| `IFS`   | ECMWF IFS deterministic forecasts, 0.25° / 0.1° global         | GRIB2 messages by byte range (ECMWF open data) | none |
| `AIFS`  | ECMWF AIFS Single machine-learning forecasts, 0.25° global     | GRIB2 messages by byte range (ECMWF open data) | none |
| `HRRR`  | NOAA High-Resolution Rapid Refresh forecasts, 3 km, contiguous US | GRIB2 messages by byte range (AWS)   | none |
| `ERA5`  | ECMWF ERA5 reanalysis                                          | not implemented yet                     | —    |

## Examples

### Sea surface temperature (OISST)

Three days of sea surface temperature over the North Atlantic. OISST longitudes
run from 0 to 360, so 280..350 is 80°W..10°W.

```julia
using GeoFetch, Dates

pipeline = OISST(start=Date(2025, 1, 1), stop=Date(2025, 1, 3)) |
    Select(vars=:sst, lon=Between(280, 350), lat=Between(20, 60)) |
    Rechunk(time=3) |
    Store("oisst.zarr")

execute(pipeline)
```

### Weather forecasts (GFS)

One forecast cycle at three lead times over Europe: 2 m temperature, accumulated
precipitation, and temperature on two pressure levels. Each GFS file is about
540 MB, but only the selected GRIB messages are downloaded (under 10 MB here).

```julia
using GeoFetch, Dates

pipeline = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), cycles=[0], steps=[0, 6, 12]) |
    Select(vars=[:t2m, :apcp, :t], level=[850, 500], lon=Between(0, 30), lat=Between(35, 60)) |
    Store("gfs.zarr")

execute(pipeline)
```

GFS data has dimensions `lon`, `lat`, `level` (hPa), `step` (lead time in hours)
and `time` (forecast initialization). See the `GFS` docstring for the variable
list. Without a `Select(vars=...)` every variable on every level is fetched.

### Weather forecasts (IFS and AIFS)

The same kind of pipeline for ECMWF's IFS model, read from the
[ECMWF open data](https://www.ecmwf.int/en/forecasts/datasets/open-data)
(CC-BY-4.0). Again only the selected GRIB messages are downloaded.

```julia
using GeoFetch, Dates

pipeline = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 6, 12]) |
    Select(vars=[:t2m, :tp, :t], level=[850, 500], lon=Between(0, 30), lat=Between(35, 60)) |
    Store("ifs.zarr")

execute(pipeline)
```

`AIFS(...)` takes the same keywords and reads ECMWF's machine-learning forecast
instead. Both have the same dimensions as GFS, but `lon` runs from -180 to 180
rather than 0 to 360, there are 14 pressure levels, and some units differ
between the two (`tp` is in m for IFS and kg m⁻² for AIFS). See the `IFS` and
`AIFS` docstrings for the variable lists.

### Weather forecasts on a projected grid (HRRR)

NOAA's HRRR covers the contiguous United States on a 3 km grid that is regular
in a Lambert conformal projection, so its horizontal dimensions are the
projected coordinates `x` and `y` (in m). `lon` and `lat` are two-dimensional
arrays on `(x, y)`. They can still be used in a `Select`, which keeps the
smallest `x`/`y` rectangle that contains the requested box.

```julia
using GeoFetch, Dates

pipeline = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=0:3) |
    Select(vars=[:t2m, :apcp, :t], level=[850, 500], lon=Between(-110, -100), lat=Between(35, 42)) |
    Store("hrrr.zarr")

execute(pipeline)
```

The store holds `lon` and `lat` next to the variables, and the projection as a
PROJ string in its `crs` attribute. Wind components are relative to the grid
(`u` along `x`, `v` along `y`), not to east and north. See the `HRRR` docstring
for the variable list.

### Reading a store back

Stores are plain Zarr (v3 by default, `Store(path; zarr_version=2)` for v2) and
open with any Zarr reader:

```julia
using Zarr, Dates

g = zopen("gfs.zarr")
t2m = g["t2m"][:, :, :, :]                  # (lon, lat, step, time)
lon = g["lon"][:]
time = DateTime(1970) .+ Second.(g["time"][:])
```

Time coordinates are stored as integers with CF `units` attributes
(`seconds since 1970-01-01T00:00:00` for `DateTime`, `days since 1970-01-01` for
`Date`).

### Selecting

`Select` takes one keyword per dimension, plus `vars`:

```julia
Select(vars=:sst)                           # one variable
Select(vars=[:t2m, :u10, :v10])             # several
Select(lat=Between(30, 60))                 # closed interval
Select(level=[850, 500])                    # explicit values
Select(time=Date(2025, 1, 1):Day(1):Date(2025, 1, 5))   # a range
```

Selections are applied before anything is downloaded, so files, variables and
levels that are not selected are never fetched.

Runnable scripts for each source are in [`examples/`](examples/):

```
julia --project=. examples/oisst.jl
julia --project=. examples/gfs.jl
julia --project=. examples/ifs.jl
julia --project=. examples/hrrr.jl
```
