# Pull a small NOAA GFS forecast over Europe into a local Zarr store: one cycle,
# three lead times, 2 m temperature, accumulated precipitation, and temperature
# on two pressure levels at 0.25°. Only the needed GRIB messages are downloaded
# (under 10 MB instead of three ~540 MB files).
#
#     julia --project=. examples/gfs.jl [store path]

using GeoFetch
using Dates
using Zarr

function parseargs(args)
    length(args) ≤ 1 || error("usage: gfs.jl [store path]")
    (; path=isempty(args) ? joinpath(tempdir(), "geofetch-examples", "gfs.zarr") : only(args))
end

function pipeline(path::AbstractString)
    GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), cycles=[0], steps=[0, 6, 12]) |
        Select(vars=[:t2m, :apcp, :t], level=[850, 500], lon=Between(0, 30), lat=Between(35, 60)) |
        Store(path; overwrite=true)
end

# `apcp` has no message at step 0 (the analysis), so that slab is all NaN.
function summarize(path::AbstractString)
    g = zopen(path)
    println("store: ", path)
    foreach(("t2m", "apcp", "t")) do n
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
