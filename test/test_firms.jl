using GeoFetch
using GeoFetch: FireChunk, FIRMS_SOURCES, _FIRMS_DATASETS, _firms_area_string
using Test
using Dates
using Extents: Extent

@testset "FIRMS" begin
    @testset "FIRMS <: Source" begin
        @test FIRMS <: Source
    end

    @testset "FIRMSDataset <: Dataset" begin
        @test FIRMSDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = FIRMSDataset()
        @test d.source == "VIIRS_SNPP_NRT"
        @test d.format == "csv"
    end

    @testset "Dataset with custom parameters" begin
        d = FIRMSDataset(source="MODIS_NRT", format="json")
        @test d.source == "MODIS_NRT"
        @test d.format == "json"
    end

    @testset "help" begin
        @test help(FIRMS()) isa AbstractString
        @test help(FIRMSDataset()) isa AbstractString
    end

    @testset "FIRMS_SOURCES" begin
        @test length(FIRMS_SOURCES) > 0
        @test "VIIRS_SNPP_NRT" in FIRMS_SOURCES
        @test "MODIS_NRT" in FIRMS_SOURCES
        @test "VIIRS_NOAA20_NRT" in FIRMS_SOURCES
    end

    @testset "datasets" begin
        ds = datasets(FIRMS())
        @test length(ds) == length(FIRMS_SOURCES)
        @test all(d -> d isa Dataset, ds)
    end

    @testset "FireChunk" begin
        c = FireChunk("https://firms.modaps.eosdis.nasa.gov/api/area/csv/KEY/VIIRS_SNPP_NRT/world/1/2024-01-01", "VIIRS_SNPP_NRT", Date(2024, 1, 1), 1)
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("firms_VIIRS_SNPP_NRT")
        @test GeoFetch.extension(c) == "csv"
    end

    @testset "FireChunk json extension" begin
        c = FireChunk("https://firms.modaps.eosdis.nasa.gov/api/area/json/KEY/VIIRS_SNPP_NRT/world/1/2024-01-01", "VIIRS_SNPP_NRT", Date(2024, 1, 1), 1)
        @test GeoFetch.extension(c) == "json"
    end

    @testset "_firms_area_string" begin
        @test _firms_area_string(GeoFetch.EARTH) == "world"
        ext = Extent(X=(-125.0, -114.0), Y=(32.0, 42.0))
        @test _firms_area_string(ext) == "-125.0,32.0,-114.0,42.0"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = FIRMSDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects unknown source" begin
        withenv("FIRMS_MAP_KEY" => "testkey") do
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 3)))
            d = FIRMSDataset(source="INVALID_SOURCE")
            @test_throws ErrorException GeoFetch.chunks(p, d)
        end
    end

    @testset "chunks requires FIRMS_MAP_KEY" begin
        withenv("FIRMS_MAP_KEY" => nothing) do
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 3)))
            d = FIRMSDataset()
            @test_throws ErrorException GeoFetch.chunks(p, d)
        end
    end

    @testset "chunks splits into 5-day windows" begin
        withenv("FIRMS_MAP_KEY" => "testkey") do
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 12)))
            d = FIRMSDataset()
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 3
            @test cs[1].day_range == 5
            @test cs[2].day_range == 5
            @test cs[3].day_range == 2
            @test cs[1].start_date == Date(2024, 1, 1)
            @test cs[2].start_date == Date(2024, 1, 6)
            @test cs[3].start_date == Date(2024, 1, 11)
        end
    end

    @testset "chunks single day" begin
        withenv("FIRMS_MAP_KEY" => "testkey") do
            p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4)))
            d = FIRMSDataset()
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 1
            @test cs[1].day_range == 1
            @test cs[1].start_date == Date(2024, 7, 4)
        end
    end

    @testset "chunks URL structure" begin
        withenv("FIRMS_MAP_KEY" => "abc123") do
            p = Project(
                geometry=Extent(X=(-125.0, -114.0), Y=(32.0, 42.0)),
                datetimes=(DateTime(2024, 7, 1), DateTime(2024, 7, 3)),
            )
            d = FIRMSDataset(source="VIIRS_SNPP_NRT", format="csv")
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 1
            url = cs[1].url
            @test occursin("/api/area/csv/", url)
            @test occursin("abc123", url)
            @test occursin("VIIRS_SNPP_NRT", url)
            @test occursin("-125.0,32.0,-114.0,42.0", url)
            @test occursin("/3/", url)
            @test occursin("2024-07-01", url)
        end
    end

    @testset "chunks global extent uses 'world'" begin
        withenv("FIRMS_MAP_KEY" => "testkey") do
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1)))
            d = FIRMSDataset()
            cs = GeoFetch.chunks(p, d)
            @test occursin("/world/", cs[1].url)
        end
    end

    @testset "chunks json format" begin
        withenv("FIRMS_MAP_KEY" => "testkey") do
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1)))
            d = FIRMSDataset(format="json")
            cs = GeoFetch.chunks(p, d)
            @test occursin("/api/area/json/", cs[1].url)
        end
    end

    has_firms_key = !isempty(get(ENV, "FIRMS_MAP_KEY", ""))

    if has_firms_key
        @testset "live: fetch single FireChunk" begin
            p = Project(
                geometry=Extent(X=(-120.0, -119.0), Y=(34.0, 35.0)),
                datetimes=(DateTime(2024, 7, 1), DateTime(2024, 7, 1)),
            )
            d = FIRMSDataset(source="VIIRS_SNPP_NRT")
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 1
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(cs[1]))
            GeoFetch.fetch(cs[1], file)
            @test isfile(file)
            @test filesize(file) > 0
        end
    else
        @info "Skipping live FIRMS tests (no FIRMS_MAP_KEY found)"
    end
end
