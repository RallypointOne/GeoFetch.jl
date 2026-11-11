using Dates
import Zarr

# The same message as the store holds it: Float32, cropped to lon 10..20, lat 50..40.
_gfscrop(path, n) = Float32.(_gribmsg(path, n))[11:21, 41:51]

@testset "GFS" begin
    @testset "construction" begin
        src = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 9))
        @test src isa GeoFetch.GRIBRangeSource
        sch = src.schema
        @test map(d -> d.name, sch.dims) == [:lon, :lat, :level, :step, :time]
        t = GeoFetch.dim(sch, :time).values
        @test length(t) == 8
        @test t == collect(DateTime(2026, 11, 8):Hour(6):DateTime(2026, 11, 9, 18))
        @test GeoFetch.dim(sch, :step).values == [0]
        @test length(src.units) == 8
        @test length(GeoFetch.dim(sch, :lon).values) == 1440
        @test length(GeoFetch.dim(sch, :lat).values) == 721
        @test GeoFetch.dim(sch, :level).values == GeoFetch._GFS_LEVELS
        @test first(src.units).payload ==
            "https://noaa-gfs-bdp-pds.s3.amazonaws.com/gfs.20261108/00/atmos/gfs.t00z.pgrb2.0p25.f000"
        @test map(v -> v.name, sch.vars) == map(f -> f.name, GeoFetch._GFS_FIELDS)
        @test GeoFetch.var(sch, :t).dims == [:lon, :lat, :level, :step, :time]
        @test GeoFetch.var(sch, :t2m).dims == [:lon, :lat, :step, :time]
        @test occursin("accumulated since forecast start", GeoFetch.var(sch, :apcp).attrs[:long_name])
        @test length(src.fields) == length(GeoFetch._GFS_FIELDS)

        # cycles and steps are sorted and uniqued; units are time-major
        src = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 9), cycles=[12, 0, 12], steps=[6, 0, 6],
                  resolution="1p00")
        @test GeoFetch.dim(src.schema, :step).values == [0, 6]
        @test GeoFetch.dim(src.schema, :time).values ==
            [DateTime(2026, 11, 8), DateTime(2026, 11, 8, 12), DateTime(2026, 11, 9), DateTime(2026, 11, 9, 12)]
        @test map(u -> (only(u.coords[:time]), only(u.coords[:step])), src.units[1:3]) ==
            [(DateTime(2026, 11, 8), 0), (DateTime(2026, 11, 8), 6), (DateTime(2026, 11, 8, 12), 0)]
        @test src.units[4].payload ==
            "https://noaa-gfs-bdp-pds.s3.amazonaws.com/gfs.20261108/12/atmos/gfs.t12z.pgrb2.1p00.f006"
        @test length(GeoFetch.dim(src.schema, :lon).values) == 360
        @test GeoFetch.dim(src.schema, :lat).values == collect(90.0:-1.0:-90.0)

        # hourly steps are fine at 0p25 up to 120
        @test length(GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), steps=[1, 120, 123]).units) == 12

        d = Date(2026, 11, 8)
        @test_throws ArgumentError GFS(start=Date(2026, 11, 9), stop=d)
        @test_throws ArgumentError GFS(start=Date(2021, 1, 1), stop=d)
        @test_throws ArgumentError GFS(start=d, stop=d, resolution="2p50")
        @test_throws ArgumentError GFS(start=d, stop=d, cycles=Int[])
        @test_throws ArgumentError GFS(start=d, stop=d, cycles=[0, 3])
        @test_throws ArgumentError GFS(start=d, stop=d, steps=Int[])
        @test_throws ArgumentError GFS(start=d, stop=d, steps=[387])
        @test_throws ArgumentError GFS(start=d, stop=d, steps=[121])
        @test_throws ArgumentError GFS(start=d, stop=d, steps=[1], resolution="1p00")
    end

    @testset "offline end-to-end (zarr v$zv)" for zv ∈ (2, 3)
        base = joinpath(@__DIR__, "fixtures", "gfs")
        dir = joinpath(base, "gfs.20261108", "00", "atmos")
        f0 = joinpath(dir, "gfs.t00z.pgrb2.1p00.f000")
        f6 = joinpath(dir, "gfs.t00z.pgrb2.1p00.f006")
        path = joinpath(mktempdir(), "gfs.zarr")
        src = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), cycles=[0], steps=[0, 6],
                  resolution="1p00", base=base)
        sel = Select(vars=[:t2m, :t, :apcp], level=[850, 500], lon=Between(10, 20), lat=Between(40, 50))
        execute(src | sel | Store(path; zarr_version=zv))
        g = Zarr.zopen(path)

        @test Set(keys(g.arrays)) == Set(["t2m", "t", "apcp", "lon", "lat", "level", "step", "time"])
        @test size(g["t2m"]) == (11, 11, 2, 1)
        @test size(g["t"]) == (11, 11, 2, 2, 1)
        @test size(g["apcp"]) == (11, 11, 2, 1)
        @test eltype(g["t2m"]) == Float32

        t2m = g["t2m"][:, :, :, :]
        @test t2m[:, :, 1, 1] == _gfscrop(f0, 2)
        @test t2m[:, :, 2, 1] == _gfscrop(f6, 3)
        @test all(x -> 180 < x < 340, t2m)

        t = g["t"][:, :, :, :, :]
        # level 2 = 500 hPa
        @test t[:, :, 2, 1, 1] == _gfscrop(f0, 1)
        @test t[:, :, 2, 2, 1] == _gfscrop(f6, 1)
        # level 1 = 850 hPa: not in the f000 fixture
        @test all(isnan, t[:, :, 1, 1, 1])
        @test t[:, :, 1, 2, 1] == _gfscrop(f6, 2)

        apcp = g["apcp"][:, :, :, :]
        @test all(isnan, apcp[:, :, 1, 1])
        @test apcp[:, :, 2, 1] == _gfscrop(f6, 4)

        @test g["lon"][:] == 10:20
        @test g["lat"][:] == 50:-1:40
        @test g["level"][:] == [850, 500]
        @test g["step"][:] == [0, 6]
        tm = g["time"]
        @test eltype(tm) == Int64
        @test tm[:] == [Dates.value(DateTime(2026, 11, 8) - DateTime(1970, 1, 1)) ÷ 1000]
        @test tm.attrs["units"] == "seconds since 1970-01-01T00:00:00"
        @test tm.attrs["calendar"] == "proleptic_gregorian"
        @test tm.attrs["long_name"] == "forecast initialization time"
        @test g["t2m"].attrs["units"] == "K"
    end

    # Opt-in: these hit the public NOAA bucket.
    if get(ENV, "GEOFETCH_LIVE_TESTS", "") == "true"
        @testset "live fetch" begin
            path = joinpath(mktempdir(), "gfs.zarr")
            src = GFS(start=Date(2026, 11, 8), stop=Date(2026, 11, 8), cycles=[0], steps=[3], resolution="1p00")
            execute(src | Select(vars=:t2m, lon=Between(0, 30), lat=Between(30, 60)) | Store(path))
            g = Zarr.zopen(path)
            @test size(g["t2m"]) == (31, 31, 1, 1)
            t2m = g["t2m"][:, :, :, :]
            @test all(isfinite, t2m)
            @test all(x -> 180 < x < 340, t2m)
        end

        # guards the registry strings against typos
        @testset "live registry" begin
            url = GeoFetch._GFS_BASE * "/gfs.20261108/00/atmos/gfs.t00z.pgrb2.1p00.f006.idx"
            idx = GeoFetch._parseidx(GeoFetch._readtext(url))
            @test !isempty(idx)
            @testset "$(f.name)" for f ∈ GeoFetch._GFS_FIELDS
                lev = f.level == "{} mb" ? 500 : nothing
                fld = GeoFetch.GRIBField(f.param, f.level, f.forecast)
                @test GeoFetch._findmsg(idx, fld, lev) !== nothing
            end
        end
    end
end
