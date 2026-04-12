using GeoFetch
using Landfire
using Test
using Extents: Extent

const GeoFetchLandfireExt = Base.get_extension(GeoFetch, :GeoFetchLandfire)

@testset "GeoFetchLandfire" begin
    @test GeoFetchLandfireExt !== nothing

    @testset "types" begin
        @test GeoFetchLandfireExt.LandfireSource <: GeoFetch.Source
        @test GeoFetchLandfireExt.LandfireDataset <: GeoFetch.Dataset
        @test GeoFetchLandfireExt.LandfireChunk <: GeoFetch.Chunk
    end

    prod = Landfire.Product(
        "Fire Behavior Fuel Model 40",
        "Fuels",
        "FBFM40",
        "LF 2024",
        true,
        false,
        false,
        "CONUS",
    )

    @testset "dataset defaults" begin
        d = GeoFetchLandfireExt.LandfireDataset(products=[prod], email="test@example.com")
        @test d.products == [prod]
        @test d.email == "test@example.com"
        @test isnothing(d.output_projection)
        @test isnothing(d.resample_resolution)
    end

    @testset "help" begin
        @test GeoFetch.help(GeoFetchLandfireExt.LandfireSource()) isa AbstractString
        @test GeoFetch.help(GeoFetchLandfireExt.LandfireDataset(products=[prod], email="test@example.com")) isa AbstractString
    end

    @testset "datasets from explicit products" begin
        ds = GeoFetch.datasets(GeoFetchLandfireExt.LandfireSource(); products=[prod])
        @test length(ds) == 1
        @test ds[1] isa GeoFetchLandfireExt.LandfireDataset
        @test ds[1].products == [prod]
    end

    @testset "chunks requires products" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.5, 40.0)))
        d = GeoFetchLandfireExt.LandfireDataset(email="test@example.com")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks requires email" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.5, 40.0)))
        d = GeoFetchLandfireExt.LandfireDataset(products=[prod])
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks requires bounded extent" begin
        p = Project()
        d = GeoFetchLandfireExt.LandfireDataset(products=[prod], email="test@example.com")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks returns single lazy chunk" begin
        p = Project(geometry=Extent(X=(-106.0, -105.0), Y=(39.5, 40.0)))
        d = GeoFetchLandfireExt.LandfireDataset(products=[prod], email="test@example.com")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa GeoFetchLandfireExt.LandfireChunk
        @test GeoFetch.prefix(cs[1]) == :landfire_FBFM40
        @test GeoFetch.extension(cs[1]) == "tif"
        @test cs[1].dataset.job.area_of_interest == "-106.0 39.5 -105.0 40.0"
    end
end
