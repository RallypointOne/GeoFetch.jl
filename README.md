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
| `NASAPower` | NASA global daily meteorological and solar data | None |
| `USGSWater` | USGS streamflow, gage height, and water quality observations | None |
| `NCEI` | NOAA historical weather and climate observations | None |
| `OISST` | NOAA daily global sea surface temperature (0.25° grid) | None |
| `Landfire` | USGS LANDFIRE wildland fire, vegetation, and fuel data via WCS | None |

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
