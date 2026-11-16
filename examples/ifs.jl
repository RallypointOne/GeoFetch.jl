# Pull a small ECMWF IFS forecast over Europe into a local Zarr store: one cycle,
# three lead times, 2 m temperature, accumulated precipitation, and temperature
# on two pressure levels at 0.25°. Only the needed GRIB messages are downloaded
# (about 4 MB instead of three ~100 MB files).
#
#     julia --project=. examples/ifs.jl [store path]
#
# `AIFS` takes the same pipeline; swap the preset to get the machine-learning
# forecast instead (its `tp` is in kg m-2 rather than m).

using GeoFetch
using Dates
using Zarr

function parseargs(args)
    length(args) ≤ 1 || error("usage: ifs.jl [store path]")
    (; path=isempty(args) ? joinpath(tempdir(), "geofetch-examples", "ifs.zarr") : only(args))
end

# IFS longitudes run from -180 to 180.
function pipeline(path::AbstractString)
    IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 6, 12]) |
        Select(vars=[:t2m, :tp, :t], level=[850, 500], lon=Between(0, 30), lat=Between(35, 60)) |
        Store(path; overwrite=true)
end

function summarize(path::AbstractString)
    g = zopen(path)
    println("store: ", path)
    foreach(("t2m", "tp", "t")) do n
        x = Array(g[n])
        println(rpad(n * ":", 7), "size ", size(x), ", range ", extrema(filter(!isnan, x)), ", ", count(isnan, x), " NaN")
    end
    println("level: ", g["level"][:], " hPa")
    println("step:  ", g["step"][:], " h")
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
