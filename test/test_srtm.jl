using GeoFetch
using GeoFetch: SRTMChunk, _SRTM_DATASETS, _srtm_tile_name, _srtm_tiles_for_extent, _srtm_build_url, SRTM_30m, SRTM_90m
using Test
using Extents: Extent

@testset "SRTM" begin
    @testset "SRTM <: Source" begin
        @test SRTM <: Source
    end

    @testset "SRTMDataset <: Dataset" begin
        @test SRTMDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = SRTMDataset()
        @test d.product == "SRTMGL1"
        @test d.version == "003"
    end

    @testset "help" begin
        @test help(SRTM()) isa AbstractString
        @test help(SRTMDataset()) isa AbstractString
    end

    @testset "tile name generation" begin
        @test _srtm_tile_name(30, -90) == "N30W090"
        @test _srtm_tile_name(-10, 20) == "S10E020"
        @test _srtm_tile_name(0, 0) == "N00E000"
        @test _srtm_tile_name(-1, -1) == "S01W001"
        @test _srtm_tile_name(45, 120) == "N45E120"
    end

    @testset "tiles for extent" begin
        ext = Extent(X=(-90.5, -89.5), Y=(30.0, 31.0))
        tiles = _srtm_tiles_for_extent(ext)
        @test length(tiles) == 2
        @test "N30W091" in tiles
        @test "N30W090" in tiles
    end

    @testset "tiles for single degree" begin
        ext = Extent(X=(-90.0, -89.0), Y=(30.0, 31.0))
        tiles = _srtm_tiles_for_extent(ext)
        @test length(tiles) == 1
        @test "N30W090" in tiles
    end

    @testset "tiles clamp to SRTM coverage" begin
        ext = Extent(X=(0.0, 1.0), Y=(-70.0, 70.0))
        tiles = _srtm_tiles_for_extent(ext)
        lats = [parse(Int, m.captures[2]) * (m.captures[1] == "S" ? -1 : 1)
                for t in tiles for m in eachmatch(r"([NS])(\d+)[EW]\d+", t)]
        @test all(l -> -60 <= l <= 59, lats)
    end

    @testset "URL construction" begin
        d = SRTMDataset(product="SRTMGL1", version="003")
        url = _srtm_build_url(d, "N30W090")
        @test occursin("e4ftl01.cr.usgs.gov", url)
        @test occursin("SRTMGL1.003", url)
        @test occursin("N30W090", url)
        @test endswith(url, ".hgt.zip")
    end

    @testset "SRTMChunk" begin
        c = SRTMChunk("https://example.com/N30W090.hgt.zip", "N30W090", "SRTMGL1")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("srtm_N30W090")
        @test GeoFetch.extension(c) == "hgt.zip"
    end

    @testset "chunks requires bounded extent" begin
        p = Project()
        d = SRTMDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid product" begin
        p = Project(geometry=Extent(X=(-90.0, -89.0), Y=(30.0, 31.0)))
        d = SRTMDataset(product="INVALID")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks generates correct tiles" begin
        withenv("EARTHDATA_TOKEN" => "testtoken") do
            p = Project(geometry=Extent(X=(-90.0, -88.0), Y=(30.0, 32.0)))
            d = SRTMDataset()
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 4
            tile_names = [c.tile_name for c in cs]
            @test "N30W090" in tile_names
            @test "N30W089" in tile_names
            @test "N31W090" in tile_names
            @test "N31W089" in tile_names
        end
    end

    @testset "chunks requires auth" begin
        withenv("EARTHDATA_TOKEN" => nothing) do
            c = SRTMChunk("https://example.com/N30W090.hgt.zip", "N30W090", "SRTMGL1")
            @test_throws ErrorException GeoFetch.fetch(c, tempname())
        end
    end

    @testset "datasets" begin
        ds = datasets(SRTM())
        @test length(ds) == 2
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(SRTM(); product="SRTMGL3")
        @test length(ds) == 1
        @test ds[1].product == "SRTMGL3"
    end

    @testset "popular constants" begin
        @test SRTM_30m isa SRTMDataset
        @test SRTM_30m.product == "SRTMGL1"
        @test SRTM_90m.product == "SRTMGL3"
    end
end
