using GeoFetch
using GeoFetch: NCEIChunk, _NCEI_DATASETS, _NCEI_DATASET_INFO, _NCEI_MAX_DAYS,
    _ncei_build_url, NCEI_DAILY, NCEI_MONTHLY, NCEI_YEARLY, NCEI_HOURLY, NCEI_NORMALS, NCEI_MARINE
using Test
using Dates
using Extents: Extent

@testset "NCEI" begin
    @testset "NCEI <: Source" begin
        @test NCEI <: Source
    end

    @testset "NCEIDataset <: Dataset" begin
        @test NCEIDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = NCEIDataset()
        @test d.dataset == "daily-summaries"
        @test d.datatypes == ["TMAX", "TMIN", "PRCP"]
        @test d.stations == String[]
        @test d.format == "json"
        @test d.units == "metric"
    end

    @testset "Dataset with custom parameters" begin
        d = NCEIDataset(
            dataset="global-hourly",
            datatypes=String[],
            stations=["72503014732"],
            format="csv",
            units="standard",
        )
        @test d.dataset == "global-hourly"
        @test d.stations == ["72503014732"]
        @test d.format == "csv"
        @test d.units == "standard"
    end

    @testset "help" begin
        @test help(NCEI()) isa AbstractString
        @test help(NCEIDataset()) isa AbstractString
    end

    @testset "datasets" begin
        ds = datasets(NCEI())
        @test length(ds) == 6
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(NCEI(); dataset="daily-summaries")
        @test length(ds) == 1
        @test ds[1].dataset == "daily-summaries"

        ds = datasets(NCEI(); dataset="global-hourly")
        @test length(ds) == 1
    end

    @testset "NCEIChunk json" begin
        c = NCEIChunk("https://example.com?format=json", "daily-summaries", Date(2024, 1, 1), Date(2024, 12, 31))
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :ncei_daily_summaries
        @test GeoFetch.extension(c) == "json"
    end

    @testset "NCEIChunk csv" begin
        c = NCEIChunk("https://example.com?format=csv", "daily-summaries", Date(2024, 1, 1), Date(2024, 12, 31))
        @test GeoFetch.extension(c) == "csv"
    end

    @testset "NCEIChunk prefix varies by dataset" begin
        c = NCEIChunk("https://example.com?format=json", "global-hourly", Date(2024, 1, 1), Date(2024, 12, 31))
        @test GeoFetch.prefix(c) == :ncei_global_hourly
    end

    @testset "URL construction - with stations" begin
        d = NCEIDataset(dataset="daily-summaries", datatypes=["TMAX", "TMIN"], stations=["USC00457180"])
        ext = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))
        url = _ncei_build_url(d, ext, Date(2024, 1, 1), Date(2024, 6, 30))
        @test occursin("dataset=daily-summaries", url)
        @test occursin("startDate=2024-01-01", url)
        @test occursin("endDate=2024-06-30", url)
        @test occursin("dataTypes=TMAX,TMIN", url)
        @test occursin("stations=USC00457180", url)
        @test !occursin("bbox", url)
        @test occursin("units=metric", url)
        @test occursin("format=json", url)
    end

    @testset "URL construction - with bbox" begin
        d = NCEIDataset(dataset="global-marine", datatypes=String[])
        ext = Extent(X=(-78.0, -76.0), Y=(38.0, 40.0))
        url = _ncei_build_url(d, ext, Date(2024, 1, 1), Date(2024, 1, 31))
        @test occursin("boundingBox=40.0,-78.0,38.0,-76.0", url)
        @test !occursin("stations", url)
    end

    @testset "URL construction - multiple stations" begin
        d = NCEIDataset(stations=["USC00457180", "USC00390043"])
        ext = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))
        url = _ncei_build_url(d, ext, Date(2024, 1, 1), Date(2024, 3, 31))
        @test occursin("stations=USC00457180,USC00390043", url)
    end

    @testset "URL construction - no datatypes" begin
        d = NCEIDataset(dataset="global-hourly", datatypes=String[], stations=["72503014732"])
        ext = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))
        url = _ncei_build_url(d, ext, Date(2024, 1, 1), Date(2024, 1, 7))
        @test !occursin("dataTypes", url)
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = NCEIDataset(stations=["USC00457180"])
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks requires stations or bounded extent" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 6, 30)))
        d = NCEIDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks allows bbox without stations" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)),
        )
        d = NCEIDataset(dataset="global-marine", datatypes=String[])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test occursin("boundingBox", cs[1].url)
    end

    @testset "chunks rejects unknown dataset" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 6, 30)))
        d = NCEIDataset(dataset="invalid", stations=["USC00457180"])
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks within one year" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 6, 30)))
        d = NCEIDataset(stations=["USC00457180"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].dataset == "daily-summaries"
        @test cs[1].start_date == Date(2024, 1, 1)
        @test cs[1].end_date == Date(2024, 6, 30)
    end

    @testset "chunks splits long ranges into 365-day windows" begin
        p = Project(datetimes=(DateTime(2022, 1, 1), DateTime(2024, 6, 30)))
        d = NCEIDataset(stations=["USC00457180"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3
        @test cs[1].start_date == Date(2022, 1, 1)
        @test cs[1].end_date == Date(2022, 12, 31)
        @test cs[2].start_date == Date(2023, 1, 1)
        @test cs[2].end_date == Date(2023, 12, 31)
        @test cs[3].start_date == Date(2024, 1, 1)
        @test cs[3].end_date == Date(2024, 6, 30)
    end

    @testset "popular constants" begin
        @test NCEI_DAILY isa NCEIDataset
        @test NCEI_DAILY.dataset == "daily-summaries"

        @test NCEI_MONTHLY isa NCEIDataset
        @test NCEI_MONTHLY.dataset == "global-summary-of-the-month"

        @test NCEI_YEARLY isa NCEIDataset
        @test NCEI_YEARLY.dataset == "global-summary-of-the-year"

        @test NCEI_HOURLY isa NCEIDataset
        @test NCEI_HOURLY.dataset == "global-hourly"

        @test NCEI_NORMALS isa NCEIDataset
        @test NCEI_NORMALS.dataset == "normals-daily"

        @test NCEI_MARINE isa NCEIDataset
        @test NCEI_MARINE.dataset == "global-marine"
    end

    @testset "dataset info reference" begin
        @test haskey(_NCEI_DATASET_INFO, "daily-summaries")
        @test haskey(_NCEI_DATASET_INFO, "global-hourly")
        @test haskey(_NCEI_DATASET_INFO, "global-marine")
        @test length(_NCEI_DATASET_INFO) == 9
    end

    @testset "metadata" begin
        m = metadata(NCEIDataset())
        @test m[:data_type] == "station"
        @test haskey(m, :license)
    end

    @testset "filesize estimate returns nothing for station data" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)))
        @test filesize(p, NCEIDataset()) === nothing
    end

    @testset "live: NCEI daily summaries" begin
        try
            p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)))
            d = NCEIDataset(stations=["USC00457180"])
            cs = GeoFetch.chunks(p, d)
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(cs[1]))
            GeoFetch.fetch(cs[1], file)
            @test isfile(file)
            @test filesize(file) > 0
        catch e
            @warn "live: NCEI daily summaries" exception=(e, catch_backtrace())
        end
    end
end
