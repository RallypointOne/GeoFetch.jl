# Pull a small NOAA HRRR forecast over Colorado into a local Zarr store: one
# cycle, three lead times, 2 m temperature, accumulated precipitation, and
# temperature on two pressure levels on the 3 km grid. Only the needed GRIB
# messages are downloaded (under 10 MB instead of six files of 140 to 390 MB).
#
# The HRRR grid is regular in a Lambert conformal projection, so its dims are
# the projected `x` and `y`; `lon` and `lat` are 2D arrays, which `Select`
# turns into the enclosing `x`/`y` rectangle.
#
#     julia --project=. examples/hrrr.jl [store path]

using GeoFetch
using Dates
using Zarr

function parseargs(args)
    length(args) ≤ 1 || error("usage: hrrr.jl [store path]")
    (; path=isempty(args) ? joinpath(tempdir(), "geofetch-examples", "hrrr.zarr") : only(args))
end

function pipeline(path::AbstractString)
    HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 1, 2]) |
        Select(vars=[:t2m, :apcp, :t], level=[850, 500], lon=Between(-109, -102), lat=Between(37, 41)) |
        Store(path; overwrite=true)
end

function summarize(path::AbstractString)
    g = zopen(path)
    println("store: ", path)
    foreach(("t2m", "apcp", "t")) do n
        x = Array(g[n])
        println(rpad(n * ":", 7), "size ", size(x), ", range ", extrema(filter(!isnan, x)), ", ", count(isnan, x), " NaN")
    end
    println("lon:   size ", size(g["lon"]), ", range ", extrema(Array(g["lon"])))
    println("lat:   size ", size(g["lat"]), ", range ", extrema(Array(g["lat"])))
    println("level: ", g["level"][:], " hPa")
    println("step:  ", g["step"][:], " h")
    println("time:  ", g["time"][:], " ", g["time"].attrs["units"])
    println("crs:   ", g.attrs["crs"])
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
