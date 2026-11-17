using Dates
import GRIB
import Zarr

# Longitudes (-180..180) and latitudes of the grid of the first message of the GRIB file
# at `path`, as ecCodes computes them, shaped like the decoded field.
function _griblonlat(path)
    bytes = read(path)
    GC.@preserve bytes begin
        m = GRIB.Message(bytes)
        sz = size(m["values"])
        (reshape(m["longitudes"] .- 360, sz), reshape(m["latitudes"], sz))
    end
end

# Index range from the first to the last `true` of `mask` along dim `k`.
function _hitrange(mask, k)
    hit = vec(any(mask; dims=3 - k))
    findfirst(hit):findlast(hit)
end

@testset "HRRR" begin
    dir = joinpath(@__DIR__, "fixtures", "hrrr", "hrrr.20261114", "conus")
    s0 = joinpath(dir, "hrrr.t00z.wrfsfcf00.grib2")
    s1 = joinpath(dir, "hrrr.t00z.wrfsfcf01.grib2")
    p0 = joinpath(dir, "hrrr.t00z.wrfprsf00.grib2")
    p1 = joinpath(dir, "hrrr.t00z.wrfprsf01.grib2")

    @testset "fixture" begin
        @testset "$(basename(f))" for (f, n) ∈ (s0 => 1, s1 => 3, p0 => 1, p1 => 2)
            @test length(GeoFetch._parseidx(read(f * ".idx", String))) == n
            foreach(k -> (@test size(_gribmsg(f, k)) == (1799, 1059)), 1:n)
        end
    end

    @testset "projection" begin
        g = GeoFetch._HRRR_GRID
        (x, y) = GeoFetch._lcc(g, g.lon1, g.lat1)
        @test x ≈ -2697520.14 atol=0.01
        @test y ≈ -1587306.15 atol=0.01
        # the first grid point is given east of Greenwich in the GRIB files
        @test all(GeoFetch._lcc(g, g.lon1 + 360, g.lat1) .≈ (x, y))
        @test all(GeoFetch._lcc(g, g.lon0, g.lat0) .≈ (0, 0))
        @test all(isapprox.(GeoFetch._lccinv(g, x, y), (g.lon1, g.lat1); atol=1e-9))
        @test all(isapprox.(GeoFetch._lccinv(g, 0.0, 0.0), (g.lon0, g.lat0); atol=1e-9))
        @test occursin("+proj=lcc", GeoFetch._lccproj(g))
        @test occursin("+R=6371229 ", GeoFetch._lccproj(g))
    end

    @testset "construction" begin
        src = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 15))
        @test src isa GeoFetch.GRIBRangeSource
        sch = src.schema
        @test map(d -> d.name, sch.dims) == [:x, :y, :level, :step, :time]
        @test length(GeoFetch.dim(sch, :x).values) == 1799
        @test length(GeoFetch.dim(sch, :y).values) == 1059
        @test all(≈(3000), diff(GeoFetch.dim(sch, :x).values))
        @test all(≈(3000), diff(GeoFetch.dim(sch, :y).values))
        @test GeoFetch.dim(sch, :level).values == collect(1000:-25:50)
        @test GeoFetch.dim(sch, :step).values == [0]
        @test GeoFetch.dim(sch, :time).values == collect(DateTime(2026, 11, 14):Hour(1):DateTime(2026, 11, 15, 23))
        @test map(v -> v.name, sch.vars) == map(f -> f.name, GeoFetch._HRRR_FIELDS)
        @test GeoFetch.var(sch, :t).dims == [:x, :y, :level, :step, :time]
        @test GeoFetch.var(sch, :t2m).dims == [:x, :y, :step, :time]
        @test GeoFetch.var(sch, :t2m).attrs[:coordinates] == "lon lat"
        @test occursin("+proj=lcc", sch.attrs[:crs])
        @test length(src.fields) == length(GeoFetch._HRRR_FIELDS)

        # two units per (time, step): the wrfsfc and the wrfprs file
        @test length(src.units) == 2 * 48
        @test src.units[1].payload ==
            "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20261114/conus/hrrr.t00z.wrfsfcf00.grib2"
        @test src.units[2].payload ==
            "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20261114/conus/hrrr.t00z.wrfprsf00.grib2"
        @test :t2m ∈ src.units[1].vars && :t ∉ src.units[1].vars
        @test src.units[2].vars == [:t, :u, :v, :w, :z, :rh, :q]

        # auxiliary coordinates agree with the grid ecCodes computes from the file
        @test map(c -> c.name, sch.coords) == [:lon, :lat]
        @test GeoFetch.coord(sch, :lon).dims == [:x, :y]
        (lon, lat) = _griblonlat(s0)
        @test size(GeoFetch.coord(sch, :lon).values) == (1799, 1059)
        @test maximum(abs, GeoFetch.coord(sch, :lon).values .- lon) < 1e-5
        @test maximum(abs, GeoFetch.coord(sch, :lat).values .- lat) < 1e-5

        # cycles and steps are sorted and uniqued; units are time-major
        src = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[12, 0, 12], steps=[48, 1, 48])
        @test GeoFetch.dim(src.schema, :step).values == [1, 48]
        @test GeoFetch.dim(src.schema, :time).values == [DateTime(2026, 11, 14), DateTime(2026, 11, 14, 12)]
        @test map(u -> (only(u.coords[:time]), only(u.coords[:step])), src.units[[1, 3, 5]]) ==
            [(DateTime(2026, 11, 14), 1), (DateTime(2026, 11, 14), 48), (DateTime(2026, 11, 14, 12), 1)]
        @test src.units[8].payload ==
            "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20261114/conus/hrrr.t12z.wrfprsf48.grib2"

        d = Date(2026, 11, 14)
        @test length(HRRR(start=d, stop=d, steps=0:18).units) == 2 * 24 * 19
        @test_throws ArgumentError HRRR(start=Date(2026, 11, 15), stop=d)
        @test_throws ArgumentError HRRR(start=Date(2014, 7, 29), stop=d)
        @test_throws ArgumentError HRRR(start=d, stop=d, cycles=Int[])
        @test_throws ArgumentError HRRR(start=d, stop=d, cycles=[24])
        @test_throws ArgumentError HRRR(start=d, stop=d, steps=Int[])
        @test_throws ArgumentError HRRR(start=d, stop=d, cycles=[0], steps=[49])
        @test_throws ArgumentError HRRR(start=d, stop=d, cycles=[0, 1], steps=[19])
    end

    @testset "coordinate selection" begin
        src = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0])
        (lon, lat) = (GeoFetch.coord(src.schema, :lon).values, GeoFetch.coord(src.schema, :lat).values)
        mask = (-106 .≤ lon .≤ -104) .& (39 .≤ lat .≤ 41)
        (ix, iy) = (_hitrange(mask, 1), _hitrange(mask, 2))

        (sch, us) = GeoFetch.apply_select(Select(lon=Between(-106, -104), lat=Between(39, 41)), src.schema, src.units)
        @test GeoFetch.dim(sch, :x).values == GeoFetch.dim(src.schema, :x).values[ix]
        @test GeoFetch.dim(sch, :y).values == GeoFetch.dim(src.schema, :y).values[iy]
        @test GeoFetch.coord(sch, :lon).values == lon[ix, iy]
        @test GeoFetch.coord(sch, :lat).values == lat[ix, iy]
        @test length(us) == 2
        # the rectangle contains the box and not much more
        @test count(mask) ≤ length(ix) * length(iy) < 1.2 * count(mask)

        # a selector on the dim itself is applied on top
        x = GeoFetch.dim(src.schema, :x).values
        sel = Select(lon=Between(-106, -104), lat=Between(39, 41), x=Between(x[ix[3]], x[ix[5]]))
        (sch, _) = GeoFetch.apply_select(sel, src.schema, src.units)
        @test GeoFetch.dim(sch, :x).values == x[ix[3:5]]
        @test size(GeoFetch.coord(sch, :lat).values) == (3, length(iy))

        # one coordinate alone, and a second Select on the narrowed schema
        (sch, us) = GeoFetch.apply_select(Select(lat=Between(50, 90)), src.schema, src.units)
        @test minimum(GeoFetch.coord(sch, :lat).values[:, end]) ≥ 50
        @test length(GeoFetch.dim(sch, :y).values) < 1059
        (sch, _) = GeoFetch.apply_select(Select(lon=Between(-100, -90)), sch, us)
        @test size(GeoFetch.coord(sch, :lon).values) ==
            (length(GeoFetch.dim(sch, :x).values), length(GeoFetch.dim(sch, :y).values))

        @test_throws ArgumentError GeoFetch.apply_select(Select(lon=Between(0, 10)), src.schema, src.units)
        @test_throws ArgumentError GeoFetch.CoordSpec(:lon, [:x], lon)
    end

    @testset "offline end-to-end (zarr v$zv)" for zv ∈ (2, 3)
        base = joinpath(@__DIR__, "fixtures", "hrrr")
        path = joinpath(mktempdir(), "hrrr.zarr")
        src = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 1], base=base)
        sel = Select(vars=[:t2m, :apcp, :lsm, :t], level=[850, 500], lon=Between(-106, -104), lat=Between(39, 41))
        execute(src | sel | Store(path; zarr_version=zv))
        g = Zarr.zopen(path)

        # expected crop, from the grid of the file itself
        (lon, lat) = _griblonlat(s0)
        mask = (-106 .≤ lon .≤ -104) .& (39 .≤ lat .≤ 41)
        (ix, iy) = (_hitrange(mask, 1), _hitrange(mask, 2))
        (nx, ny) = (length(ix), length(iy))
        crop(f, n) = Float32.(_gribmsg(f, n))[ix, iy]

        @test Set(keys(g.arrays)) ==
            Set(["t2m", "apcp", "lsm", "t", "x", "y", "lon", "lat", "level", "step", "time"])
        @test size(g["t2m"]) == (nx, ny, 2, 1)
        @test size(g["t"]) == (nx, ny, 2, 2, 1)
        @test eltype(g["t2m"]) == Float32

        lsm = g["lsm"][:, :, :, :]
        @test lsm[:, :, 1, 1] == crop(s0, 1)
        @test lsm[:, :, 2, 1] == crop(s1, 3)
        @test all(∈((0, 1)), lsm)

        # t2m and apcp are not in the f00 fixture
        t2m = g["t2m"][:, :, :, :]
        @test all(isnan, t2m[:, :, 1, 1])
        @test t2m[:, :, 2, 1] == crop(s1, 1)
        @test all(x -> 220 < x < 330, t2m[:, :, 2, 1])
        apcp = g["apcp"][:, :, :, :]
        @test all(isnan, apcp[:, :, 1, 1])
        @test apcp[:, :, 2, 1] == crop(s1, 2)

        t = g["t"][:, :, :, :, :]
        # level 2 = 500 hPa
        @test t[:, :, 2, 1, 1] == crop(p0, 1)
        @test t[:, :, 2, 2, 1] == crop(p1, 1)
        # level 1 = 850 hPa: not in the f00 fixture
        @test all(isnan, t[:, :, 1, 1, 1])
        @test t[:, :, 1, 2, 1] == crop(p1, 2)

        @test size(g["lon"]) == (nx, ny)
        @test eltype(g["lon"]) == Float64
        @test maximum(abs, g["lon"][:, :] .- lon[ix, iy]) < 1e-5
        @test maximum(abs, g["lat"][:, :] .- lat[ix, iy]) < 1e-5
        @test g["lon"].attrs["units"] == "degrees_east"
        @test g["x"][:] == GeoFetch.dim(src.schema, :x).values[ix]
        @test g["y"][:] == GeoFetch.dim(src.schema, :y).values[iy]
        @test g["x"].attrs["units"] == "m"
        @test g["level"][:] == [850, 500]
        @test g["step"][:] == [0, 1]
        @test g["time"][:] == [Dates.value(DateTime(2026, 11, 14) - DateTime(1970, 1, 1)) ÷ 1000]
        @test g["t2m"].attrs["units"] == "K"
        @test g["t2m"].attrs["coordinates"] == "lon lat"
        @test occursin("+proj=lcc", g.attrs["crs"])
    end

    # Opt-in: these hit the public NOAA bucket.
    if get(ENV, "GEOFETCH_LIVE_TESTS", "") == "true"
        @testset "live fetch" begin
            path = joinpath(mktempdir(), "hrrr.zarr")
            src = HRRR(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[3])
            sel = Select(vars=[:t2m, :t], level=[500], lon=Between(-106, -104), lat=Between(39, 41))
            execute(src | sel | Store(path))
            g = Zarr.zopen(path)
            t2m = g["t2m"][:, :, :, :]
            @test size(t2m)[1:2] == size(g["lon"])
            @test all(x -> 220 < x < 330, t2m)
            @test all(x -> 220 < x < 290, g["t"][:, :, :, :, :])
        end

        # guards the registry strings against typos
        @testset "live registry" begin
            dir = GeoFetch._HRRR_BASE * "/hrrr.20261114/conus/"
            sfc = GeoFetch._parseidx(GeoFetch._readtext(dir * "hrrr.t00z.wrfsfcf06.grib2.idx"))
            prs = GeoFetch._parseidx(GeoFetch._readtext(dir * "hrrr.t00z.wrfprsf06.grib2.idx"))
            @testset "$(f.name)" for f ∈ GeoFetch._HRRR_FIELDS
                fld = GeoFetch.GRIBField(f.param, f.level, f.forecast)
                if f.level == "{} mb"
                    @test all(l -> GeoFetch._findmsg(prs, fld, l) !== nothing, GeoFetch._HRRR_LEVELS)
                else
                    @test GeoFetch._findmsg(sfc, fld, nothing) !== nothing
                end
            end
        end
    end
end
