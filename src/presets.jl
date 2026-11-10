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
