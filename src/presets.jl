# Presets are the user-facing dataset constructors. Each preset returns a
# concrete *transport* source pre-configured with the right URL pattern (or
# CDS request template), schema, and unit list for one named dataset.
#
# The split: transports (in `transports.jl`) know how to move bytes; presets
# know which bytes to ask for. Adding a new dataset that fits an existing
# transport pattern means writing a new preset — no new transport code.

#-----------------------------------------------------------------------------# OISST
# NOAA Optimum Interpolation SST v2.1 (AVHRR-only). Daily 1/4° global grid.
# Each daily file is one HTTP GET, ~1.6 MB, served from NCEI public HTTPS.
const _OISST_BASE = "https://www.ncei.noaa.gov/data/sea-surface-temperature-optimum-interpolation/v2.1/access/avhrr/"

# Build an HTTPFileSource for the given date range, one FetchUnit per day.
#
# Schema dim ORDER is `[:lon, :lat, :zlev, :time]` — that is, NCDatasets'
# in-memory order for OISST files (the files declare dims as
# `(time, zlev, lat, lon)`, but NCDatasets returns arrays in the reversed
# order due to column-major Julia vs. row-major NetCDF).
#
# Native chunks: each daily file delivers the full lon/lat grid in one shot,
# and one timestep. So lon=1440, lat=720, zlev=1, time=1 are the natural
# chunks; downstream Rechunk(time=N) bundles N days per output chunk.
"""
    OISST(; start, stop)

NOAA Optimum Interpolation Sea Surface Temperature (OISST) v2.1, AVHRR-only:
daily fields on a 0.25° global grid, read from NCEI over HTTPS. Returns an
`HTTPFileSource` with one NetCDF file (about 1.6 MB) per day from `start` to
`stop` (`Date`s, inclusive).

# Dimensions
- `lon`: degrees east, 0.125 to 359.875.
- `lat`: degrees north, -89.875 to 89.875.
- `zlev`: a single level at 0 m.
- `time`: one `Date` per day.

# Variables
All on `(lon, lat, zlev, time)` as `Float32`, with `NaN` where there is no data
(such as `sst` over land): `sst` (sea surface temperature, °C), `anom` (anomaly
from the climatological mean, °C), `err` (estimated error standard deviation,
°C), `ice` (sea-ice concentration).

# Example
```julia
using GeoFetch, Dates

pipeline = OISST(start=Date(2025, 1, 1), stop=Date(2025, 1, 3)) |
    Select(vars=:sst, lon=Between(280, 350), lat=Between(20, 60)) |
    Store("oisst.zarr")
execute(pipeline)
```
"""
function OISST(; start::Date, stop::Date)
    start <= stop || throw(ArgumentError("OISST: start ($start) must be <= stop ($stop)"))
    dates = collect(start:Day(1):stop)

    lon = collect(range(0.125f0, 359.875f0; length = 1440))
    lat = collect(range(-89.875f0, 89.875f0; length = 720))

    sch = SourceSchema(
        [DimSpec(:lon,  lon;   chunk = 1440, attrs = Dict(:units => "degrees_east")),
         DimSpec(:lat,  lat;   chunk = 720,  attrs = Dict(:units => "degrees_north")),
         DimSpec(:zlev, [0.0f0]; chunk = 1, attrs = Dict(:units => "meters")),
         DimSpec(:time, dates;   chunk = 1, attrs = Dict(:standard_name => "time"))],
        [VarSpec(:sst,  [:lon, :lat, :zlev, :time], Float32; attrs = Dict(:units => "degrees_C", :long_name => "sea surface temperature")),
         VarSpec(:anom, [:lon, :lat, :zlev, :time], Float32; attrs = Dict(:units => "degrees_C", :long_name => "anomaly from mean")),
         VarSpec(:err,  [:lon, :lat, :zlev, :time], Float32; attrs = Dict(:units => "degrees_C", :long_name => "estimated error std")),
         VarSpec(:ice,  [:lon, :lat, :zlev, :time], Float32; attrs = Dict(:units => "fraction",   :long_name => "sea-ice fraction"))];
        attrs = Dict(:dataset => "OISST v2.1 AVHRR-only", :source => "NOAA NCEI"),
    )

    # One unit per day: covers the single :time coord for that day; lon, lat,
    # zlev are full-extent (omitted from `coords` => "all of that dim").
    units = FetchUnit[FetchUnit(
        Dict{Symbol,AbstractVector}(:time => [d]),
        Symbol[],
        _oisst_url(d),
    ) for d in dates]

    HTTPFileSource(; schema = sch, units = units, format = :netcdf)
end

function _oisst_url(d::Date)
    yyyy = lpad(year(d),  4, '0')
    mm   = lpad(month(d), 2, '0')
    dd   = lpad(day(d),   2, '0')
    string(_OISST_BASE, yyyy, mm, "/", "oisst-avhrr-v02r01.", yyyy, mm, dd, ".nc")
end

#-----------------------------------------------------------------------------# ERA5 (stub)
# ECMWF ERA5 reanalysis via Copernicus CDS. Will be a CDSAPISource preset:
# one FetchUnit per (variable, month) tuple, payload = CDS request body.
# Not yet implemented — the constructor errors on call.
"""
    ERA5(; start, stop, variables, levels=nothing)

ECMWF ERA5 reanalysis from the Copernicus Climate Data Store. Not implemented
yet: calling it throws an error.
"""
function ERA5(; start::Date, stop::Date, variables::AbstractVector{<:Union{Symbol,AbstractString}}, levels = nothing)
    error("ERA5 preset is not yet implemented — placeholder only")
end

#-----------------------------------------------------------------------------# GFS
"""
    GFS(; start, stop, cycles=0:6:18, steps=[0], resolution="0p25", base=...)

NOAA Global Forecast System (GFS) forecasts on a regular global lat/lon grid,
read from the `pgrb2` GRIB2 files of the public AWS bucket `noaa-gfs-bdp-pds`.
Returns a `GRIBRangeSource`: only the GRIB messages of the selected variables
and levels are downloaded, located through the `.idx` sidecar of each file and
fetched with HTTP byte-range requests.

# Keyword arguments
- `start`, `stop`: first and last cycle `Date` (inclusive). The bucket layout
  used here starts on 2021-03-23.
- `cycles`: initialization hours (UTC) to use on each date, any of 0, 6, 12, 18.
- `steps`: forecast lead times in hours, within `0:384`. At `"0p25"` every hour
  up to 120 is available, beyond that (and at the other resolutions) only
  multiples of 3.
- `resolution`: `"0p25"`, `"0p50"` or `"1p00"` (grid spacing in degrees).
- `base`: root location of the `gfs.YYYYMMDD/HH/atmos/` tree. Defaults to the
  AWS bucket; pass the URL of a mirror or a local directory with the same
  layout (GRIB files plus their `.idx` sidecars) to read from there instead.

# Dimensions
- `lon`: degrees east, from 0 eastwards.
- `lat`: degrees north, from 90 down to -90 (north first).
- `level`: isobaric level in hPa, from 1000 up to 1 (33 levels).
- `step`: forecast lead time in hours.
- `time`: forecast initialization time (the cycle), one per date and cycle.

One file, hence one fetch unit, exists per `(time, step)`.

# Variables
On `(lon, lat, step, time)`: `t2m`, `d2m`, `rh2m`, `u10`, `v10`, `gust`,
`prmsl`, `sp`, `pwat`, `cape`, `tcc`, `apcp`, `orog`, `lsm`.

On `(lon, lat, level, step, time)`: `t`, `u`, `v`, `w`, `z`, `rh`, `q`.

All are stored as `Float32`. `apcp` is the precipitation accumulated since
forecast start.

!!! warning
    Without a `Select(vars=...)` every variable above is fetched on every level:
    about 245 sequential range requests and on the order of 1 GB in memory per
    `(cycle, step)` at `"0p25"`. Select the variables, levels and region you
    need.

A message that a file does not contain is stored as `NaN` rather than raising
an error, for example `apcp` at step 0 or a level that a variable lacks.

# Example
```julia
using GeoFetch, Dates

pipeline = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), cycles=[0], steps=0:6:24) |
    Select(vars=[:t2m, :t], level=[850, 500], lon=Between(0, 30), lat=Between(30, 60)) |
    Store("gfs.zarr")
execute(pipeline)
```
"""
function GFS(;
    start::Date,
    stop::Date,
    cycles=0:6:18,
    steps=[0],
    resolution::AbstractString="0p25",
    base::AbstractString=_GFS_BASE,
)
    start ≤ stop || throw(ArgumentError("GFS: start ($start) must be <= stop ($stop)"))
    start ≥ Date(2021, 3, 23) || throw(ArgumentError("GFS: start ($start) must be on or after 2021-03-23"))
    resolution ∈ ("0p25", "0p50", "1p00") ||
        throw(ArgumentError("GFS: resolution must be \"0p25\", \"0p50\" or \"1p00\", got \"$resolution\""))
    isempty(cycles) && throw(ArgumentError("GFS: cycles must not be empty"))
    all(∈((0, 6, 12, 18)), cycles) || throw(ArgumentError("GFS: cycles must be among 0, 6, 12, 18, got $cycles"))
    isempty(steps) && throw(ArgumentError("GFS: steps must not be empty"))
    all(∈(0:384), steps) || throw(ArgumentError("GFS: steps must be within 0:384, got $steps"))
    all(h -> (h ≤ 120 && resolution == "0p25") || h % 3 == 0, steps) ||
        throw(ArgumentError("GFS: steps must be multiples of 3 (hourly only up to 120 at \"0p25\"), got $steps"))

    Δ = parse(Float64, replace(resolution, "p" => "."))
    lon = collect(0:Δ:360-Δ)
    lat = collect(90:-Δ:-90)
    hs = sort(unique(map(Int, steps)))
    cs = sort(unique(map(Int, cycles)))
    ts = vec(map(((c, d),) -> DateTime(d) + Hour(c), Iterators.product(cs, start:Day(1):stop)))

    dims = [
        DimSpec(:lon, lon; chunk=length(lon), attrs=Dict(:units => "degrees_east")),
        DimSpec(:lat, lat; chunk=length(lat), attrs=Dict(:units => "degrees_north")),
        DimSpec(:level, _GFS_LEVELS; chunk=1, attrs=Dict(:units => "hPa")),
        DimSpec(:step, hs; chunk=1, attrs=Dict(:units => "hours", :long_name => "forecast lead time")),
        DimSpec(:time, ts; chunk=1, attrs=Dict(:long_name => "forecast initialization time")),
    ]
    vars = map(_GFS_FIELDS) do f
        ds = occursin("{}", f.level) ? [:lon, :lat, :level, :step, :time] : [:lon, :lat, :step, :time]
        VarSpec(f.name, ds, Float32; attrs=Dict(:units => f.units, :long_name => f.long_name))
    end
    sch = SourceSchema(dims, vars; attrs=Dict(:dataset => "NOAA GFS $resolution", :source => String(base)))

    # One unit per GRIB file, i.e. per (time, step), time-major; lon, lat and
    # level are full-extent.
    units = vec(map(Iterators.product(hs, ts)) do (h, t)
        FetchUnit(; coords=Dict(:time => [t], :step => [h]), payload=_gfs_url(base, resolution, t, h))
    end)
    fields = Dict(map(f -> f.name => GRIBField(f.param, f.level, f.forecast), _GFS_FIELDS))

    GRIBRangeSource(; schema=sch, units, fields)
end

# Location of the pgrb2 file of cycle `t`, lead hour `h`, under `base`.
function _gfs_url(base::AbstractString, resolution::AbstractString, t::DateTime, h::Integer)
    hh = lpad(hour(t), 2, '0')
    string(base, "/gfs.", Dates.format(t, "yyyymmdd"), "/", hh, "/atmos/gfs.t", hh, "z.pgrb2.",
           resolution, ".f", lpad(h, 3, '0'))
end

#-----------------------------------------------------------------------------# ECMWF open data: IFS, AIFS
"""
    IFS(; start, stop, cycles=0:6:18, steps=[0], resolution="0p25", base=...)

ECMWF Integrated Forecasting System (IFS) high-resolution deterministic
forecasts on a regular global lat/lon grid, read from the GRIB2 files of the
[ECMWF open data](https://www.ecmwf.int/en/forecasts/datasets/open-data)
(CC-BY-4.0). Returns a `GRIBRangeSource`: only the GRIB messages of the
selected variables and levels are downloaded, located through the `.index`
sidecar of each file and fetched with HTTP byte-range requests.

# Keyword arguments
- `start`, `stop`: first and last cycle `Date` (inclusive). The file layout
  used here starts on 2024-03-01.
- `cycles`: initialization hours (UTC) to use on each date, any of 0, 6, 12, 18.
- `steps`: forecast lead times in hours: multiples of 3 up to 144, and for the
  0 and 12 UTC cycles also multiples of 6 up to 360. Older runs are shorter:
  the 6 and 18 UTC cycles end at 90 before 2026-05-12, the 0 and 12 UTC cycles
  at 240 before November 2024.
- `resolution`: `"0p25"`, or `"0p1"` (0.1°, from 2026-10-21).
- `base`: root location of the `YYYYMMDD/HHz/ifs/` tree. Defaults to the
  Google Cloud mirror; pass the URL of another mirror (the AWS bucket
  `https://ecmwf-forecasts.s3.eu-central-1.amazonaws.com`, or
  `https://data.ecmwf.int/forecasts`, which keeps about the last 4 days) or a
  local directory with the same layout (GRIB files plus their `.index`
  sidecars) to read from there instead.

# Dimensions
- `lon`: degrees east, from -180 eastwards (unlike `GFS`, which starts at 0).
- `lat`: degrees north, from 90 down to -90 (north first).
- `level`: isobaric level in hPa, from 1000 up to 10 (14 levels).
- `step`: forecast lead time in hours.
- `time`: forecast initialization time (the cycle), one per date and cycle.

One file, hence one fetch unit, exists per `(time, step)`; at `"0p1"` there are
two, one with the pressure-level variables and one with all the others.

# Variables
On `(lon, lat, step, time)`: `t2m`, `d2m`, `u10`, `v10`, `u100`, `v100`,
`fg10`, `mx2t3`, `mn2t3`, `skt`, `msl`, `sp`, `tcc`, `lcc`, `mcc`, `hcc`,
`tcw`, `tcwv`, `tclw`, `tciw`, `tcrw`, `mucape`, `tp`, `cp`, `sf`, `ro`,
`tprate`, `ptype`, `ssrd`, `ssr`, `strd`, `str`, `ttr`, `ewss`, `nsss`, `sd`,
`rsn`, `asn`, `sithick`, `zos`, `sve`, `svn`, `lsm`, `zsfc`, `sdor`, `slor`,
and the soil layers `sot1` to `sot4` and `vsw1` to `vsw4`.

On `(lon, lat, level, step, time)`: `t`, `u`, `v`, `w`, `z`, `gh`, `q`, `r`,
`d`, `vo`.

Names are the ECMWF short names, except that a leading number moves to the end
(`2t` is `t2m`, `10u` is `u10`, `10fg` is `fg10`), the surface geopotential `z`
is `zsfc`, and the soil parameters `sot` and `vsw` carry their layer number.
All are stored as `Float32`. `tp`, `cp`, `sf`, `ro` and the radiation and
stress fields are accumulated since forecast start; `tp` is in metres. `z` is
the geopotential in m² s⁻² and `gh` the geopotential height.

!!! warning
    Without a `Select(vars=...)` every variable above is fetched on every level:
    about 190 sequential range requests and on the order of 1 GB in memory per
    `(cycle, step)` at `"0p25"`, and about six times that at `"0p1"`. Select the
    variables, levels and region you need.

A message that a file does not contain is stored as `NaN` rather than raising
an error. That applies to `zsfc`, `sdor` and `slor` at any step but 0, to
`mx2t3` and `mn2t3` beyond step 144, and to the many variables and levels that
were added to the open data over time (in March 2024 it had 11 single-level
variables and 9 levels). Ocean fields are `NaN` over land.

# Example
```julia
using GeoFetch, Dates

pipeline = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=0:6:24) |
    Select(vars=[:t2m, :t], level=[850, 500], lon=Between(0, 30), lat=Between(30, 60)) |
    Store("ifs.zarr")
execute(pipeline)
```
"""
function IFS(;
    start::Date,
    stop::Date,
    cycles=0:6:18,
    steps=[0],
    resolution::AbstractString="0p25",
    base::AbstractString=_ECMWF_BASE,
)
    _ecmwf_check("IFS", start, stop, Date(2024, 3, 1), cycles, steps)
    resolution ∈ ("0p25", "0p1") ||
        throw(ArgumentError("IFS: resolution must be \"0p25\" or \"0p1\", got \"$resolution\""))
    resolution == "0p1" && start < Date(2026, 10, 21) &&
        throw(ArgumentError("IFS: resolution \"0p1\" starts on 2026-10-21, got start = $start"))
    all(h -> h ∈ 0:3:144 || h ∈ 150:6:360, steps) ||
        throw(ArgumentError("IFS: steps must be multiples of 3 up to 144 or multiples of 6 up to 360, got $steps"))
    hmax = start < Date(2026, 5, 12) ? 90 : 144
    all(∈((0, 12)), cycles) || all(≤(hmax), steps) ||
        throw(ArgumentError("IFS: the 6 and 18 UTC cycles only have steps up to $hmax, got $steps"))
    _ecmwf("ifs", "ECMWF IFS", _IFS_FIELDS; start, stop, cycles, steps, resolution, base)
end

"""
    AIFS(; start, stop, cycles=0:6:18, steps=[0], base=...)

ECMWF Artificial Intelligence Forecasting System (AIFS Single) deterministic
forecasts on a regular global 0.25° lat/lon grid, read from the GRIB2 files of
the [ECMWF open data](https://www.ecmwf.int/en/forecasts/datasets/open-data)
(CC-BY-4.0). Works like `IFS`, with which it shares the file layout, the
dimensions and the variable naming.

# Keyword arguments
- `start`, `stop`: first and last cycle `Date` (inclusive). The file layout
  used here starts on 2025-03-01.
- `cycles`: initialization hours (UTC) to use on each date, any of 0, 6, 12, 18.
- `steps`: forecast lead times in hours, multiples of 6 up to 360.
- `base`: root location of the `YYYYMMDD/HHz/aifs-single/` tree, see `IFS`.

# Dimensions
`lon` (from -180 eastwards), `lat` (north first), `level` (hPa, 14 levels from
1000 up to 10), `step` and `time`, as for `IFS`. One file, hence one fetch
unit, exists per `(time, step)`.

# Variables
On `(lon, lat, step, time)`: `t2m`, `d2m`, `u10`, `v10`, `u100`, `v100`, `skt`,
`msl`, `sp`, `tcc`, `lcc`, `mcc`, `hcc`, `tcw`, `tp`, `cp`, `sf`, `rowe`,
`fscov`, `ssrd`, `strd`, `lsm`, `zsfc`, `sdor`, `slor`, and the soil layers
`sot1`, `sot2`, `vsw1` and `vsw2`.

On `(lon, lat, level, step, time)`: `t`, `u`, `v`, `w`, `z`, `gh`, `q`.

All are stored as `Float32`. Some units differ from `IFS`: `tp`, `cp` and `sf`
are in kg m⁻² (accumulated since forecast start) and cloud cover is in %.

!!! warning
    Without a `Select(vars=...)` every variable above is fetched on every level:
    about 125 sequential range requests per `(cycle, step)`. Select the
    variables, levels and region you need.

A message that a file does not contain is stored as `NaN` rather than raising
an error, for example `lsm`, `zsfc`, `sdor` and `slor` at any step but 0, or
variables and levels that were added to the open data after the selected dates.

# Example
```julia
using GeoFetch, Dates

pipeline = AIFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=0:6:24) |
    Select(vars=[:t2m, :tp], lon=Between(0, 30), lat=Between(30, 60)) |
    Store("aifs.zarr")
execute(pipeline)
```
"""
function AIFS(;
    start::Date,
    stop::Date,
    cycles=0:6:18,
    steps=[0],
    base::AbstractString=_ECMWF_BASE,
)
    _ecmwf_check("AIFS", start, stop, Date(2025, 3, 1), cycles, steps)
    all(∈(0:6:360), steps) || throw(ArgumentError("AIFS: steps must be multiples of 6 up to 360, got $steps"))
    _ecmwf("aifs-single", "ECMWF AIFS Single", _AIFS_FIELDS; start, stop, cycles, steps, resolution="0p25", base)
end

# Argument checks shared by the ECMWF presets; `first` is the first supported date.
function _ecmwf_check(name::AbstractString, start::Date, stop::Date, first::Date, cycles, steps)
    start ≤ stop || throw(ArgumentError("$name: start ($start) must be <= stop ($stop)"))
    start ≥ first || throw(ArgumentError("$name: start ($start) must be on or after $first"))
    isempty(cycles) && throw(ArgumentError("$name: cycles must not be empty"))
    all(∈((0, 6, 12, 18)), cycles) || throw(ArgumentError("$name: cycles must be among 0, 6, 12, 18, got $cycles"))
    isempty(steps) && throw(ArgumentError("$name: steps must not be empty"))
    nothing
end

# GRIBRangeSource over the ECMWF open data tree of `model` (the directory name
# below `HHz/`), with the variables of the registry `fields`.
function _ecmwf(
    model::AbstractString,
    title::AbstractString,
    fields;
    start::Date,
    stop::Date,
    cycles,
    steps,
    resolution::AbstractString,
    base::AbstractString,
)
    Δ = parse(Float64, replace(resolution, "p" => "."))
    lon = collect(range(-180.0; step=Δ, length=round(Int, 360 / Δ)))
    lat = collect(range(90.0; step=-Δ, length=round(Int, 180 / Δ) + 1))
    hs = sort(unique(map(Int, steps)))
    cs = sort(unique(map(Int, cycles)))
    ts = vec(map(((c, d),) -> DateTime(d) + Hour(c), Iterators.product(cs, start:Day(1):stop)))

    dims = [
        DimSpec(:lon, lon; chunk=length(lon), attrs=Dict(:units => "degrees_east")),
        DimSpec(:lat, lat; chunk=length(lat), attrs=Dict(:units => "degrees_north")),
        DimSpec(:level, _ECMWF_LEVELS; chunk=1, attrs=Dict(:units => "hPa")),
        DimSpec(:step, hs; chunk=1, attrs=Dict(:units => "hours", :long_name => "forecast lead time")),
        DimSpec(:time, ts; chunk=1, attrs=Dict(:long_name => "forecast initialization time")),
    ]
    ispl(f) = occursin("{}", f.level)
    vars = map(fields) do f
        ds = ispl(f) ? [:lon, :lat, :level, :step, :time] : [:lon, :lat, :step, :time]
        VarSpec(f.name, ds, Float32; attrs=Dict(:units => f.units, :long_name => f.long_name))
    end
    attrs = Dict(:dataset => "$title $resolution", :source => String(base), :license => "CC-BY-4.0")
    sch = SourceSchema(dims, vars; attrs)

    # One unit per GRIB file, time-major; lon, lat and level are full-extent.
    # At 0p25 that is one file per (time, step). At 0p1 the pressure-level
    # variables are in a file of their own, so there are two units per
    # (time, step), each restricted to the variables of its file.
    parts = if resolution == "0p1"
        ["-sfc" => map(f -> f.name, filter(!ispl, fields)), "-pl" => map(f -> f.name, filter(ispl, fields))]
    else
        ["" => Symbol[]]
    end
    units = vec(map(Iterators.product(parts, hs, ts)) do ((sfx, vs), h, t)
        FetchUnit(;
            coords=Dict(:time => [t], :step => [h]),
            vars=vs,
            payload=_ecmwf_url(base, model, resolution, t, h, sfx),
        )
    end)
    gf = Dict(map(f -> f.name => GRIBField(f.param, f.level), fields))

    GRIBRangeSource(; schema=sch, units, fields=gf, index=:ecmwf)
end

# Location of the ECMWF open data file of cycle `t`, lead hour `h`, under
# `base`; `sfx` is the file-name suffix of the 0p1 split ("-sfc", "-pl") or "".
# The 6 and 18 UTC IFS runs were published as stream `scda` until 2026-05-11.
function _ecmwf_url(
    base::AbstractString,
    model::AbstractString,
    resolution::AbstractString,
    t::DateTime,
    h::Integer,
    sfx::AbstractString,
)
    scda = model == "ifs" && hour(t) ∈ (6, 18) && Date(t) < Date(2026, 5, 12)
    stream = scda ? "scda" : "oper"
    string(base, "/", Dates.format(t, "yyyymmdd"), "/", lpad(hour(t), 2, '0'), "z/", model, "/", resolution, "/",
           stream, "/", Dates.format(t, "yyyymmddHH"), "0000-", h, "h-", stream, "-fc", sfx, ".grib2")
end

#-----------------------------------------------------------------------------# HRRR
"""
    HRRR(; start, stop, cycles=0:23, steps=[0], base=...)

NOAA High-Resolution Rapid Refresh (HRRR) forecasts over the contiguous United
States on a 3 km grid, read from the GRIB2 files of the public AWS bucket
`noaa-hrrr-bdp-pds`. Returns a `GRIBRangeSource`: only the GRIB messages of the
selected variables and levels are downloaded, located through the `.idx`
sidecar of each file and fetched with HTTP byte-range requests.

# Keyword arguments
- `start`, `stop`: first and last cycle `Date` (inclusive). The bucket starts
  on 2014-07-30.
- `cycles`: initialization hours (UTC) to use on each date, within `0:23`.
- `steps`: forecast lead times in hours: up to 18, and for the 0, 6, 12 and 18
  UTC cycles up to 48. Older runs are shorter (36 before December 2020, 18
  before July 2018).
- `base`: root location of the `hrrr.YYYYMMDD/conus/` tree. Defaults to the AWS
  bucket; pass the URL of a mirror or a local directory with the same layout
  (GRIB files plus their `.idx` sidecars) to read from there instead.

# Dimensions
The grid is regular in a Lambert conformal projection, not in longitude and
latitude, so the horizontal dimensions are the projected coordinates.
- `x`: projected easting in m, 1799 points from west to east.
- `y`: projected northing in m, 1059 points from south to north.
- `level`: isobaric level in hPa, from 1000 up to 50 in steps of 25 (39 levels).
- `step`: forecast lead time in hours.
- `time`: forecast initialization time (the cycle), one per date and cycle.

`lon` (degrees east, about -134 to -61) and `lat` (degrees north, about 21 to
53) are two-dimensional auxiliary coordinates on `(x, y)`, stored next to the
variables. A `Select` on `lon` and `lat` keeps the smallest `x`/`y` rectangle
that contains the matching grid points. The projection is recorded as a PROJ
string in the `crs` attribute of the store.

Two files, hence two fetch units, exist per `(time, step)`: `wrfsfc` with the
single-level variables and `wrfprs` with the pressure-level variables.

# Variables
On `(x, y, step, time)`: `t2m`, `d2m`, `rh2m`, `q2m`, `u10`, `v10`, `u80`,
`v80`, `gust`, `prmsl`, `sp`, `skt`, `pwat`, `cape`, `cin`, `tcc`, `lcc`,
`mcc`, `hcc`, `vis`, `refc`, `hpbl`, `prate`, `apcp`, `asnow`, `snod`, `weasd`,
`dswrf`, `dlwrf`, `shtfl`, `lhtfl`, `smoke`, `colmd`, `orog`, `lsm`.

On `(x, y, level, step, time)`: `t`, `u`, `v`, `w`, `z`, `rh`, `q`.

All are stored as `Float32`. `apcp` and `asnow` are accumulated since forecast
start.

!!! warning
    Wind components (`u10`, `v10`, `u80`, `v80`, `u`, `v`) are relative to the
    grid: `u` is along `x` and `v` along `y`, which away from the central
    meridian (97.5° W) is not due east and north.

!!! warning
    Without a `Select(vars=...)` every variable above is fetched on every level:
    about 310 sequential range requests and several GB in memory per
    `(cycle, step)`. Select the variables, levels and region you need.

A message that a file does not contain is stored as `NaN` rather than raising
an error, for example variables that were added in later versions of the model
(such as `smoke` and `colmd`, added in December 2020).

# Example
```julia
using GeoFetch, Dates

pipeline = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=0:3) |
    Select(vars=[:t2m, :t], level=[850, 500], lon=Between(-110, -100), lat=Between(35, 42)) |
    Store("hrrr.zarr")
execute(pipeline)
```
"""
function HRRR(;
    start::Date,
    stop::Date,
    cycles=0:23,
    steps=[0],
    base::AbstractString=_HRRR_BASE,
)
    start ≤ stop || throw(ArgumentError("HRRR: start ($start) must be <= stop ($stop)"))
    start ≥ Date(2014, 7, 30) || throw(ArgumentError("HRRR: start ($start) must be on or after 2014-07-30"))
    isempty(cycles) && throw(ArgumentError("HRRR: cycles must not be empty"))
    all(∈(0:23), cycles) || throw(ArgumentError("HRRR: cycles must be within 0:23, got $cycles"))
    isempty(steps) && throw(ArgumentError("HRRR: steps must not be empty"))
    all(∈(0:48), steps) || throw(ArgumentError("HRRR: steps must be within 0:48, got $steps"))
    all(∈((0, 6, 12, 18)), cycles) || all(≤(18), steps) ||
        throw(ArgumentError("HRRR: only the 0, 6, 12 and 18 UTC cycles have steps beyond 18, got $steps"))

    g = _HRRR_GRID
    (x0, y0) = _lcc(g, g.lon1, g.lat1)
    x = collect(range(x0; step=g.Δ, length=g.nx))
    y = collect(range(y0; step=g.Δ, length=g.ny))
    ll = map(((x, y),) -> _lccinv(g, x, y), Iterators.product(x, y))
    hs = sort(unique(map(Int, steps)))
    cs = sort(unique(map(Int, cycles)))
    ts = vec(map(((c, d),) -> DateTime(d) + Hour(c), Iterators.product(cs, start:Day(1):stop)))

    dims = [
        DimSpec(:x, x; chunk=g.nx, attrs=Dict(:units => "m", :standard_name => "projection_x_coordinate")),
        DimSpec(:y, y; chunk=g.ny, attrs=Dict(:units => "m", :standard_name => "projection_y_coordinate")),
        DimSpec(:level, _HRRR_LEVELS; chunk=1, attrs=Dict(:units => "hPa")),
        DimSpec(:step, hs; chunk=1, attrs=Dict(:units => "hours", :long_name => "forecast lead time")),
        DimSpec(:time, ts; chunk=1, attrs=Dict(:long_name => "forecast initialization time")),
    ]
    coords = [
        CoordSpec(:lon, [:x, :y], map(first, ll); attrs=Dict(:units => "degrees_east", :standard_name => "longitude")),
        CoordSpec(:lat, [:x, :y], map(last, ll); attrs=Dict(:units => "degrees_north", :standard_name => "latitude")),
    ]
    ispl(f) = occursin("{}", f.level)
    vars = map(_HRRR_FIELDS) do f
        ds = ispl(f) ? [:x, :y, :level, :step, :time] : [:x, :y, :step, :time]
        VarSpec(f.name, ds, Float32; attrs=Dict(:units => f.units, :long_name => f.long_name, :coordinates => "lon lat"))
    end
    attrs = Dict(:dataset => "NOAA HRRR CONUS 3 km", :source => String(base), :crs => _lccproj(g))
    sch = SourceSchema(dims, vars; attrs, coords)

    # One unit per GRIB file, time-major; x, y and level are full-extent. The
    # pressure-level variables are in a file of their own, so there are two
    # units per (time, step), each restricted to the variables of its file.
    parts = [
        "wrfsfc" => map(f -> f.name, filter(!ispl, _HRRR_FIELDS)),
        "wrfprs" => map(f -> f.name, filter(ispl, _HRRR_FIELDS)),
    ]
    units = vec(map(Iterators.product(parts, hs, ts)) do ((p, vs), h, t)
        FetchUnit(; coords=Dict(:time => [t], :step => [h]), vars=vs, payload=_hrrr_url(base, p, t, h))
    end)
    fields = Dict(map(f -> f.name => GRIBField(f.param, f.level, f.forecast), _HRRR_FIELDS))

    GRIBRangeSource(; schema=sch, units, fields)
end

# Location of the HRRR CONUS file of `product` ("wrfsfc" or "wrfprs"), cycle
# `t`, lead hour `h`, under `base`.
function _hrrr_url(base::AbstractString, product::AbstractString, t::DateTime, h::Integer)
    string(base, "/hrrr.", Dates.format(t, "yyyymmdd"), "/conus/hrrr.t", lpad(hour(t), 2, '0'), "z.", product,
           "f", lpad(h, 2, '0'), ".grib2")
end

# Lambert conformal conic projection on a sphere, for a grid `g` (such as
# `_HRRR_GRID`) with a single standard parallel `g.lat0`, which is also the
# latitude of origin, central meridian `g.lon0` and radius `g.R`. Maps
# longitude `λ` and latitude `φ` in degrees to `(x, y)` in metres. Northern
# hemisphere only (`g.lat0 > 0`).
function _lcc(g, λ, φ)
    n = sind(g.lat0)
    ρ0 = g.R * cosd(g.lat0) / n
    ρ = ρ0 * (tand(45 + g.lat0 / 2) / tand(45 + φ / 2))^n
    θ = n * deg2rad(rem(λ - g.lon0, 360, RoundNearest))
    (ρ * sin(θ), ρ0 - ρ * cos(θ))
end

# Inverse of `_lcc`: `(x, y)` in metres to `(λ, φ)` in degrees, with `λ`
# continuous across the grid around `g.lon0`.
function _lccinv(g, x, y)
    n = sind(g.lat0)
    ρ0 = g.R * cosd(g.lat0) / n
    θ = atan(x, ρ0 - y)
    φ = 2 * atand((ρ0 / hypot(x, ρ0 - y))^(1 / n) * tand(45 + g.lat0 / 2)) - 90
    (g.lon0 + rad2deg(θ) / n, φ)
end

# PROJ string of the projection of `_lcc`.
function _lccproj(g)
    "+proj=lcc +lat_0=$(g.lat0) +lon_0=$(g.lon0) +lat_1=$(g.lat0) +lat_2=$(g.lat0) +x_0=0 +y_0=0 +R=$(g.R) +units=m +no_defs"
end
