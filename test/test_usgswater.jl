using GeoFetch
using GeoFetch: USGSWaterChunk, _USGS_WATER_DATASETS, _USGS_COLLECTIONS, _USGS_PARAMETER_CODES,
    _USGS_STATISTICS, _usgs_build_url, USGS_WATER_DAILY_DISCHARGE, USGS_WATER_DAILY_GAGE_HEIGHT,
    USGS_WATER_CONTINUOUS_DISCHARGE
using Test
using Dates
using Extents: Extent

@testset "USGSWater" begin
    @testset "USGSWater <: Source" begin
        @test USGSWater <: Source
    end

    @testset "USGSWaterDataset <: Dataset" begin
        @test USGSWaterDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = USGSWaterDataset()
        @test d.parameter_codes == ["00060"]
        @test d.collection == "daily"
        @test d.statistic_id == "00003"
        @test d.site_ids == String[]
        @test d.format == "json"
    end

    @testset "Dataset with custom parameters" begin
        d = USGSWaterDataset(
            parameter_codes=["00065", "00010"],
            collection="continuous",
            site_ids=["USGS-01646500"],
            format="csv",
        )
        @test d.parameter_codes == ["00065", "00010"]
        @test d.collection == "continuous"
        @test d.site_ids == ["USGS-01646500"]
        @test d.format == "csv"
    end

    @testset "help" begin
        @test help(USGSWater()) isa AbstractString
        @test help(USGSWaterDataset()) isa AbstractString
    end

    @testset "datasets" begin
        ds = datasets(USGSWater())
        @test length(ds) == 4
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering by collection" begin
        ds = datasets(USGSWater(); collection="daily")
        @test length(ds) == 3
        @test all(d -> d.collection == "daily", ds)

        ds = datasets(USGSWater(); collection="continuous")
        @test length(ds) == 1
    end

    @testset "datasets filtering by parameter_code" begin
        ds = datasets(USGSWater(); parameter_code="00060")
        @test length(ds) == 3
        @test all(d -> "00060" in d.parameter_codes, ds)

        ds = datasets(USGSWater(); parameter_code="00065")
        @test length(ds) == 2
    end

    @testset "USGSWaterChunk" begin
        c = USGSWaterChunk("https://api.waterdata.usgs.gov/ogcapi/v0/collections/daily/items?f=json", "00060", "daily")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("usgswater_daily_00060")
        @test GeoFetch.extension(c) == "json"
    end

    @testset "USGSWaterChunk csv extension" begin
        c = USGSWaterChunk("https://api.waterdata.usgs.gov/ogcapi/v0/collections/daily/items?f=csv", "00060", "daily")
        @test GeoFetch.extension(c) == "csv"
    end

    @testset "URL construction - daily with bbox" begin
        d = USGSWaterDataset(parameter_codes=["00060"], collection="daily", statistic_id="00003")
        ext = Extent(X=(-78.0, -76.0), Y=(38.0, 40.0))
        url = _usgs_build_url(d, ext, "00060", Date(2024, 1, 1), Date(2024, 3, 31))
        @test occursin("collections/daily/items", url)
        @test occursin("parameter_code=00060", url)
        @test occursin("bbox=-78.0,38.0,-76.0,40.0", url)
        @test occursin("statistic_id=00003", url)
        @test occursin("time=2024-01-01/2024-03-31", url)
        @test occursin("limit=10000", url)
        @test occursin("f=json", url)
    end

    @testset "URL construction - daily with site_ids" begin
        d = USGSWaterDataset(site_ids=["USGS-01646500", "USGS-01647000"])
        ext = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))
        url = _usgs_build_url(d, ext, "00060", Date(2024, 6, 1), Date(2024, 6, 30))
        @test occursin("monitoring_location_id=USGS-01646500,USGS-01647000", url)
        @test !occursin("bbox", url)
    end

    @testset "URL construction - continuous omits statistic_id" begin
        d = USGSWaterDataset(collection="continuous")
        ext = Extent(X=(-78.0, -76.0), Y=(38.0, 40.0))
        url = _usgs_build_url(d, ext, "00060", Date(2024, 1, 1), Date(2024, 1, 7))
        @test occursin("collections/continuous/items", url)
        @test !occursin("statistic_id", url)
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = USGSWaterDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid collection" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)))
        d = USGSWaterDataset(collection="invalid")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks daily - single parameter" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)),
        )
        d = USGSWaterDataset(parameter_codes=["00060"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa USGSWaterChunk
        @test cs[1].parameter_code == "00060"
        @test cs[1].collection == "daily"
    end

    @testset "chunks daily - multiple parameters" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 31)),
        )
        d = USGSWaterDataset(parameter_codes=["00060", "00065", "00010"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3
        @test cs[1].parameter_code == "00060"
        @test cs[2].parameter_code == "00065"
        @test cs[3].parameter_code == "00010"
    end

    @testset "chunks continuous - short range no split" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 2, 15)),
        )
        d = USGSWaterDataset(collection="continuous")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].collection == "continuous"
    end

    @testset "chunks continuous - splits into 90-day windows" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 12, 31)),
        )
        d = USGSWaterDataset(collection="continuous", parameter_codes=["00060"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 5  # 366 days / 90 = 4.07, so 5 chunks
        @test all(c -> c.collection == "continuous", cs)
    end

    @testset "chunks continuous - multiple params splits each" begin
        p = Project(
            geometry=Extent(X=(-78.0, -76.0), Y=(38.0, 40.0)),
            datetimes=(DateTime(2024, 1, 1), DateTime(2024, 6, 30)),
        )
        d = USGSWaterDataset(collection="continuous", parameter_codes=["00060", "00065"])
        cs = GeoFetch.chunks(p, d)
        n_windows_060 = count(c -> c.parameter_code == "00060", cs)
        n_windows_065 = count(c -> c.parameter_code == "00065", cs)
        @test n_windows_060 == n_windows_065
        @test n_windows_060 == 3  # 182 days / 90 = 3 chunks (90 + 90 + 2)
    end

    @testset "popular constants" begin
        @test USGS_WATER_DAILY_DISCHARGE isa USGSWaterDataset
        @test USGS_WATER_DAILY_DISCHARGE.collection == "daily"
        @test "00060" in USGS_WATER_DAILY_DISCHARGE.parameter_codes

        @test USGS_WATER_DAILY_GAGE_HEIGHT isa USGSWaterDataset
        @test "00065" in USGS_WATER_DAILY_GAGE_HEIGHT.parameter_codes

        @test USGS_WATER_CONTINUOUS_DISCHARGE isa USGSWaterDataset
        @test USGS_WATER_CONTINUOUS_DISCHARGE.collection == "continuous"
    end

    @testset "parameter codes reference" begin
        @test haskey(_USGS_PARAMETER_CODES, "00060")
        @test haskey(_USGS_PARAMETER_CODES, "00065")
        @test haskey(_USGS_PARAMETER_CODES, "00010")
        @test length(_USGS_PARAMETER_CODES) >= 8
    end

    @testset "statistics reference" begin
        @test haskey(_USGS_STATISTICS, "00003")
        @test _USGS_STATISTICS["00003"] == "Mean"
    end

    @testset "live: USGS Water daily discharge" begin
        try
            p = Project(
                geometry=Extent(X=(-77.5, -77.0), Y=(38.8, 39.0)),
                datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 7)),
            )
            d = USGSWaterDataset(parameter_codes=["00060"])
            cs = GeoFetch.chunks(p, d)
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(cs[1]))
            GeoFetch.fetch(cs[1], file)
            @test isfile(file)
            @test filesize(file) > 0
        catch e
            @warn "live: USGS Water daily discharge" exception=(e, catch_backtrace())
        end
    end
end
