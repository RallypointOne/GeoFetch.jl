using GeoFetch
using GeoFetch: NDBCChunk, _NDBC_DATASETS, _NDBC_DATATYPES, _NDBC_REALTIME_EXT
using GeoFetch: NDBC_STDMET, NDBC_OCEAN
using Test
using Dates
using Extents: Extent

@testset "NDBC" begin
    @testset "NDBC <: Source" begin
        @test NDBC <: Source
    end

    @testset "NDBCDataset <: Dataset" begin
        @test NDBCDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = NDBCDataset()
        @test d.stations == String[]
        @test d.datatype == "stdmet"
        @test d.format == "txt"
    end

    @testset "Dataset with custom parameters" begin
        d = NDBCDataset(stations=["41002", "41004"], datatype="ocean", format="nc")
        @test d.stations == ["41002", "41004"]
        @test d.datatype == "ocean"
        @test d.format == "nc"
    end

    @testset "help" begin
        @test help(NDBC()) isa AbstractString
        @test help(NDBCDataset()) isa AbstractString
    end

    @testset "NDBCChunk txt.gz" begin
        c = NDBCChunk("https://www.ndbc.noaa.gov/data/historical/stdmet/41002h2024.txt.gz", "41002", "stdmet", 2024)
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :ndbc_41002_stdmet
        @test GeoFetch.extension(c) == "txt.gz"
    end

    @testset "NDBCChunk nc" begin
        c = NDBCChunk("https://dods.ndbc.noaa.gov/thredds/fileServer/data/stdmet/41002/41002h2024.nc", "41002", "stdmet", 2024)
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = NDBCDataset(stations=["41002"])
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks requires stations or bounded extent" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)))
        d = NDBCDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid datatype" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)))
        d = NDBCDataset(stations=["41002"], datatype="invalid")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid format" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)))
        d = NDBCDataset(stations=["41002"], format="csv")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks single station single year" begin
        p = Project(datetimes=(DateTime(2024, 6, 1), DateTime(2024, 6, 30)))
        d = NDBCDataset(stations=["41002"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa NDBCChunk
        @test cs[1].station == "41002"
        @test cs[1].year == 2024
        @test occursin("historical/stdmet", cs[1].url)
        @test occursin("41002h2024", cs[1].url)
        @test endswith(cs[1].url, ".txt.gz")
    end

    @testset "chunks multi-year" begin
        p = Project(datetimes=(DateTime(2022, 1, 1), DateTime(2024, 12, 31)))
        d = NDBCDataset(stations=["41002"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3
        @test cs[1].year == 2022
        @test cs[2].year == 2023
        @test cs[3].year == 2024
    end

    @testset "chunks multi-station" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)))
        d = NDBCDataset(stations=["41002", "41004"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 2
        @test cs[1].station == "41002"
        @test cs[2].station == "41004"
    end

    @testset "chunks NetCDF format" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)))
        d = NDBCDataset(stations=["41002"], format="nc")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test occursin("thredds/fileServer", cs[1].url)
        @test endswith(cs[1].url, ".nc")
    end

    @testset "chunks ocean datatype" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)))
        d = NDBCDataset(stations=["41002"], datatype="ocean")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test occursin("historical/ocean", cs[1].url)
        @test occursin("41002o2024", cs[1].url)
    end

    @testset "datasets" begin
        ds = datasets(NDBC())
        @test length(ds) == length(_NDBC_DATASETS)
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(NDBC(); datatype="stdmet")
        @test length(ds) == 1
        @test ds[1].datatype == "stdmet"

        ds = datasets(NDBC(); datatype="ocean")
        @test length(ds) == 1
    end

    @testset "popular constants" begin
        @test NDBC_STDMET isa NDBCDataset
        @test NDBC_STDMET.datatype == "stdmet"
        @test NDBC_OCEAN isa NDBCDataset
        @test NDBC_OCEAN.datatype == "ocean"
    end

    @testset "metadata" begin
        m = metadata(NDBCDataset())
        @test m[:data_type] == "station"
        @test haskey(m, :license)
    end

    @testset "filesize estimate returns nothing for station data" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)))
        @test filesize(p, NDBCDataset()) === nothing
    end

    @testset "live: NDBC historical stdmet download" begin
        try
            p = Project(datetimes=(DateTime(2023, 1, 1), DateTime(2023, 12, 31)))
            d = NDBCDataset(stations=["41002"])
            cs = GeoFetch.chunks(p, d)
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(cs[1]))
            GeoFetch.fetch(cs[1], file)
            @test isfile(file)
            @test filesize(file) > 0
        catch e
            @warn "live: NDBC historical stdmet download" exception=(e, catch_backtrace())
        end
    end
end
