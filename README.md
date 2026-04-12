# GeoFetch

Fetch geospatial data from multiple sources into a unified project directory.

## Quick Start

```julia
using GeoFetch, Dates, Extents

gfs = GeoFetch.GFS_025  
gfs.parameters = ["TMP"]
gfs.levels = ["2_m_above_ground"]

p = Project(
    geometry = Extent(X=(-90.0, -80.0), Y=(30.0, 40.0)),
    datetimes = (DateTime(2026, 4, 1), DateTime(2026, 4, 1)),
    datasets = [gfs],
)

fetch(p)
```

## Type Hierarchy

- **`Source`** -- a data provider (e.g. `NOMADS`, `CDS`, `FIRMS`)
  - `datasets(source)` -- list available datasets
  - `help(source)` -- documentation URL
- **`Dataset`** -- a configurable remote dataset
  - `chunks(project, dataset)` -- resolve into downloadable chunks
  - `nchunks(project, dataset)` -- number of chunks
- **`Chunk`** -- a single downloadable file
  - `fetch(chunk, filepath)` -- download to disk
  - `filesize(chunk)` -- remote file size in bytes (via HEAD request), or `nothing`
- **`Project`** -- spatial/temporal region of interest + output directory

## Sources

| Source | Description | Auth |
|--------|-------------|------|
| `NOMADS` | NOAA operational weather models (GFS, HRRR, NAM, ...) via GRIB filter | None |
| `CDS` | Copernicus Climate Data Store (ERA5, CERRA, satellite, ...) | `CDSAPI_KEY` env var or `~/.cdsapirc` |
| `FIRMS` | NASA active fire data (VIIRS, MODIS, LANDSAT) | `FIRMS_MAP_KEY` env var |
| `ETOPO` | NOAA global relief model (bathymetry + topography) | None |
| `SRTM` | NASA Shuttle Radar Topography Mission (30m/90m elevation) | `EARTHDATA_TOKEN` env var |
| `GOES` | NOAA GOES-16/17/18 satellite imagery via AWS S3 | None |
| `HRRRArchive` | HRRR model archive via AWS S3 | None |
| `GeoFetchLandfire` | LANDFIRE fuels, vegetation, disturbance, and topography via optional extension | `LANDFIRE_EMAIL` |

## Project

```julia
Project(;
    geometry = EARTH,           # any GeoInterface-compatible geometry or Extent
    datetimes = nothing,        # (start, stop) DateTime tuple
    path = mktempdir(),         # output directory
    datasets = [],              # Vector of Dataset instances
)
```

- `fetch(project)` downloads all chunks, skipping files that already exist.
- Data is written to `<project.path>/data/`.

## Optional Extensions

`Landfire.jl` integration is shipped as a package extension. Load both packages, grab the
extension module, and create a `LandfireDataset` from `Landfire.Product` values:

```julia
using GeoFetch, Landfire

ext = Base.get_extension(GeoFetch, :GeoFetchLandfire)
prods = Landfire.products(layer="FBFM40", conus=true)

p = Project(
    geometry = region("Colorado"),
    datasets = [ext.LandfireDataset(products=prods)],
)

fetch(p)
```
