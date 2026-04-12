using GeoFetch
using GeoFetch: NASAPowerChunk, _NASAPOWER_DATASETS, _NASAPOWER_VARIABLES, _NASAPOWER_COMMUNITIES,
    _nasapower_build_url, NASAPOWER_WEATHER, NASAPOWER_SURFACE, NASAPOWER_SOLAR
using Test
using Dates
using Extents: Extent

@testset "NASAPower" begin
    @testset "NASAPower <: Source" begin
        @test NASAPower <: Source
    end

    @testset "NASAPowerDataset <: Dataset" begin
        @test NASAPowerDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = NASAPowerDataset()
        @test d.variables == ["T2M", "PRECTOTCORR"]
        @test d.community == "AG"
        @test d.query_type == "point"
    end

    @testset "Dataset with custom parameters" begin
        d = NASAPowerDataset(variables=["WS10M", "PS"], community="RE", query_type="regional")
        @test d.variables == ["WS10M", "PS"]
        @test d.community == "RE"
        @test d.query_type == "regional"
    end

    @testset "help" begin
        @test help(NASAPower()) isa AbstractString
        @test help(NASAPowerDataset()) isa AbstractString
    end

    @testset "datasets" begin
        ds = datasets(NASAPower())
        @test length(ds) == 3
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(NASAPower(); community="AG")
        @test length(ds) == 3
        @test all(d -> d.community == "AG", ds)
    end

    @testset "NASAPowerChunk" begin
        c = NASAPowerChunk("https://power.larc.nasa.gov/api/test", ["T2M"], "point")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :nasapower_point
        @test GeoFetch.extension(c) == "json"
    end

    @testset "NASAPowerChunk regional prefix" begin
        c = NASAPowerChunk("https://power.larc.nasa.gov/api/test", ["T2M"], "regional")
        @test GeoFetch.prefix(c) == :nasapower_regional
    end

    @testset "URL construction - point" begin
        d = NASAPowerDataset(variables=["T2M", "RH2M"], community="AG", query_type="point")
        ext = Extent(X=(-74.0, -74.0), Y=(40.7, 40.7))
        url = _nasapower_build_url(d, ext, Date(2024, 1, 1), Date(2024, 1, 7))
        @test occursin("temporal/daily/point", url)
        @test occursin("parameters=T2M,RH2M", url)
        @test occursin("community=AG", url)
        @test occursin("longitude=-74.0", url)
        @test occursin("latitude=40.7", url)
        @test occursin("start=20240101", url)
        @test occursin("end=20240107", url)
        @test occursin("format=JSON", url)
    end

    @testset "URL construction - regional" begin
        d = NASAPowerDataset(variables=["T2M"], community="AG", query_type="regional")
        ext = Extent(X=(-80.0, -70.0), Y=(35.0, 45.0))
        url = _nasapower_build_url(d, ext, Date(2024, 6, 1), Date(2024, 6, 30))
        @test occursin("temporal/daily/regional", url)
        @test occursin("longitude-min=-80.0", url)
        @test occursin("longitude-max=-70.0", url)
        @test occursin("latitude-min=35.0", url)
        @test occursin("latitude-max=45.0", url)
        @test occursin("start=20240601", url)
        @test occursin("end=20240630", url)
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = NASAPowerDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid community" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)))
        d = NASAPowerDataset(community="INVALID")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid query_type" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)))
        d = NASAPowerDataset(query_type="invalid")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks point returns single chunk" begin
        p = Project(
            geometry=Extent(X=(-74.0, -74.0), Y=(40.7, 40.7)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)),
        )
        d = NASAPowerDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa NASAPowerChunk
        @test cs[1].query_type == "point"
        @test occursin("temporal/daily/point", cs[1].url)
    end

    @testset "chunks regional returns single chunk" begin
        p = Project(
            geometry=Extent(X=(-80.0, -70.0), Y=(35.0, 45.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)),
        )
        d = NASAPowerDataset(query_type="regional")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].query_type == "regional"
        @test occursin("temporal/daily/regional", cs[1].url)
    end

    @testset "chunks regional rejects small extent" begin
        p = Project(
            geometry=Extent(X=(-74.5, -73.5), Y=(40.0, 41.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)),
        )
        d = NASAPowerDataset(query_type="regional")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "popular constants" begin
        @test NASAPOWER_WEATHER isa NASAPowerDataset
        @test "T2M" in NASAPOWER_WEATHER.variables
        @test "PRECTOTCORR" in NASAPOWER_WEATHER.variables

        @test NASAPOWER_SURFACE isa NASAPowerDataset
        @test "T2M" in NASAPOWER_SURFACE.variables
        @test "PS" in NASAPOWER_SURFACE.variables

        @test NASAPOWER_SOLAR isa NASAPowerDataset
        @test "ALLSKY_SFC_SW_DWN" in NASAPOWER_SOLAR.variables
    end
end
