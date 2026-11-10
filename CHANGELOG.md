## Unreleased

### Features
- `GFS` preset: NOAA GFS forecasts (0.25°, 0.5°, 1°) from the `noaa-gfs-bdp-pds` AWS bucket, with dims `lon`, `lat`, `level`, `step`, `time`
- `GRIBRangeSource` transport: reads individual GRIB2 messages by HTTP byte range using `.idx` sidecars, from a URL or a local path
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
