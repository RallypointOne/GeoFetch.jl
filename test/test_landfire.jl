using GeoFetch
using GeoFetch: LandfireChunk, _LANDFIRE_DATASETS, _LANDFIRE_PRODUCTS, _LANDFIRE_REGIONS
using GeoFetch: _landfire_build_url, _landfire_year
using GeoFetch: LANDFIRE_FBFM40, LANDFIRE_FBFM13
using Test
using Extents: Extent

@testset "Landfire" begin
    @testset "Landfire <: Source" begin
        @test Landfire <: Source
    end

    @testset "LandfireDataset <: Dataset" begin
        @test LandfireDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = LandfireDataset()
        @test d.product == "FBFM40"
        @test d.region == "CONUS"
        @test d.year isa Latest
    end

    @testset "Dataset with explicit year" begin
        d = LandfireDataset(product="CC", region="AK", year=2023)
        @test d.product == "CC"
        @test d.region == "AK"
        @test d.year == 2023
    end

    @testset "help" begin
        @test help(Landfire()) isa AbstractString
        @test help(LandfireDataset()) isa AbstractString
    end

    @testset "_landfire_year" begin
        @test _landfire_year(2023, "CONUS") == 2023
    end

    @testset "URL construction" begin
        ext = Extent(X=(-106.0, -105.0), Y=(39.0, 40.0))
        url = _landfire_build_url("FBFM40", "CONUS", 2024, ext)
        @test occursin("conus_2024/wcs", url)
        @test occursin("CoverageId=landfire_wcs__LF2024_FBFM40_CONUS", url)
        @test occursin("subset=Long(-106.0,-105.0)", url)
        @test occursin("subset=Lat(39.0,40.0)", url)
        @test occursin("version=2.0.1", url)
        @test occursin("format=image/tiff", url)
        @test occursin("subsettingCrs=", url)
    end

    @testset "URL with different year" begin
        ext = Extent(X=(-106.0, -105.0), Y=(39.0, 40.0))
        url = _landfire_build_url("FBFM40", "CONUS", 2025, ext)
        @test occursin("conus_2025/wcs", url)
        @test occursin("LF2025_FBFM40_CONUS", url)
    end

    @testset "LandfireChunk" begin
        c = LandfireChunk("https://example.com/landfire.tif", "FBFM40")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :landfire_FBFM40
        @test GeoFetch.extension(c) == "tif"
    end

    @testset "chunks with explicit year" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.0, 40.0)))
        d = LandfireDataset(year=2024)
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa LandfireChunk
        @test occursin("2024", cs[1].url)
    end

    @testset "chunks requires bounded extent" begin
        p = Project()
        d = LandfireDataset(year=2024)
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid product" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.0, 40.0)))
        d = LandfireDataset(product="INVALID", year=2024)
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid region" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.0, 40.0)))
        d = LandfireDataset(region="EU", year=2024)
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "datasets" begin
        ds = datasets(Landfire())
        @test length(ds) == length(_LANDFIRE_PRODUCTS) * length(_LANDFIRE_REGIONS)
        @test all(d -> d isa Dataset, ds)
        @test all(d -> d.year isa Latest, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(Landfire(); product="FBFM40")
        @test all(d -> d.product == "FBFM40", ds)
        @test length(ds) == length(_LANDFIRE_REGIONS)

        ds = datasets(Landfire(); region="AK")
        @test all(d -> d.region == "AK", ds)

        ds = datasets(Landfire(); product="CC", region="CONUS")
        @test length(ds) == 1
        @test ds[1].product == "CC"
    end

    @testset "popular constants" begin
        @test LANDFIRE_FBFM40 isa LandfireDataset
        @test LANDFIRE_FBFM40.product == "FBFM40"
        @test LANDFIRE_FBFM40.year isa Latest
        @test LANDFIRE_FBFM13 isa LandfireDataset
        @test LANDFIRE_FBFM13.product == "FBFM13"
    end
end
