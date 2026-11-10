using Dates
using Statistics

# Decode message `n` (file order) of the GRIB file at `path`, located via its idx.
function _gribmsg(path, n)
    e = GeoFetch._parseidx(read(path * ".idx", String))[n]
    GeoFetch._decodegrib(GeoFetch._readbytes(path, e.start, e.stop))
end

# 1° schema over one GRIB file: `t2m` at the surface and `t` on pressure levels.
function _gribschema()
    dims = [
        GeoFetch.DimSpec(:lon, collect(0.0:359.0)),
        GeoFetch.DimSpec(:lat, collect(90.0:-1.0:-90.0)),
        GeoFetch.DimSpec(:level, [850, 500, 300]),
        GeoFetch.DimSpec(:step, [6]),
        GeoFetch.DimSpec(:time, [DateTime(2026, 11, 8)]),
    ]
    vars = [
        GeoFetch.VarSpec(:t2m, [:lon, :lat, :step, :time], Float32),
        GeoFetch.VarSpec(:t, [:lon, :lat, :level, :step, :time], Float32),
    ]
    GeoFetch.SourceSchema(dims, vars)
end

function _gribsource(path, fields)
    sch = _gribschema()
    u = GeoFetch.FetchUnit(;
        coords=Dict(:step => [6], :time => [DateTime(2026, 11, 8)]),
        payload=path,
    )
    GeoFetch.GRIBRangeSource(; schema=sch, units=[u], fields)
end

@testset "GRIBRangeSource" begin
    dir = joinpath(@__DIR__, "fixtures", "gfs", "gfs.20261108", "00", "atmos")
    path = joinpath(dir, "gfs.t00z.pgrb2.1p00.f006")
    fields = Dict(
        :t2m => GeoFetch.GRIBField("TMP", "2 m above ground"),
        :t => GeoFetch.GRIBField("TMP", "{} mb"),
    )

    @testset "_parseidx" begin
        text = """
        1:0:d=2026110800:TMP:500 mb:6 hour fcst:

        2:100:d=2026110800:UGRD:10 m above ground:6 hour fcst:
        3:100:d=2026110800:VGRD:10 m above ground:6 hour fcst:
        not an index line
        """
        idx = GeoFetch._parseidx(text)
        @test length(idx) == 3
        @test map(e -> e.start, idx) == [0, 100, 100]
        @test idx[1].stop == 99
        @test idx[2].stop === nothing
        @test idx[3].stop === nothing
        @test idx[1].param == "TMP"
        @test idx[1].level == "500 mb"
        @test idx[1].forecast == "6 hour fcst"
        @test idx[3].param == "VGRD"
        @test isempty(GeoFetch._parseidx("not an index\n"))
    end

    @testset "_findmsg" begin
        idx = GeoFetch._parseidx(read(path * ".idx", String))
        @test length(idx) == 5
        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("APCP", "surface"), nothing) === nothing
        acc = GeoFetch.GRIBField("APCP", "surface", r"^0-\d+ (hour|day) acc fcst$")
        @test GeoFetch._findmsg(idx, acc, nothing) == idx[4]
        @test GeoFetch._findmsg(idx, fields[:t], 500) == idx[1]
        @test GeoFetch._findmsg(idx, fields[:t], 850) == idx[2]
        @test GeoFetch._findmsg(idx, fields[:t], 300) === nothing
        @test GeoFetch._findmsg(idx, fields[:t2m], nothing) == idx[3]
    end

    @testset "_readbytes" begin
        p = tempname()
        write(p, UInt8.(0:9))
        @test GeoFetch._readbytes(p, 0, 3) == UInt8.(0:3)
        @test GeoFetch._readbytes(p, 2, nothing) == UInt8.(2:9)
        @test_throws ErrorException GeoFetch._readbytes(p, 8, 12)
    end

    @testset "fetch! cropped" begin
        src = _gribsource(path, fields)
        sel = Select(lon=Between(10, 20), lat=Between(40, 50))
        (sch, us) = GeoFetch.apply_select(sel, src.schema, src.units)
        data = GeoFetch.fetch!(src, only(us), sch)
        @test keys(data) == (:t2m, :t)
        @test data.t2m isa Array{Float32, 4}
        @test size(data.t2m) == (11, 11, 1, 1)
        @test size(data.t) == (11, 11, 3, 1, 1)
        @test data.t2m[:, :, 1, 1] == Float32.(_gribmsg(path, 3)[11:21, 41:51])
        @test data.t[:, :, 1, 1, 1] == Float32.(_gribmsg(path, 2)[11:21, 41:51])
        @test data.t[:, :, 2, 1, 1] == Float32.(_gribmsg(path, 1)[11:21, 41:51])
        @test all(isnan, data.t[:, :, 3, 1, 1])
        @test all(x -> 180 < x < 340, data.t2m)

        # the unit's `vars` restrict what is returned
        u = GeoFetch.FetchUnit(only(us).coords, [:t], path)
        @test keys(GeoFetch.fetch!(src, u, sch)) == (:t,)
    end

    @testset "grid layout" begin
        src = _gribsource(path, fields)
        g = GeoFetch.fetch!(src, only(src.units), src.schema).t2m
        @test size(g) == (360, 181, 1, 1)
        eq = mean(g[:, 86:96, 1, 1])
        @test eq - mean(g[:, 1:5, 1, 1]) > 20
        @test eq - mean(g[:, 177:181, 1, 1]) > 20
    end

    @testset "absent messages" begin
        src = _gribsource(path, Dict(:t2m => GeoFetch.GRIBField("NOPE", "surface")))
        (sch, us) = GeoFetch.apply_select(Select(vars=:t2m), src.schema, src.units)
        data = GeoFetch.fetch!(src, only(us), sch)
        @test keys(data) == (:t2m,)
        @test size(data.t2m) == (360, 181, 1, 1)
        @test all(isnan, data.t2m)
    end

    @testset "garbage index" begin
        x = joinpath(mktempdir(), "x")
        write(x, "")
        write(x * ".idx", "not an index\n")
        src = _gribsource(x, fields)
        @test_throws ErrorException GeoFetch.fetch!(src, only(src.units), src.schema)
    end
end
