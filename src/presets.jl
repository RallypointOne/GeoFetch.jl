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
function ERA5(; start::Date, stop::Date, variables::AbstractVector{<:Union{Symbol,AbstractString}}, levels = nothing)
    error("ERA5 preset is not yet implemented — placeholder only")
end
