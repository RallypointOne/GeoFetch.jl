# Pull three days of NOAA OISST sea surface temperature over the North Atlantic
# into a local Zarr store (three ~1.6 MB daily files are downloaded).
#
#     julia --project=. examples/oisst.jl [store path]

using GeoFetch
using Dates
using Zarr

function parseargs(args)
    length(args) ≤ 1 || error("usage: oisst.jl [store path]")
    (; path=isempty(args) ? joinpath(tempdir(), "geofetch-examples", "oisst.zarr") : only(args))
end

# OISST longitudes run 0..360, so 280..350 is 80°W..10°W.
function pipeline(path::AbstractString)
    OISST(start=Date(2025, 1, 1), stop=Date(2025, 1, 3)) |
        Select(vars=:sst, lon=Between(280, 350), lat=Between(20, 60)) |
        Rechunk(time=3) |
        Store(path; overwrite=true)
end

function summarize(path::AbstractString)
    g = zopen(path)
    sst = Array(g["sst"])
    println("store: ", path)
    println("sst:   size ", size(sst), " over (lon, lat, zlev, time)")
    println("       range ", extrema(filter(!isnan, sst)), " °C, ", count(isnan, sst), " land cells (NaN)")
    println("time:  ", g["time"][:], " ", g["time"].attrs["units"])
end

function (@main)(args)
    o = parseargs(args)
    p = pipeline(o.path)
    display(p)
    println()
    execute(p)
    summarize(o.path)
    0
end
