using GeoFetch
using GeoFetch: ETOPOChunk, _ETOPO_DATASETS, _etopo_build_url, ETOPO_60s, ETOPO_30s, ETOPO_15s
using Test

@testset "ETOPO" begin
    @testset "ETOPO <: Source" begin
        @test ETOPO <: Source
    end

    @testset "ETOPODataset <: Dataset" begin
        @test ETOPODataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = ETOPODataset()
        @test d.resolution == "60s"
        @test d.surface_type == "surface"
        @test d.format == "netcdf"
    end

    @testset "Dataset with custom parameters" begin
        d = ETOPODataset(resolution="15s", surface_type="bedrock", format="geotiff")
        @test d.resolution == "15s"
        @test d.surface_type == "bedrock"
        @test d.format == "geotiff"
    end

    @testset "help" begin
        @test help(ETOPO()) isa AbstractString
        @test help(ETOPODataset()) isa AbstractString
    end

    @testset "datasets" begin
        ds = datasets(ETOPO())
        @test length(ds) == 6
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(ETOPO(); resolution="30s")
        @test length(ds) == 2
        @test all(d -> d.resolution == "30s", ds)

        ds = datasets(ETOPO(); surface_type="bedrock")
        @test length(ds) == 3
        @test all(d -> d.surface_type == "bedrock", ds)
    end

    @testset "URL construction" begin
        d = ETOPODataset(resolution="60s", surface_type="surface")
        url = _etopo_build_url(d)
        @test occursin("ETOPO2022", url)
        @test occursin("60s", url)
        @test occursin("surface", url)
        @test endswith(url, ".nc")

        d2 = ETOPODataset(resolution="15s", surface_type="bedrock", format="geotiff")
        url2 = _etopo_build_url(d2)
        @test occursin("15s", url2)
        @test occursin("bedrock", url2)
        @test endswith(url2, ".tif")
    end

    @testset "ETOPOChunk" begin
        c = ETOPOChunk("https://example.com/etopo.nc", "60s", "surface", "netcdf")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("etopo_60s_surface")
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "ETOPOChunk geotiff extension" begin
        c = ETOPOChunk("https://example.com/etopo.tif", "30s", "bedrock", "geotiff")
        @test GeoFetch.extension(c) == "tif"
    end

    @testset "chunks returns single chunk" begin
        p = Project()
        d = ETOPODataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa ETOPOChunk
    end

    @testset "chunks ignores datetimes" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)))
        d = ETOPODataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
    end

    @testset "chunks rejects invalid resolution" begin
        p = Project()
        d = ETOPODataset(resolution="5s", surface_type="surface")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid surface_type" begin
        p = Project()
        d = ETOPODataset(resolution="60s", surface_type="ice")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "popular constants" begin
        @test ETOPO_60s isa ETOPODataset
        @test ETOPO_60s.resolution == "60s"
        @test ETOPO_30s.resolution == "30s"
        @test ETOPO_15s.resolution == "15s"
    end
end
