## Unreleased

### Features
- `GFS` preset: NOAA GFS forecasts (0.25°, 0.5°, 1°) from the `noaa-gfs-bdp-pds` AWS bucket, with dims `lon`, `lat`, `level`, `step`, `time`
- `IFS` and `AIFS` presets: ECMWF IFS (0.25°, 0.1°) and AIFS Single (0.25°) deterministic forecasts from the ECMWF open data, with the same dims as `GFS`
- `HRRR` preset: NOAA HRRR 3 km forecasts over the contiguous US from the `noaa-hrrr-bdp-pds` AWS bucket, with dims `x`, `y` (Lambert conformal projected coordinates), `level`, `step`, `time`
- Auxiliary coordinates (`CoordSpec`): sources on a projected grid carry two-dimensional `lon`/`lat` coordinates, which are written to the store and can be used in `Select` (keeps the bounding `x`/`y` rectangle of the matching grid points)
- `GRIBRangeSource` transport: reads individual GRIB2 messages by HTTP byte range using `.idx` sidecars, from a URL or a local path
- `GRIBRangeSource` also reads ECMWF JSON `.index` sidecars (`index=:ecmwf`)
- GRIB.jl is now a dependency

### Fixes
- `Select` on variables and on dims not pinned by a fetch unit (e.g. `lon`, `lat`) now narrows what transports read and return
- `Date`/`DateTime` coordinates are stored as CF-encoded integers (`units`/`calendar` attributes) so stores can be reopened

### Breaking
- The transport contract is now `fetch!(source, unit, schema)`, where `schema` is the narrowed (post-`Select`) schema

## v0.1.0 - 2026-04-13

### Features
- Initial release of GeoFetch, a Julia package for fetching geospatial data from multiple providers
- NOMADS sources: GOES satellite imagery, HRRR archive
- CDS sources: ERA5 reanalysis via Copernicus Climate Data Store
- FIRMS active fire data (NASA)
- ETOPO global relief/bathymetry data
- SRTM elevation data
- NASAPower meteorological and solar data
- USGSWater streamflow and water quality data
- NCEI climate data
- OISST sea surface temperature data
- Landfire WCS source with Latest() year resolution
- GeoInterface.crs integration for all Dataset types
- Live integration tests for all sources
