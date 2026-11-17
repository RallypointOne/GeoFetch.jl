using Dates
import GRIB
import Zarr

# Decode message `n` (file order) of the ECMWF GRIB file at `path`, located via its index.
function _ecmwfmsg(path, n)
    e = GeoFetch._parseindex(read(GeoFetch._indexloc(path), String))[n]
    GeoFetch._decodegrib(GeoFetch._readbytes(path, e.start, e.stop))
end

# The same message as the store holds it: Float32, cropped to lon 10..20, lat 50..40.
_ecmwfcrop(path, n) = Float32.(_ecmwfmsg(path, n))[761:801, 161:201]

@testset "ECMWF" begin
    base = joinpath(@__DIR__, "fixtures", "ecmwf")
    dir = joinpath(base, "20261114", "00z", "ifs", "0p25", "oper")
    f0 = joinpath(dir, "20261114000000-0h-oper-fc.grib2")
    f6 = joinpath(dir, "20261114000000-6h-oper-fc.grib2")
    fa = joinpath(base, "20261114", "00z", "aifs-single", "0p25", "oper", "20261114000000-6h-oper-fc.grib2")

    # Checked independently of the package's own index parser and decoder.
    @testset "fixture" begin
        @testset "$(basename(f))" for (f, n) ∈ (f0 => 2, f6 => 4, fa => 1)
            ls = filter(!isempty, readlines(replace(f, r"\.grib2$" => ".index")))
            @test length(ls) == n
            r = map(ls) do l
                a = parse(Int, match(r"\"_offset\": (\d+)", l)[1])
                (a, a + parse(Int, match(r"\"_length\": (\d+)", l)[1]) - 1)
            end
            @test first(first(r)) == 0
            @test last(last(r)) == filesize(f) - 1
            data = read(f)
            foreach(r) do (a, b)
                bytes = data[a+1:b+1]
                GC.@preserve bytes begin
                    m = GRIB.Message(bytes)
                    @test size(m["values"]) == (1440, 721)
                    @test m["latitudeOfFirstGridPointInDegrees"] == 90
                    # i.e. -180
                    @test m["longitudeOfFirstGridPointInDegrees"] == 180
                end
            end
        end
    end

    @testset "_parseindex" begin
        text = """
        {"domain": "g", "step": "6", "levtype": "sfc", "param": "2t", "_offset": 0, "_length": 100}

        {"domain": "g", "step": "6", "levelist": "500", "levtype": "pl", "param": "z", "_offset": 100, "_length": 50}
        {"domain": "g", "step": "6", "levtype": "sfc", "param": "z", "_offset": 150, "_length": 25}
        {"domain": "g", "step": "6", "levelist": "2", "levtype": "sol", "param": "sot", "_offset": 175, "_length": 5}
        {"param": "incomplete"}
        not an index line
        """
        idx = GeoFetch._parseindex(text)
        @test length(idx) == 4
        @test map(e -> (e.start, e.stop), idx) == [(0, 99), (100, 149), (150, 174), (175, 179)]
        @test map(e -> e.param, idx) == ["2t", "z", "z", "sot"]
        @test map(e -> e.level, idx) == ["sfc", "500 pl", "sfc", "2 sol"]
        @test all(e -> e.forecast == "", idx)
        @test isempty(GeoFetch._parseindex("not an index\n"))

        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("z", "{} pl"), 500) == idx[2]
        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("z", "{} pl"), 850) === nothing
        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("z", "sfc"), nothing) == idx[3]
        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("sot", "2 sol"), nothing) == idx[4]
        @test GeoFetch._findmsg(idx, GeoFetch.GRIBField("sot", "1 sol"), nothing) === nothing

        @test GeoFetch._indexloc("a/b-fc.grib2") == "a/b-fc.index"
        @test_throws ErrorException GeoFetch._indexloc("a/b-fc.grib")
    end

    @testset "GRIBRangeSource index" begin
        sch = GeoFetch.SourceSchema(GeoFetch.DimSpec[], GeoFetch.VarSpec[])
        @test GeoFetch.GRIBRangeSource(; schema=sch, units=GeoFetch.FetchUnit[], fields=Dict()).index === :wgrib2
        @test_throws ArgumentError GeoFetch.GRIBRangeSource(; schema=sch, units=GeoFetch.FetchUnit[], fields=Dict(),
                                                            index=:nope)
    end

    @testset "IFS construction" begin
        src = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 15))
        @test src isa GeoFetch.GRIBRangeSource
        @test src.index === :ecmwf
        sch = src.schema
        @test map(d -> d.name, sch.dims) == [:lon, :lat, :level, :step, :time]
        @test GeoFetch.dim(sch, :time).values == collect(DateTime(2026, 11, 14):Hour(6):DateTime(2026, 11, 15, 18))
        @test GeoFetch.dim(sch, :step).values == [0]
        @test GeoFetch.dim(sch, :lon).values == collect(-180.0:0.25:179.75)
        @test GeoFetch.dim(sch, :lat).values == collect(90.0:-0.25:-90.0)
        @test GeoFetch.dim(sch, :level).values == GeoFetch._ECMWF_LEVELS
        @test length(src.units) == 8
        @test all(u -> isempty(u.vars), src.units)
        @test first(src.units).payload ==
            "https://storage.googleapis.com/ecmwf-open-data/20261114/00z/ifs/0p25/oper/20261114000000-0h-oper-fc.grib2"
        @test map(v -> v.name, sch.vars) == map(f -> f.name, GeoFetch._IFS_FIELDS)
        @test allunique(map(f -> f.name, GeoFetch._IFS_FIELDS))
        @test allunique(map(f -> (f.param, f.level), GeoFetch._IFS_FIELDS))
        @test GeoFetch.var(sch, :t).dims == [:lon, :lat, :level, :step, :time]
        @test GeoFetch.var(sch, :t2m).dims == [:lon, :lat, :step, :time]
        @test GeoFetch.var(sch, :sot1).dims == [:lon, :lat, :step, :time]
        @test GeoFetch.var(sch, :tp).attrs[:units] == "m"
        @test src.fields[:zsfc] == GeoFetch.GRIBField("z", "sfc", nothing)
        @test src.fields[:z] == GeoFetch.GRIBField("z", "{} pl", nothing)
        @test sch.attrs[:license] == "CC-BY-4.0"

        # cycles and steps are sorted and uniqued; units are time-major
        src = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 15), cycles=[12, 0, 12], steps=[6, 0, 6])
        @test GeoFetch.dim(src.schema, :step).values == [0, 6]
        @test map(u -> (only(u.coords[:time]), only(u.coords[:step])), src.units[1:3]) ==
            [(DateTime(2026, 11, 14), 0), (DateTime(2026, 11, 14), 6), (DateTime(2026, 11, 14, 12), 0)]
        @test endswith(src.units[4].payload, "/20261114/12z/ifs/0p25/oper/20261114120000-6h-oper-fc.grib2")

        # 0p1: two files per (time, step), each with its own variables
        src = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 6], resolution="0p1")
        @test length(GeoFetch.dim(src.schema, :lon).values) == 3600
        @test length(GeoFetch.dim(src.schema, :lat).values) == 1801
        @test extrema(GeoFetch.dim(src.schema, :lon).values) == (-180.0, 179.9)
        @test extrema(GeoFetch.dim(src.schema, :lat).values) == (-90.0, 90.0)
        @test length(src.units) == 4
        @test endswith(src.units[1].payload, "/ifs/0p1/oper/20261114000000-0h-oper-fc-sfc.grib2")
        @test endswith(src.units[2].payload, "/ifs/0p1/oper/20261114000000-0h-oper-fc-pl.grib2")
        @test endswith(src.units[3].payload, "/ifs/0p1/oper/20261114000000-6h-oper-fc-sfc.grib2")
        @test src.units[2].vars == [:t, :u, :v, :w, :z, :gh, :q, :r, :d, :vo]
        @test :t2m ∈ src.units[1].vars && :sot4 ∈ src.units[1].vars && :t ∉ src.units[1].vars
        @test length(src.units[1].vars) + length(src.units[2].vars) == length(GeoFetch._IFS_FIELDS)
        # a selection without pressure-level variables drops the -pl files
        (_, us) = GeoFetch.apply_select(Select(vars=:t2m), src.schema, src.units)
        @test map(u -> u.vars, us) == [[:t2m], [:t2m]]
        @test all(u -> endswith(u.payload, "-sfc.grib2"), us)

        # the 6 and 18 UTC runs were stream `scda` until 2026-05-11
        u(d, c) = only(IFS(start=d, stop=d, cycles=[c], steps=[3]).units).payload
        @test endswith(u(Date(2026, 5, 11), 18), "/20260511/18z/ifs/0p25/scda/20260511180000-3h-scda-fc.grib2")
        @test endswith(u(Date(2026, 5, 11), 12), "/20260511/12z/ifs/0p25/oper/20260511120000-3h-oper-fc.grib2")
        @test endswith(u(Date(2026, 5, 12), 6), "/20260512/06z/ifs/0p25/oper/20260512060000-3h-oper-fc.grib2")

        d = Date(2026, 11, 14)
        @test length(IFS(start=d, stop=d, cycles=[0, 12], steps=[3, 144, 150, 360]).units) == 8
        @test length(IFS(start=d, stop=d, steps=[144]).units) == 4
        @test length(IFS(start=Date(2026, 5, 1), stop=d, cycles=[6], steps=[90]).units) == 198
        @test_throws ArgumentError IFS(start=Date(2026, 11, 15), stop=d)
        @test_throws ArgumentError IFS(start=Date(2024, 2, 29), stop=d)
        @test_throws ArgumentError IFS(start=d, stop=d, resolution="1p00")
        @test_throws ArgumentError IFS(start=Date(2026, 10, 20), stop=d, resolution="0p1")
        @test_throws ArgumentError IFS(start=d, stop=d, cycles=Int[])
        @test_throws ArgumentError IFS(start=d, stop=d, cycles=[0, 3])
        @test_throws ArgumentError IFS(start=d, stop=d, steps=Int[])
        @test_throws ArgumentError IFS(start=d, stop=d, steps=[1])
        @test_throws ArgumentError IFS(start=d, stop=d, cycles=[0], steps=[147])
        @test_throws ArgumentError IFS(start=d, stop=d, cycles=[0], steps=[366])
        @test_throws ArgumentError IFS(start=d, stop=d, steps=[150])
        @test_throws ArgumentError IFS(start=Date(2026, 5, 1), stop=d, cycles=[6], steps=[93])
    end

    @testset "AIFS construction" begin
        src = AIFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[18], steps=[0, 360])
        @test src isa GeoFetch.GRIBRangeSource
        @test src.index === :ecmwf
        sch = src.schema
        @test map(d -> d.name, sch.dims) == [:lon, :lat, :level, :step, :time]
        @test length(GeoFetch.dim(sch, :lon).values) == 1440
        @test map(v -> v.name, sch.vars) == map(f -> f.name, GeoFetch._AIFS_FIELDS)
        @test allunique(map(f -> f.name, GeoFetch._AIFS_FIELDS))
        @test allunique(map(f -> (f.param, f.level), GeoFetch._AIFS_FIELDS))
        @test GeoFetch.var(sch, :tp).attrs[:units] == "kg m-2"
        @test map(u -> u.payload, src.units) == map(["0h", "360h"]) do h
            "https://storage.googleapis.com/ecmwf-open-data/20261114/18z/aifs-single/0p25/oper/20261114180000-$h-oper-fc.grib2"
        end

        d = Date(2026, 11, 14)
        @test_throws ArgumentError AIFS(start=Date(2026, 11, 15), stop=d)
        @test_throws ArgumentError AIFS(start=Date(2025, 2, 28), stop=d)
        @test_throws ArgumentError AIFS(start=d, stop=d, cycles=[1])
        @test_throws ArgumentError AIFS(start=d, stop=d, steps=[3])
        @test_throws ArgumentError AIFS(start=d, stop=d, steps=[366])
        @test_throws ArgumentError AIFS(start=d, stop=d, steps=Int[])
    end

    @testset "IFS offline end-to-end (zarr v$zv)" for zv ∈ (2, 3)
        path = joinpath(mktempdir(), "ifs.zarr")
        src = IFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[0, 6], base=base)
        sel = Select(vars=[:t2m, :t, :tp, :zsfc], level=[850, 500], lon=Between(10, 20), lat=Between(40, 50))
        execute(src | sel | Store(path; zarr_version=zv))
        g = Zarr.zopen(path)

        @test Set(keys(g.arrays)) == Set(["t2m", "t", "tp", "zsfc", "lon", "lat", "level", "step", "time"])
        @test size(g["t2m"]) == (41, 41, 2, 1)
        @test size(g["t"]) == (41, 41, 2, 2, 1)
        @test eltype(g["t2m"]) == Float32

        t2m = g["t2m"][:, :, :, :]
        @test t2m[:, :, 1, 1] == _ecmwfcrop(f0, 1)
        @test t2m[:, :, 2, 1] == _ecmwfcrop(f6, 1)
        @test all(x -> 180 < x < 340, t2m)

        t = g["t"][:, :, :, :, :]
        # level 2 = 500 hPa
        @test t[:, :, 2, 1, 1] == _ecmwfcrop(f0, 2)
        @test t[:, :, 2, 2, 1] == _ecmwfcrop(f6, 2)
        # level 1 = 850 hPa: not in the 0h fixture
        @test all(isnan, t[:, :, 1, 1, 1])
        @test t[:, :, 1, 2, 1] == _ecmwfcrop(f6, 3)

        tp = g["tp"][:, :, :, :]
        @test all(isnan, tp[:, :, 1, 1])
        @test tp[:, :, 2, 1] == _ecmwfcrop(f6, 4)
        @test all(x -> 0 ≤ x < 1, tp[:, :, 2, 1])

        # not in the fixture at all
        @test all(isnan, g["zsfc"][:, :, :, :])

        @test g["lon"][:] == 10:0.25:20
        @test g["lat"][:] == 50:-0.25:40
        @test g["level"][:] == [850, 500]
        @test g["step"][:] == [0, 6]
        @test g["time"][:] == [Dates.value(DateTime(2026, 11, 14) - DateTime(1970, 1, 1)) ÷ 1000]
        @test g["t2m"].attrs["units"] == "K"
        @test g.attrs["license"] == "CC-BY-4.0"
    end

    @testset "AIFS offline end-to-end" begin
        path = joinpath(mktempdir(), "aifs.zarr")
        src = AIFS(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[6], base=base)
        execute(src | Select(vars=:t2m, lon=Between(10, 20), lat=Between(40, 50)) | Store(path))
        g = Zarr.zopen(path)
        @test size(g["t2m"]) == (41, 41, 1, 1)
        @test g["t2m"][:, :, 1, 1] == _ecmwfcrop(fa, 1)
        # same valid time and place as the IFS forecast, a different model
        @test g["t2m"][:, :, 1, 1] ≠ _ecmwfcrop(f6, 1)
        @test maximum(abs, g["t2m"][:, :, 1, 1] .- _ecmwfcrop(f6, 1)) < 15
    end

    @testset "grid layout" begin
        g = _ecmwfmsg(f6, 1)
        # north first, both poles colder than the equator
        eq = sum(g[:, 341:381]) / length(g[:, 341:381])
        @test eq - sum(g[:, 1:20]) / length(g[:, 1:20]) > 20
        @test eq - sum(g[:, 702:721]) / length(g[:, 702:721]) > 20
    end

    # Opt-in: these hit the public mirror.
    if get(ENV, "GEOFETCH_LIVE_TESTS", "") == "true"
        @testset "live fetch $(nameof(f))" for f ∈ (IFS, AIFS)
            path = joinpath(mktempdir(), "ecmwf.zarr")
            src = f(start=Date(2026, 11, 14), stop=Date(2026, 11, 14), cycles=[0], steps=[6])
            execute(src | Select(vars=:t2m, lon=Between(0, 30), lat=Between(30, 60)) | Store(path))
            g = Zarr.zopen(path)
            @test size(g["t2m"]) == (121, 121, 1, 1)
            t2m = g["t2m"][:, :, :, :]
            @test all(isfinite, t2m)
            @test all(x -> 180 < x < 340, t2m)
        end

        # guards the registry strings against typos; step 0 has every field
        @testset "live registry $model" for (model, fields) ∈ ("ifs" => GeoFetch._IFS_FIELDS,
                                                               "aifs-single" => GeoFetch._AIFS_FIELDS)
            url = GeoFetch._ecmwf_url(GeoFetch._ECMWF_BASE, model, "0p25", DateTime(2026, 11, 14), 0, "")
            idx = GeoFetch._readidx(Val(:ecmwf), url)
            @test !isempty(idx)
            @testset "$(f.name)" for f ∈ fields
                lev = f.level == "{} pl" ? 500 : nothing
                @test GeoFetch._findmsg(idx, GeoFetch.GRIBField(f.param, f.level), lev) !== nothing
            end
        end
    end
end
