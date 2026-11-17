"""
    GeoFetch

Build Zarr stores on disk from remote geospatial data sources using a small
DAG-style pipeline. A pipeline is a chain of `Stage`s combined with the `|`
operator and has the shape

    Source | [Transform ...] | Sink

Components:

- `Source`     — describes upstream data (a `SourceSchema`) and how it is
                 partitioned for fetching (a list of `FetchUnit`s). Sources
                 are organized by *transport* (`HTTPFileSource`,
                 `CDSAPISource`, `GRIBRangeSource`, …); user-friendly presets
                 like `OISST(...)`, `GFS(...)` or `IFS(...)` build a transport
                 source pre-configured for a known dataset.
- `Transform`  — narrows or reshapes the pipeline. `Select` filters dims and
                 variables (and the unit list along with them). `Rechunk`
                 overrides the output chunk shape but does not affect what
                 gets fetched.
- `Sink`       — the materialization target. Currently only `Store`, which
                 writes a Zarr v2 or v3 store on local disk.

Building a pipeline is purely value-level: nothing is downloaded, no I/O
happens, no Zarr is created. The pipeline value can be inspected, printed,
or composed further. Calling `execute(pipeline)` is the one operation that
actually does work — it resolves the effective schema and unit list,
creates the Zarr group + arrays, then iterates the unit list and writes
each fetched chunk into place.

Public exports:
- Stage hierarchy: `Stage`, `Source`, `Transform`, `Sink`, `Pipeline`
- Transforms / sink: `Select`, `Rechunk`, `Store`
- Selectors: `All`, `Between`
- Presets: `OISST`, `ERA5`, `GFS`, `IFS`, `AIFS`, `HRRR`
- Entry point: `execute`
"""
module GeoFetch

using Dates
using Downloads
using Zarr
using NCDatasets
import GRIB
import JSON

export Pipeline, Stage, Source, Transform, Sink
export Select, Rechunk, Store
export All, Between
export OISST, ERA5, GFS, IFS, AIFS, HRRR
export execute

# NOAA GFS on the AWS Open Data bucket (see the `GFS` preset in `presets.jl`).
const _GFS_BASE = "https://noaa-gfs-bdp-pds.s3.amazonaws.com"

# Isobaric levels of the GFS pgrb2 files, in hPa.
const _GFS_LEVELS = [1000, 975, 950, 925, 900, 850, 800, 750, 700, 650, 600, 550, 500,
                     450, 400, 350, 300, 250, 200, 150, 100, 70, 50, 40, 30, 20, 15, 10,
                     7, 5, 3, 2, 1]

# GFS variable registry. `param`, `level` and `forecast` identify a variable's
# messages in the `.idx` sidecars: a `{}` in `level` marks an isobaric variable
# (one message per `_GFS_LEVELS` entry); `forecast === nothing` means an
# instantaneous field, a `Regex` constrains the idx forecast text.
const _GFS_FIELDS = [
    (name=:t2m, param="TMP", level="2 m above ground", forecast=nothing, units="K", long_name="2 metre temperature"),
    (name=:d2m, param="DPT", level="2 m above ground", forecast=nothing, units="K", long_name="2 metre dewpoint temperature"),
    (name=:rh2m, param="RH", level="2 m above ground", forecast=nothing, units="%", long_name="2 metre relative humidity"),
    (name=:u10, param="UGRD", level="10 m above ground", forecast=nothing, units="m s-1", long_name="10 metre eastward wind"),
    (name=:v10, param="VGRD", level="10 m above ground", forecast=nothing, units="m s-1", long_name="10 metre northward wind"),
    (name=:gust, param="GUST", level="surface", forecast=nothing, units="m s-1", long_name="surface wind gust"),
    (name=:prmsl, param="PRMSL", level="mean sea level", forecast=nothing, units="Pa", long_name="pressure reduced to mean sea level"),
    (name=:sp, param="PRES", level="surface", forecast=nothing, units="Pa", long_name="surface pressure"),
    (name=:pwat, param="PWAT", level="entire atmosphere (considered as a single layer)", forecast=nothing, units="kg m-2", long_name="precipitable water"),
    (name=:cape, param="CAPE", level="surface", forecast=nothing, units="J kg-1", long_name="surface-based convective available potential energy"),
    (name=:tcc, param="TCDC", level="entire atmosphere", forecast=nothing, units="%", long_name="total cloud cover"),
    (name=:apcp, param="APCP", level="surface", forecast=r"^0-\d+ (hour|day) acc fcst$", units="kg m-2", long_name="total precipitation accumulated since forecast start"),
    (name=:orog, param="HGT", level="surface", forecast=nothing, units="gpm", long_name="surface geopotential height (orography)"),
    (name=:lsm, param="LAND", level="surface", forecast=nothing, units="1", long_name="land-sea mask (1 = land)"),
    (name=:t, param="TMP", level="{} mb", forecast=nothing, units="K", long_name="temperature"),
    (name=:u, param="UGRD", level="{} mb", forecast=nothing, units="m s-1", long_name="eastward wind"),
    (name=:v, param="VGRD", level="{} mb", forecast=nothing, units="m s-1", long_name="northward wind"),
    (name=:w, param="VVEL", level="{} mb", forecast=nothing, units="Pa s-1", long_name="vertical velocity (pressure)"),
    (name=:z, param="HGT", level="{} mb", forecast=nothing, units="gpm", long_name="geopotential height"),
    (name=:rh, param="RH", level="{} mb", forecast=nothing, units="%", long_name="relative humidity"),
    (name=:q, param="SPFH", level="{} mb", forecast=nothing, units="kg kg-1", long_name="specific humidity"),
]

# ECMWF open data (see the `IFS` and `AIFS` presets in `presets.jl`), Google
# Cloud mirror. The AWS mirror (`https://ecmwf-forecasts.s3.eu-central-1.amazonaws.com`)
# and ECMWF's own server (`https://data.ecmwf.int/forecasts`, last ~4 days only)
# have the same layout.
const _ECMWF_BASE = "https://storage.googleapis.com/ecmwf-open-data"

# Isobaric levels of the ECMWF open data, in hPa.
const _ECMWF_LEVELS = [1000, 925, 850, 700, 600, 500, 400, 300, 250, 200, 150, 100, 50, 10]

# IFS variable registry. `param` is the ECMWF short name as written in the
# `.index` sidecars. `level` is `"sfc"` for a single-level field, `"{} pl"` for
# an isobaric variable (one message per `_ECMWF_LEVELS` entry) and `"N sol"`
# for soil layer `N`.
const _IFS_FIELDS = [
    (name=:t2m, param="2t", level="sfc", units="K", long_name="2 metre temperature"),
    (name=:d2m, param="2d", level="sfc", units="K", long_name="2 metre dewpoint temperature"),
    (name=:u10, param="10u", level="sfc", units="m s-1", long_name="10 metre eastward wind"),
    (name=:v10, param="10v", level="sfc", units="m s-1", long_name="10 metre northward wind"),
    (name=:u100, param="100u", level="sfc", units="m s-1", long_name="100 metre eastward wind"),
    (name=:v100, param="100v", level="sfc", units="m s-1", long_name="100 metre northward wind"),
    (name=:fg10, param="10fg", level="sfc", units="m s-1", long_name="maximum 10 metre wind gust since previous post-processing"),
    (name=:mx2t3, param="mx2t3", level="sfc", units="K", long_name="maximum 2 metre temperature in the last 3 hours"),
    (name=:mn2t3, param="mn2t3", level="sfc", units="K", long_name="minimum 2 metre temperature in the last 3 hours"),
    (name=:skt, param="skt", level="sfc", units="K", long_name="skin temperature"),
    (name=:msl, param="msl", level="sfc", units="Pa", long_name="mean sea level pressure"),
    (name=:sp, param="sp", level="sfc", units="Pa", long_name="surface pressure"),
    (name=:tcc, param="tcc", level="sfc", units="1", long_name="total cloud cover (0 - 1)"),
    (name=:lcc, param="lcc", level="sfc", units="1", long_name="low cloud cover (0 - 1)"),
    (name=:mcc, param="mcc", level="sfc", units="1", long_name="medium cloud cover (0 - 1)"),
    (name=:hcc, param="hcc", level="sfc", units="1", long_name="high cloud cover (0 - 1)"),
    (name=:tcw, param="tcw", level="sfc", units="kg m-2", long_name="total column water"),
    (name=:tcwv, param="tcwv", level="sfc", units="kg m-2", long_name="total column water vapour"),
    (name=:tclw, param="tclw", level="sfc", units="kg m-2", long_name="total column cloud liquid water"),
    (name=:tciw, param="tciw", level="sfc", units="kg m-2", long_name="total column cloud ice water"),
    (name=:tcrw, param="tcrw", level="sfc", units="kg m-2", long_name="total column rain water"),
    (name=:mucape, param="mucape", level="sfc", units="J kg-1", long_name="most-unstable convective available potential energy"),
    (name=:tp, param="tp", level="sfc", units="m", long_name="total precipitation accumulated since forecast start"),
    (name=:cp, param="cp", level="sfc", units="m", long_name="convective precipitation accumulated since forecast start"),
    (name=:sf, param="sf", level="sfc", units="m", long_name="snowfall (water equivalent) accumulated since forecast start"),
    (name=:ro, param="ro", level="sfc", units="m", long_name="runoff accumulated since forecast start"),
    (name=:tprate, param="tprate", level="sfc", units="kg m-2 s-1", long_name="total precipitation rate"),
    (name=:ptype, param="ptype", level="sfc", units="1", long_name="precipitation type (WMO code table 4.201)"),
    (name=:ssrd, param="ssrd", level="sfc", units="J m-2", long_name="surface short-wave radiation downwards accumulated since forecast start"),
    (name=:ssr, param="ssr", level="sfc", units="J m-2", long_name="surface net short-wave radiation accumulated since forecast start"),
    (name=:strd, param="strd", level="sfc", units="J m-2", long_name="surface long-wave radiation downwards accumulated since forecast start"),
    (name=:str, param="str", level="sfc", units="J m-2", long_name="surface net long-wave radiation accumulated since forecast start"),
    (name=:ttr, param="ttr", level="sfc", units="J m-2", long_name="top net long-wave radiation accumulated since forecast start"),
    (name=:ewss, param="ewss", level="sfc", units="N m-2 s", long_name="time-integrated eastward turbulent surface stress"),
    (name=:nsss, param="nsss", level="sfc", units="N m-2 s", long_name="time-integrated northward turbulent surface stress"),
    (name=:sd, param="sd", level="sfc", units="m", long_name="snow depth (water equivalent)"),
    (name=:rsn, param="rsn", level="sfc", units="kg m-3", long_name="snow density"),
    (name=:asn, param="asn", level="sfc", units="1", long_name="snow albedo (0 - 1)"),
    (name=:sithick, param="sithick", level="sfc", units="m", long_name="sea ice thickness"),
    (name=:zos, param="zos", level="sfc", units="m", long_name="sea surface height"),
    (name=:sve, param="sve", level="sfc", units="m s-1", long_name="eastward surface sea water velocity"),
    (name=:svn, param="svn", level="sfc", units="m s-1", long_name="northward surface sea water velocity"),
    (name=:lsm, param="lsm", level="sfc", units="1", long_name="land-sea mask (0 - 1, 1 = land)"),
    (name=:zsfc, param="z", level="sfc", units="m2 s-2", long_name="surface geopotential (orography), step 0 only"),
    (name=:sdor, param="sdor", level="sfc", units="m", long_name="standard deviation of sub-gridscale orography, step 0 only"),
    (name=:slor, param="slor", level="sfc", units="1", long_name="slope of sub-gridscale orography, step 0 only"),
    (name=:sot1, param="sot", level="1 sol", units="K", long_name="soil temperature, layer 1"),
    (name=:sot2, param="sot", level="2 sol", units="K", long_name="soil temperature, layer 2"),
    (name=:sot3, param="sot", level="3 sol", units="K", long_name="soil temperature, layer 3"),
    (name=:sot4, param="sot", level="4 sol", units="K", long_name="soil temperature, layer 4"),
    (name=:vsw1, param="vsw", level="1 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 1"),
    (name=:vsw2, param="vsw", level="2 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 2"),
    (name=:vsw3, param="vsw", level="3 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 3"),
    (name=:vsw4, param="vsw", level="4 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 4"),
    (name=:t, param="t", level="{} pl", units="K", long_name="temperature"),
    (name=:u, param="u", level="{} pl", units="m s-1", long_name="eastward wind"),
    (name=:v, param="v", level="{} pl", units="m s-1", long_name="northward wind"),
    (name=:w, param="w", level="{} pl", units="Pa s-1", long_name="vertical velocity (pressure)"),
    (name=:z, param="z", level="{} pl", units="m2 s-2", long_name="geopotential"),
    (name=:gh, param="gh", level="{} pl", units="gpm", long_name="geopotential height"),
    (name=:q, param="q", level="{} pl", units="kg kg-1", long_name="specific humidity"),
    (name=:r, param="r", level="{} pl", units="%", long_name="relative humidity"),
    (name=:d, param="d", level="{} pl", units="s-1", long_name="divergence"),
    (name=:vo, param="vo", level="{} pl", units="s-1", long_name="relative vorticity"),
]

# AIFS (single) variable registry, same layout as `_IFS_FIELDS`. Note the
# units that differ from IFS: precipitation and snowfall in kg m-2, cloud
# cover in %.
const _AIFS_FIELDS = [
    (name=:t2m, param="2t", level="sfc", units="K", long_name="2 metre temperature"),
    (name=:d2m, param="2d", level="sfc", units="K", long_name="2 metre dewpoint temperature"),
    (name=:u10, param="10u", level="sfc", units="m s-1", long_name="10 metre eastward wind"),
    (name=:v10, param="10v", level="sfc", units="m s-1", long_name="10 metre northward wind"),
    (name=:u100, param="100u", level="sfc", units="m s-1", long_name="100 metre eastward wind"),
    (name=:v100, param="100v", level="sfc", units="m s-1", long_name="100 metre northward wind"),
    (name=:skt, param="skt", level="sfc", units="K", long_name="skin temperature"),
    (name=:msl, param="msl", level="sfc", units="Pa", long_name="mean sea level pressure"),
    (name=:sp, param="sp", level="sfc", units="Pa", long_name="surface pressure"),
    (name=:tcc, param="tcc", level="sfc", units="%", long_name="total cloud cover"),
    (name=:lcc, param="lcc", level="sfc", units="%", long_name="low cloud cover"),
    (name=:mcc, param="mcc", level="sfc", units="%", long_name="medium cloud cover"),
    (name=:hcc, param="hcc", level="sfc", units="%", long_name="high cloud cover"),
    (name=:tcw, param="tcw", level="sfc", units="kg m-2", long_name="total column water"),
    (name=:tp, param="tp", level="sfc", units="kg m-2", long_name="total precipitation accumulated since forecast start"),
    (name=:cp, param="cp", level="sfc", units="kg m-2", long_name="convective precipitation accumulated since forecast start"),
    (name=:sf, param="sf", level="sfc", units="kg m-2", long_name="snowfall water equivalent accumulated since forecast start"),
    (name=:rowe, param="rowe", level="sfc", units="kg m-2", long_name="runoff water equivalent (surface plus subsurface) accumulated since forecast start"),
    (name=:fscov, param="fscov", level="sfc", units="1", long_name="fraction of snow cover (0 - 1)"),
    (name=:ssrd, param="ssrd", level="sfc", units="J m-2", long_name="surface short-wave radiation downwards accumulated since forecast start"),
    (name=:strd, param="strd", level="sfc", units="J m-2", long_name="surface long-wave radiation downwards accumulated since forecast start"),
    (name=:lsm, param="lsm", level="sfc", units="1", long_name="land-sea mask (0 - 1, 1 = land), step 0 only"),
    (name=:zsfc, param="z", level="sfc", units="m2 s-2", long_name="surface geopotential (orography), step 0 only"),
    (name=:sdor, param="sdor", level="sfc", units="m", long_name="standard deviation of sub-gridscale orography, step 0 only"),
    (name=:slor, param="slor", level="sfc", units="1", long_name="slope of sub-gridscale orography, step 0 only"),
    (name=:sot1, param="sot", level="1 sol", units="K", long_name="soil temperature, layer 1"),
    (name=:sot2, param="sot", level="2 sol", units="K", long_name="soil temperature, layer 2"),
    (name=:vsw1, param="vsw", level="1 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 1"),
    (name=:vsw2, param="vsw", level="2 sol", units="m3 m-3", long_name="volumetric soil moisture, layer 2"),
    (name=:t, param="t", level="{} pl", units="K", long_name="temperature"),
    (name=:u, param="u", level="{} pl", units="m s-1", long_name="eastward wind"),
    (name=:v, param="v", level="{} pl", units="m s-1", long_name="northward wind"),
    (name=:w, param="w", level="{} pl", units="Pa s-1", long_name="vertical velocity (pressure)"),
    (name=:z, param="z", level="{} pl", units="m2 s-2", long_name="geopotential"),
    (name=:gh, param="gh", level="{} pl", units="gpm", long_name="geopotential height"),
    (name=:q, param="q", level="{} pl", units="kg kg-1", long_name="specific humidity"),
]

# NOAA HRRR on the AWS Open Data bucket (see the `HRRR` preset in `presets.jl`).
const _HRRR_BASE = "https://noaa-hrrr-bdp-pds.s3.amazonaws.com"

# The HRRR CONUS grid: `nx` by `ny` points spaced `Δ` metres apart in a Lambert
# conformal projection (see `_lcc`) with standard parallel `lat0` and central
# meridian `lon0`, on a sphere of radius `R` metres. `(lon1, lat1)` is the first
# (south-west) grid point. All angles are in degrees; the values are those of
# the grid definition section of the GRIB files.
const _HRRR_GRID = (nx=1799, ny=1059, Δ=3000.0, lon1=-122.719528, lat1=21.138123, lon0=-97.5, lat0=38.5, R=6371229)

# Isobaric levels of the HRRR wrfprs files, in hPa.
const _HRRR_LEVELS = collect(1000:-25:50)

# HRRR variable registry, in the format of `_GFS_FIELDS`. Variables with a
# `{}` level are read from the wrfprs files, all others from the wrfsfc files.
const _HRRR_FIELDS = [
    (name=:t2m, param="TMP", level="2 m above ground", forecast=nothing, units="K", long_name="2 metre temperature"),
    (name=:d2m, param="DPT", level="2 m above ground", forecast=nothing, units="K", long_name="2 metre dewpoint temperature"),
    (name=:rh2m, param="RH", level="2 m above ground", forecast=nothing, units="%", long_name="2 metre relative humidity"),
    (name=:q2m, param="SPFH", level="2 m above ground", forecast=nothing, units="kg kg-1", long_name="2 metre specific humidity"),
    (name=:u10, param="UGRD", level="10 m above ground", forecast=nothing, units="m s-1", long_name="10 metre wind along the grid x axis"),
    (name=:v10, param="VGRD", level="10 m above ground", forecast=nothing, units="m s-1", long_name="10 metre wind along the grid y axis"),
    (name=:u80, param="UGRD", level="80 m above ground", forecast=nothing, units="m s-1", long_name="80 metre wind along the grid x axis"),
    (name=:v80, param="VGRD", level="80 m above ground", forecast=nothing, units="m s-1", long_name="80 metre wind along the grid y axis"),
    (name=:gust, param="GUST", level="surface", forecast=nothing, units="m s-1", long_name="surface wind gust"),
    (name=:prmsl, param="MSLMA", level="mean sea level", forecast=nothing, units="Pa", long_name="pressure reduced to mean sea level (MAPS reduction)"),
    (name=:sp, param="PRES", level="surface", forecast=nothing, units="Pa", long_name="surface pressure"),
    (name=:skt, param="TMP", level="surface", forecast=nothing, units="K", long_name="surface (skin) temperature"),
    (name=:pwat, param="PWAT", level="entire atmosphere (considered as a single layer)", forecast=nothing, units="kg m-2", long_name="precipitable water"),
    (name=:cape, param="CAPE", level="surface", forecast=nothing, units="J kg-1", long_name="surface-based convective available potential energy"),
    (name=:cin, param="CIN", level="surface", forecast=nothing, units="J kg-1", long_name="surface-based convective inhibition"),
    (name=:tcc, param="TCDC", level="entire atmosphere", forecast=nothing, units="%", long_name="total cloud cover"),
    (name=:lcc, param="LCDC", level="low cloud layer", forecast=nothing, units="%", long_name="low cloud cover"),
    (name=:mcc, param="MCDC", level="middle cloud layer", forecast=nothing, units="%", long_name="medium cloud cover"),
    (name=:hcc, param="HCDC", level="high cloud layer", forecast=nothing, units="%", long_name="high cloud cover"),
    (name=:vis, param="VIS", level="surface", forecast=nothing, units="m", long_name="surface visibility"),
    (name=:refc, param="REFC", level="entire atmosphere", forecast=nothing, units="dBZ", long_name="composite radar reflectivity"),
    (name=:hpbl, param="HPBL", level="surface", forecast=nothing, units="m", long_name="planetary boundary layer height"),
    (name=:prate, param="PRATE", level="surface", forecast=nothing, units="kg m-2 s-1", long_name="precipitation rate"),
    (name=:apcp, param="APCP", level="surface", forecast=r"^0-\d+ (hour|day) acc fcst$", units="kg m-2", long_name="total precipitation accumulated since forecast start"),
    (name=:asnow, param="ASNOW", level="surface", forecast=r"^0-\d+ (hour|day) acc fcst$", units="m", long_name="snowfall accumulated since forecast start"),
    (name=:snod, param="SNOD", level="surface", forecast=nothing, units="m", long_name="snow depth"),
    (name=:weasd, param="WEASD", level="surface", forecast=nothing, units="kg m-2", long_name="water equivalent of snow depth"),
    (name=:dswrf, param="DSWRF", level="surface", forecast=nothing, units="W m-2", long_name="downward short-wave radiation flux at the surface"),
    (name=:dlwrf, param="DLWRF", level="surface", forecast=nothing, units="W m-2", long_name="downward long-wave radiation flux at the surface"),
    (name=:shtfl, param="SHTFL", level="surface", forecast=nothing, units="W m-2", long_name="sensible heat flux at the surface"),
    (name=:lhtfl, param="LHTFL", level="surface", forecast=nothing, units="W m-2", long_name="latent heat flux at the surface"),
    (name=:smoke, param="MASSDEN", level="8 m above ground", forecast=nothing, units="kg m-3", long_name="near-surface smoke mass density"),
    (name=:colmd, param="COLMD", level="entire atmosphere (considered as a single layer)", forecast=nothing, units="kg m-2", long_name="vertically integrated smoke"),
    (name=:orog, param="HGT", level="surface", forecast=nothing, units="gpm", long_name="surface geopotential height (orography)"),
    (name=:lsm, param="LAND", level="surface", forecast=nothing, units="1", long_name="land-sea mask (1 = land)"),
    (name=:t, param="TMP", level="{} mb", forecast=nothing, units="K", long_name="temperature"),
    (name=:u, param="UGRD", level="{} mb", forecast=nothing, units="m s-1", long_name="wind along the grid x axis"),
    (name=:v, param="VGRD", level="{} mb", forecast=nothing, units="m s-1", long_name="wind along the grid y axis"),
    (name=:w, param="VVEL", level="{} mb", forecast=nothing, units="Pa s-1", long_name="vertical velocity (pressure)"),
    (name=:z, param="HGT", level="{} mb", forecast=nothing, units="gpm", long_name="geopotential height"),
    (name=:rh, param="RH", level="{} mb", forecast=nothing, units="%", long_name="relative humidity"),
    (name=:q, param="SPFH", level="{} mb", forecast=nothing, units="kg kg-1", long_name="specific humidity"),
]

# Order matters: schema types are referenced by every stage, the Stage
# hierarchy is referenced by transforms/sinks/sources, and execute pulls
# everything together at the bottom.
include("schema.jl")
include("pipeline.jl")
include("transforms.jl")
include("store.jl")
include("transports.jl")
include("presets.jl")
include("execute.jl")

end # module
