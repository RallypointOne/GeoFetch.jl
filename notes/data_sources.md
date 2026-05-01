# GeoFetch Data Sources — Metadata Inventory

This is a snapshot of every source currently under `src/sources/`, the metadata the code
already exposes, and the metadata gaps. The bottom section lists metadata fields worth
collecting more systematically.

Legend:
- **Captured** — already present in the source file (struct field, `metadata()` Dict,
  constants, or URL-builder logic).
- **Implicit** — knowable from the API/URL patterns but not surfaced in code.
- **Missing** — not represented anywhere; would need a structured description.

---

## 1. CDS (Copernicus Climate Data Store) — `CDS.jl`

- **Type:** `CDSDataset <: Dataset` (DynamicDataSource semantics)
- **Access:** CDS retrieve API (`cds.climate.copernicus.eu/api`), async job submission → poll → download
- **Auth:** required. `CDSAPI_KEY` env or `~/.cdsapirc` (`key:` line)
- **Output format:** `netcdf` (default) or `grib`
- **Chunking:** one chunk per calendar month
- **Datasets (21 registered):**
  - ERA5: `reanalysis-era5-single-levels`, `reanalysis-era5-pressure-levels`,
    `…-monthly-means` (×2), `reanalysis-era5-land`, `…-land-monthly-means`,
    `…-preliminary-back-extension` (×2)
  - CERRA (regional): `reanalysis-cerra-single-levels`, `…-pressure-levels`, `…-land`
  - Satellite: `satellite-sea-surface-temperature`, `satellite-sea-level-global`,
    `satellite-soil-moisture`
  - Seasonal forecasts: `seasonal-original-single-levels`, `…-original-pressure-levels`,
    `seasonal-monthly-single-levels`, `…-monthly-pressure-levels`
  - Projections: `projections-cmip6`, `projections-cordex-domains-single-levels`
  - Other reanalyses: `reanalysis-uerra-europe-single-levels`, `reanalysis-oras5`
- **Resolution (captured, degrees):** ERA5 single/pressure = 0.25°, ERA5-Land = 0.1°;
  others not in `_CDS_RESOLUTIONS`
- **Temporal coverage:** Missing. ERA5 is ≈1940→present (w/ back-extension to 1940; main
  reanalysis from 1979), ERA5-Land from 1950, CERRA 1984→, etc. Not encoded.
- **Variables:** user-supplied list of strings; no registry of valid names/units/descriptions
- **Pressure levels:** user-supplied list of strings; no registry of valid values
- **Times of day:** default `["00:00","06:00","12:00","18:00"]`; hourly for ERA5
- **CRS:** Missing — all CDS products are regular lat/lon (EPSG:4326) in delivered NetCDF
- **License:** Copernicus/ECMWF (captured)
- **Gaps:** per-dataset variable registry, pressure-level registry, valid time cadence,
  temporal coverage, product_type enum per dataset

## 2. ETOPO (Global Relief Model) — `ETOPO.jl`

- **Type:** `ETOPODataset <: Dataset` (StaticDataSource — no time dimension)
- **Access:** NOAA THREDDS file server (direct download, no auth)
- **Format:** `netcdf` (default) or `geotiff`
- **Resolutions:** `60s` (≈1.85 km), `30s` (≈0.93 km), `15s` (≈0.46 km) — in degrees:
  1/60, 1/120, 1/240 (captured)
- **Surface types:** `surface` (ice-surface elevation), `bedrock` (sub-ice bedrock)
- **Temporal coverage:** static, version "ETOPO 2022 v1"; single epoch
- **Spatial coverage:** global (90°N–90°S, 180°W–180°E)
- **CRS:** Missing — WGS84 geographic (EPSG:4326)
- **Variable:** single `z` (elevation) in meters. Not registered as a `Variable` struct.
- **License:** NOAA/NCEI public domain (captured)
- **Gaps:** variable registry (name=`z`, units=`m`, description=`elevation above sea level`),
  version/vintage, file-size estimate (full 15s file ≈ GBs)

## 3. FIRMS (NASA Fire Information for Resource Management) — `FIRMS.jl`

- **Type:** `FIRMSDataset <: Dataset` (point data / fire detections)
- **Access:** FIRMS area API, bbox queries
- **Auth:** required. `FIRMS_MAP_KEY` env
- **Format:** `csv` (default) or `json`
- **Sources (8, captured):** LANDSAT_NRT, MODIS_NRT, MODIS_SP, VIIRS_SNPP_NRT/SP,
  VIIRS_NOAA20_NRT/SP, VIIRS_NOAA21_NRT
- **Chunking:** up to 5 days per request (`_FIRMS_MAX_DAYS`), repeat across the date range
- **Temporal coverage:** Missing. Rough reality: MODIS ~2000→present, VIIRS SNPP 2012→,
  NOAA-20 2018→, NOAA-21 2023→, LANDSAT 2022→; NRT has ~3h latency, SP ~2-month lag
- **Spatial:** global bbox supported (or `world`)
- **Variables (implicit, from CSV columns):** `latitude`, `longitude`, `bright_ti4`/`bright_ti5`
  (VIIRS K) or `brightness` (MODIS K), `scan`, `track`, `acq_date`, `acq_time`, `satellite`,
  `instrument`, `confidence` (0-100 or l/n/h), `version`, `frp` (fire radiative power, MW),
  `daynight`. Not in a structured `Variable` registry.
- **CRS:** EPSG:4326 (point lat/lon)
- **Resolution (native, implicit):** MODIS 1 km, VIIRS 375 m (I-band) or 750 m, LANDSAT 30 m
- **License:** NASA FIRMS (captured)
- **Gaps:** native pixel size per sensor, temporal coverage start per sensor, NRT-vs-SP
  latency, confidence schema per sensor

## 4. GOES (Geostationary Operational Environmental Satellites) — `GOES.jl`

- **Type:** `GOESDataset <: Dataset`
- **Access:** AWS S3 public buckets (`noaa-goes16/17/18`), HTTPS + XML list-objects
- **Auth:** none
- **Satellites:** `goes16` (East, operational), `goes17` (decommissioned 2023), `goes18` (West)
- **Products (8 registered constants; many more available):** ABI-L2-CMIPF (cloud and
  moisture imagery, full disk), ABI-L1b-RadC (radiance CONUS), ABI-L2-SSTF (SST full disk),
  GLM-L2-LCFA (Geostationary Lightning Mapper)
- **Band:** optional 1–16 filter for ABI products
- **Chunking:** S3 list per (satellite, product, year/dayOfYear/hour); one chunk per granule
- **Format:** NetCDF (`.nc`)
- **Temporal coverage:** Missing. GOES-16: 2017→present; GOES-17: 2018–2023; GOES-18:
  2022→present. Cadence is product-specific (ABI full disk every 10 min, CONUS every 5, GLM 20s)
- **Spatial:** geostationary full-disk or CONUS/Meso sector; **NOT lat/lon** — fixed grid on
  ABI perspective (satellite_height ≈ 35786 km, sub-satellite longitude -75° for G16, -137° for G18)
- **CRS:** returned as `nothing` — geostationary projection is in file CF attrs. **Missing**
  from code metadata.
- **Resolution (native, implicit):** ABI 0.5–2 km depending on band/product
- **Variables:** product-dependent (CMI for CMIP, Rad for radiances, SST, lightning events).
  No `Variable` registry.
- **License:** NOAA public domain (captured)
- **Gaps:** CRS (geostationary), native resolution per band, temporal coverage per satellite,
  granule cadence, variable registry per product, sector definitions (F/C/M1/M2)

## 5. LANDFIRE (Landscape Fire & Resource Mgmt Planning) — `Landfire.jl`

- **Type:** `LandfireDataset <: Dataset`
- **Access:** USGS GeoServer WCS 2.0.1 (`GetCoverage` requests with lat/long subsets)
- **Auth:** none
- **Format:** GeoTIFF only
- **Products (16 captured):** CBD (canopy bulk density), CBH (canopy base height), CC
  (canopy cover), CH (canopy height), EVC/EVH/EVT (existing vegetation cover/height/type),
  FBFM13 (Anderson 13 fuel models), FBFM40 (Scott & Burgan 40), FDist (fuel disturbance),
  FVC/FVH/FVT, SClass (succession class), VCC (vegetation condition class), VDep (departure)
- **Regions (captured):** CONUS, AK, HI
- **Year:** int or `Latest()` — auto-discovers latest by probing WCS GetCapabilities
  2010→today. Result cached per region.
- **Temporal coverage (implicit):** LF releases are roughly biennial (LF2020, LF2022, LF2023…).
  Each product is a single snapshot, not a time series.
- **Spatial:** bounded extent required; regional coverage (CONUS/AK/HI)
- **CRS:** subsets use EPSG:4326 in request; native LANDFIRE rasters are USGS Albers
  Equal Area (EPSG:5070) — **not captured**
- **Resolution:** 30 m native — **not captured** in `metadata()` (docstring only)
- **Variables:** each product = one raster; coded pixel values with product-specific
  classification tables. No `Variable` registry.
- **License:** USGS public domain (captured)
- **Gaps:** native CRS, native resolution, pixel value class tables per product (critical
  for interpretation — FBFM40 codes 91–204, etc.), nodata value, release year history

## 6. NASA POWER — `NASAPower.jl`

- **Type:** `NASAPowerDataset <: Dataset`
- **Access:** NASA LaRC POWER REST API (daily/temporal/{point|regional})
- **Auth:** none
- **Format:** JSON
- **Communities (captured):** `AG` (agroclimatology), `RE` (renewable energy),
  `SB` (sustainable buildings)
- **Query types:** `point` (single lat/lon from extent centroid) or `regional` (bbox, ≥2°
  on each side)
- **Variables (17 listed in `_NASAPOWER_VARIABLES`, as strings only):**
  `T2M`, `T2M_MAX/MIN/RANGE`, `T2MDEW`, `RH2M`, `PRECTOTCORR`, `WS2M/WS10M`, `WD2M/WD10M`,
  `PS`, `QV2M`, `CLOUD_AMT`, `ALLSKY_SFC_SW_DWN`, `CLRSKY_SFC_SW_DWN`, `ALLSKY_SFC_LW_DWN`
- **Cadence:** daily (times_per_day=1 captured); hourly/monthly endpoints exist but not wired up
- **Temporal coverage:** Missing. POWER daily goes back to 1981-01-01 (solar subset from 1984)
- **Spatial resolution:** 0.5° (regional, captured); point queries return bilinear interp
- **CRS:** EPSG:4326 (implicit)
- **License:** NASA LARC public domain (captured)
- **Gaps:** per-variable units/description (T2M is °C, PRECTOTCORR is mm/day, WS is m/s,
  PS is kPa, RH2M is %, shortwave is MJ/m²/day — none captured), valid community per
  variable, temporal coverage

## 7. NCEI (NOAA National Centers for Environmental Information) — `NCEI.jl`

- **Type:** `NCEIDataset <: Dataset`
- **Access:** NCEI Data Access Service v1 (`ncei.noaa.gov/access/services/data/v1`)
- **Auth:** none (rate-limited; API token recommended for heavy use but not enforced)
- **Format:** `json` (default) or `csv`
- **Datasets (captured with one-line descriptions in `_NCEI_DATASET_INFO`):**
  `daily-summaries`, `global-summary-of-the-month`, `global-summary-of-the-year`,
  `global-summary-of-the-day`, `global-hourly`, `local-climatological-data`,
  `normals-daily`, `normals-monthly`, `global-marine`
- **Chunking:** up to 365 days per request (`_NCEI_MAX_DAYS`)
- **Units:** `metric` or `standard`
- **Data types (user supplies; default `["TMAX","TMIN","PRCP"]`):** no registry; real
  GHCND types include TMAX/TMIN/TAVG (°C ×10 raw, resolved by units flag), PRCP (mm),
  SNOW, SNWD, AWND, WSFG, etc. ISD hourly uses different codes.
- **Station IDs:** user-supplied; alternative is bbox
- **Temporal coverage:** Missing. GHCND daily runs 1750s→present (station-dependent);
  ISD hourly 1901→; normals are fixed 30-year windows.
- **Spatial:** station network (global), or bbox subset
- **CRS:** N/A — station point data (lat/lon)
- **License:** NOAA/NCEI public domain (captured)
- **Gaps:** per-dataset datatype registry (GHCND vs ISD vs LCD codes are different),
  units per datatype, station metadata lookup, per-dataset start year

## 8. NDBC (National Data Buoy Center) — `NDBC.jl`

- **Type:** `NDBCDataset <: Dataset`
- **Access:** NDBC historical archive (`ndbc.noaa.gov/data/historical`) or THREDDS
  (`dods.ndbc.noaa.gov`) for NetCDF
- **Auth:** none
- **Station discovery:** `ndbcmapstations.json` → filter by bbox; or user-supplied IDs
- **Data types (12 captured with prefix codes):** stdmet (h), cwind (c), ocean (o), swden (w),
  swdir (d), swdir2 (j), swr1 (k), swr2 (l), adcp (a), dart (d), srad (r), supl (s)
- **Format:** `txt` (gzipped historical) or `nc` (THREDDS)
- **Chunking:** one chunk per (station, year)
- **Temporal coverage:** Missing per-station — stations have varying deployment dates
  (some 1970s→present, many discontinued)
- **Variables (implicit per datatype):**
  - stdmet: WDIR (°T), WSPD (m/s), GST (m/s), WVHT (m), DPD/APD (s), MWD (°T),
    PRES (hPa), ATMP (°C), WTMP (°C), DEWP (°C), VIS (nmi), PTDY (hPa), TIDE (ft)
  - ocean: DEPTH (m), OTMP (°C), COND (mS/cm), SAL (PSU), O2% (%), O2PPM (ppm), CLCON,
    TURB, PH, EH (mV)
  - cwind: WDIR (°T), WSPD (m/s), GDR, GST, GTIME
  - swden: spectral density (m²/Hz) as f(freq)
  - (others similar) — none in a structured registry
- **Spatial:** point (moored/drifting buoys); global coverage, dense in US coastal
- **Cadence:** typically hourly (stdmet), 10-min continuous wind, …
- **License:** NOAA public domain (captured)
- **Gaps:** per-datatype variable registry, per-station temporal coverage and position,
  file size estimate (currently `Base.filesize(::NDBCChunk)` not defined), buoy type
  (moored/drifting/C-MAN)

## 9. NOAA S3 (HRRR + GFS archives) — `NOAA_S3.jl`

Two `Dataset` types share one `NOAA_S3Chunk`:

### HistoricalHRRR
- **Access:** `noaa-hrrr-bdp-pds` AWS bucket (HTTPS)
- **Product:** sfc (surface 2D), prs (pressure levels), nat (native vertical hybrid)
- **Domain:** conus or alaska
- **Forecast hours:** 0–18 (conus f00/f01 every hour; extended forecasts every 6h cycle),
  0–36 for extended; user supplies list
- **Cycles:** hourly 00–23 UTC (user supplies list)
- **Chunking:** per (date, cycle, forecast_hour)
- **Temporal coverage:** Missing. HRRR archive in S3 starts 2014-07-30 (v1); current v4
  from 2020-12-02
- **Spatial / CRS:** Missing — HRRR is Lambert Conformal Conic (NOT lat/lon),
  3 km native, 1799×1059 CONUS grid. `GI.crs(::HistoricalHRRR) = nothing` is a red flag.
- **Variables:** Missing. GRIB2 multi-variable files; contents depend on product
  (sfc ≈ 170+ fields, prs ≈ 500+ fields, nat ≈ 1000+ fields per hybrid level)
- **License:** NOAA public domain (captured)

### HistoricalGFS
- **Access:** `noaa-gfs-bdp-pds` AWS bucket
- **Resolution:** `0p25` (0.25°), `0p50` (0.5°), `1p00` (1.0°) — captured in metadata
- **Forecast hours:** 0–384 (long range); user supplies
- **Cycles:** 00, 06, 12, 18 UTC
- **Chunking:** per (date, cycle, forecast_hour)
- **Temporal coverage:** Missing. GFS S3 archive from 2021-01-01; current v16.2 from 2021
- **CRS:** regular lat/lon, 0.25°/0.5°/1.0°
- **Variables:** Missing — GRIB2 `pgrb2.*` files have ~400 variables at ~25 levels
- **License:** NOAA public domain (captured)

### Shared gaps
- GRIB2 byte-range support (`.idx` sidecars) for per-variable subsetting not implemented
- No variable or level registry; no CRS definition for HRRR

## 10. NOMADS (NOAA Operational Model Archive and Distribution System) — `NOMADS.jl`

- **Type:** `NomadsDataset <: Dataset`
- **Access:** NOMADS `filter_*.pl` CGI GRIB filter (returns GRIB2 subsets); dir/file
  discovery via HTML scraping
- **Auth:** none
- **Categories (enum):** Global, Regional, Climate, Ocean, SpaceWeather, External
- **Datasets (≈100 registered):** see constants at bottom of file; highlights include
  GFS (0.25/0.5/1.0°, hourly), GEFS, HRRR (conus/ak, 2d/sub-hourly), NAM (conus/ak/na/…),
  RAP, RTMA, HREF, HIRESW, CFS, RTOFS, GLWU, STOFS, Sea Ice, etc.
- **parameters / levels:** `All()` or user-supplied lists (server-side subset via
  `var_X=on` / `lev_X=on`)
- **Format:** GRIB2
- **Chunking:** one chunk per forecast file in latest available run
- **Temporal coverage:** **rolling, short** — NOMADS keeps only ~7-10 days for most
  products; longer archives live on NCEI. Not captured.
- **CRS/resolution:** product-specific (GFS regular lat/lon; HRRR Lambert; NAM Lambert;
  RTMA Lambert; RTOFS tripolar). **Not captured.**
- **Variables/levels:** Missing. Each product has its own variable + level name conventions
  used in the filter script (`TMP`, `UGRD`, `VGRD`, `PRMSL`, level strings like `surface`,
  `2_m_above_ground`, `500_mb`).
- **License:** NOAA public domain (captured)
- **Gaps:** huge — no variable/level registry per product, no CRS, no native resolution,
  no cycle/freq info (the `freq` field on the struct is always `""`)

## 11. Nominatim (OpenStreetMap geocoding) — `Nominatim.jl`

- **Type:** `NominatimDataset <: Dataset`
- **Access:** Nominatim REST API (search / reverse / lookup)
- **Auth:** none (but usage policy requires User-Agent + `email` for heavy use;
  public server is rate-limited to 1 req/s)
- **Format:** `json` / `jsonv2` / `geojson` / `geocodejson`
- **Endpoints:** search (q string), reverse (lat/lon from extent centroid), lookup (osm_ids)
- **Options captured:** addressdetails, extratags, namedetails, polygon_geojson,
  countrycodes, layer, accept_language, email, zoom, limit
- **Temporal coverage:** N/A (snapshot of current OSM)
- **Spatial:** global (OSM coverage varies by region)
- **CRS:** EPSG:4326
- **Variables:** response schema varies by format; no `Variable` registry (nor is one
  meaningful here since this is geocoding, not gridded/time-series data)
- **License:** OpenStreetMap ODbL (captured) — **attribution requirement is strict**
- **Gaps:** this source fits awkwardly in the `Variable`/`Metadata` model that the
  abstract `DataSource` hierarchy seems aimed at. Worth flagging as a distinct
  `geocoding` data_type (already tagged).

## 12. OISST (Optimum Interpolation SST) — `OISST.jl`

- **Type:** `OISSTDataset <: Dataset` (empty — no config)
- **Access:** NCEI THREDDS file server
- **Auth:** none
- **Format:** NetCDF
- **Chunking:** one file per day
- **Temporal coverage:** Missing. OISST v2.1 AVHRR covers 1981-09-01 → present with ~1 day
  latency (preliminary) / ~2 weeks (final).
- **Spatial:** global 0.25° regular lat/lon (captured as resolution)
- **CRS:** EPSG:4326 (implicit)
- **Variables (implicit):** `sst` (°C), `anom` (anomaly °C), `err` (estimated error °C),
  `ice` (sea ice concentration fraction). Single vertical level (surface). Not registered.
- **License:** NOAA/NCEI public domain (captured)
- **Gaps:** variable registry, coverage start date, prelim-vs-final flag, file-size estimate

## 13. SRTM (Shuttle Radar Topography Mission) — `SRTM.jl`

- **Type:** `SRTMDataset <: Dataset`
- **Access:** USGS LP DAAC via Earthdata (`e4ftl01.cr.usgs.gov/MEASURES/…`)
- **Auth:** required. Bearer token in `EARTHDATA_TOKEN` env (generate at urs.earthdata.nasa.gov)
- **Products (captured):** SRTMGL1 (~30 m, 1"), SRTMGL3 (~90 m, 3")
- **Version:** `003`
- **Format:** zipped SRTM HGT tiles (`.hgt.zip`)
- **Chunking:** one chunk per 1°×1° tile intersecting the extent (global grid named
  `N|S{lat}E|W{lon}`)
- **Temporal coverage:** static; acquired Feb 2000, v003 released 2015
- **Spatial coverage:** 60°S–60°N (captured in `_srtm_tiles_for_extent`)
- **CRS:** EPSG:4326 (implicit — WGS84 geographic, EGM96 vertical datum)
- **Resolution:** 1/3600 or 1/1200 degrees captured; `bytes_per_value=2` captured (int16)
- **Variable:** single elevation (m), int16, nodata = -32768. Not registered.
- **License:** NASA/USGS public domain (captured)
- **Gaps:** variable registry, vertical datum (EGM96), nodata value

## 14. USGS Water Data — `USGSWater.jl`

- **Type:** `USGSWaterDataset <: Dataset`
- **Access:** USGS OGC API (`api.waterdata.usgs.gov/ogcapi/v0`)
- **Auth:** none
- **Collections:** `daily` (one/day, with statistic) or `continuous` (≈15 min)
- **Chunking:** daily = single request; continuous chunked in 90-day windows per parameter
- **Parameter codes (8 captured with unit strings):**
  - `00060` Discharge (ft³/s), `00065` Gage height (ft), `00010` Water temperature (°C),
    `00045` Precipitation (in), `00400` pH, `00300` Dissolved oxygen (mg/L),
    `00095` Specific conductance (µS/cm), `72019` Groundwater level (ft below land surface)
- **Statistic codes (captured):** 00001 Max, 00002 Min, 00003 Mean
- **Format:** `json` or `csv`
- **Temporal coverage:** Missing per-site; network overall ~1890s→present (discharge),
  site-dependent
- **Spatial:** US + territories; site points or bbox
- **CRS:** N/A — station points (lat/lon, EPSG:4269/NAD83 natively)
- **License:** USGS public domain (captured)
- **Gaps:** the listed 8 parameter codes are a tiny slice of the USGS dictionary (thousands);
  site metadata registry (drainage area, HUC, altitude), data quality flags

---

## Cross-cutting metadata gaps

The `Metadata{DS}` struct in `src/GeoFetch.jl` is still a stub (`time::` has no type). The
`metadata(d)` methods currently return `Dict{Symbol,Any}` with an ad-hoc set of keys:
`data_type`, `resolution`, `license`, `requires_auth`, `n_variables`, `n_levels`,
`times_per_day`, `bytes_per_value`. That’s useful for file-size estimation but misses the
descriptive metadata needed for discoverability.

---

## What else to consider collecting

Ordered by how much leverage each gives for an atmosphere/ocean coupling workflow:

**Tier 1 — needed to actually use the data**

1. **Variable registry** (name, standard_name, units, description, per-dataset availability).
   The `Variable` struct exists but nothing populates it. At minimum for each dataset:
   list of available variables with units. Even partial coverage beats the current
   "string-typed" user input.
2. **Vertical coordinate system** (pressure level hPa / hybrid sigma / depth m / single-level).
   Matters for NOMADS, CDS, GFS, HRRR, CDS pressure-levels products — and especially for
   coupling, where you need to know the surface layer height.
3. **CRS / native grid projection.** Currently `GI.crs(::GOESDataset) = nothing` and
   `GI.crs(::HistoricalHRRR) = nothing` are explicit "unknown" markers. Add:
   - Geographic (EPSG:4326) for CDS/OISST/ETOPO/SRTM/NASA-POWER/GFS
   - Lambert Conformal for HRRR, NAM, RAP, RTMA
   - Geostationary fixed grid for GOES ABI
   - Albers Equal Area for LANDFIRE native rasters
4. **Temporal coverage** `(t_start, t_stop)` tuple per dataset, where `t_stop` can be
   `Latest()`/`now()` for live products. Drives validity checks before firing requests.
5. **Native temporal cadence** (e.g. GFS 3-hourly out to 240h then 6-hourly to 384h;
   HRRR hourly; OISST daily; GOES ABI full-disk every 10 min). Related but distinct from
   `times_per_day`.

**Tier 2 — needed for operational robustness**

6. **Latency** — how far behind real-time the product is available (NRT vs final; ERA5
   has a ~5-day ERA5T window before final replacement).
7. **Update / release cadence** — GFS runs 4×/day at HH:00 + ~5h; LANDFIRE ≈ biennial;
   ERA5 monthly.
8. **Retention policy** — NOMADS keeps ~7–10 days; S3 archives are permanent; CDS is
   permanent. Tells the user where to fall back when data ages out.
9. **Rate limits / request-size caps** — CDS has per-user queues and daily item limits;
   Nominatim public server is 1 req/s; FIRMS has a 5-day max per call (already encoded).
10. **Authentication schema** — already tracked as `requires_auth` bool; extend with
    the expected env var name / token URL (currently only in docstrings and errors).
11. **Typical chunk size (bytes)** — useful for `filesize(::Project)` estimates without
    a HEAD request. ETOPO 15s ≈ 3 GB; OISST ≈ 1.6 MB/day; GFS 0.25 pgrb2 ≈ 400 MB/file.

**Tier 3 — nice to have**

12. **Citation / DOI** — ERA5 has `10.24381/cds.adbb2d47`, OISST has
    `10.25921/RE9P-PT57`, ETOPO 2022 has `10.25921/fd45-gt74`. Useful for reproducibility.
13. **Known caveats / discontinuities** — OISST v2 → v2.1 change; ERA5T vs ERA5 replacement;
    GOES-17 decommissioning; HRRR v1→v4 grid changes.
14. **Successor / related datasets** — so a user can follow forward when something is
    retired (GOES-17 → GOES-18; ERA-Interim → ERA5).
15. **Native nodata / missing-value sentinel** and **dtype** — SRTM is int16 with
    -32768 nodata; ETOPO is int16 meters; LANDFIRE is uint8/uint16 coded classes.
16. **File format** — already implicit via `extension(::Chunk)`; worth promoting to
    metadata (`"netcdf"`, `"grib2"`, `"geotiff"`, `"csv"`, `"json"`).
17. **Per-dataset "native" spatial extent polygon** (not bbox) — LANDFIRE is CONUS only;
    CERRA is Europe; HRRR is a trimmed Lambert grid; GOES is a disk. bbox is misleading
    for non-rectangular grids.
18. **Contact / support channel** — for debugging when fetches fail.

**Suggested next step:** finish the `Metadata` struct. Something like:

```julia
struct Metadata{DS <: DataSource}
    data_source::DS
    variables::Vector{Variable}               # name/units/description/levels — populate it
    crs::Union{String, Nothing}               # "EPSG:4326", "EPSG:5070", ":geostationary", etc.
    resolution::Union{Float64, Nothing}       # degrees, or nothing for non-lat/lon
    extent::Extent                            # native coverage polygon/bbox
    time_range::Union{Tuple{DateTime,DateTime}, Nothing}
    cadence::Union{Period, Nothing}           # e.g. Hour(1), Day(1), nothing for static
    latency::Union{Period, Nothing}
    file_format::Symbol                       # :netcdf, :grib2, :geotiff, :csv, :json
    license::String
    citation::Union{String, Nothing}
    requires_auth::Bool
    auth_env_var::Union{String, Nothing}
end
```

Then each source's `metadata(::MyDataset)` populates it instead of returning a free-form
Dict. The variable registry is the highest-value piece — most of the other fields can be
filled in as constants from NOAA/NASA/Copernicus product docs.
