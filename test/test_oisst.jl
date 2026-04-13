using GeoFetch
using GeoFetch: OISSTChunk, _OISST_DATASETS, _oisst_url, OISST_DAILY
using Downloads
using Test
using Dates

@testset "OISST" begin
    @testset "OISST <: Source" begin
        @test OISST <: Source
    end

    @testset "OISSTDataset <: Dataset" begin
        @test OISSTDataset <: Dataset
    end

    @testset "help" begin
        @test help(OISST()) isa AbstractString
        @test help(OISSTDataset()) isa AbstractString
    end

    @testset "datasets" begin
        ds = datasets(OISST())
        @test length(ds) == 1
        @test ds[1] isa OISSTDataset
    end

    @testset "OISSTChunk" begin
        c = OISSTChunk("https://example.com/oisst.nc", Date(2024, 1, 1))
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :oisst
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "URL construction" begin
        url = _oisst_url(Date(2024, 7, 15))
        @test occursin("202407/oisst-avhrr-v02r01.20240715.nc", url)
        @test startswith(url, "https://www.ncei.noaa.gov/thredds/fileServer/")
    end

    @testset "URL construction - year boundary" begin
        url = _oisst_url(Date(2023, 12, 31))
        @test occursin("202312/oisst-avhrr-v02r01.20231231.nc", url)

        url = _oisst_url(Date(2024, 1, 1))
        @test occursin("202401/oisst-avhrr-v02r01.20240101.nc", url)
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = OISSTDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks single day" begin
        p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4)))
        d = OISSTDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].date == Date(2024, 7, 4)
        @test occursin("20240704", cs[1].url)
    end

    @testset "chunks date range" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)))
        d = OISSTDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 7
        @test cs[1].date == Date(2024, 1, 1)
        @test cs[7].date == Date(2024, 1, 7)
    end

    @testset "chunks across month boundary" begin
        p = Project(datetimes=(DateTime(2024, 1, 30), DateTime(2024, 2, 2)))
        d = OISSTDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 4
        @test occursin("202401/", cs[1].url)
        @test occursin("202401/", cs[2].url)
        @test occursin("202402/", cs[3].url)
        @test occursin("202402/", cs[4].url)
    end

    @testset "popular constants" begin
        @test OISST_DAILY isa OISSTDataset
    end

    @testset "live: OISST endpoint reachable" begin
        try
            Downloads.request(_oisst_url(Date(2024, 7, 4)); method="HEAD", output=devnull)
            @test true
        catch e
            @warn "live: OISST endpoint reachable" exception=(e, catch_backtrace())
        end
    end
end
