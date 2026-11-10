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
                 like `OISST(...)` or `GFS(...)` build a transport source
                 pre-configured for a known dataset.
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
- Presets: `OISST`, `ERA5`, `GFS`
- Entry point: `execute`
"""
module GeoFetch

using Dates
using Downloads
using Zarr
using NCDatasets
import GRIB

export Pipeline, Stage, Source, Transform, Sink
export Select, Rechunk, Store
export All, Between
export OISST, ERA5, GFS
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
