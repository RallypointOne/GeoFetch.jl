using GeoFetch
using GeoFetch: HRRRArchiveChunk, _HRRR_ARCHIVE_DATASETS, _hrrr_archive_url, HRRR_ARCHIVE_SFC, HRRR_ARCHIVE_PRS
using Downloads
using Test
using Dates

@testset "HRRRArchive" begin
    @testset "HRRRArchive <: Source" begin
        @test HRRRArchive <: Source
    end

    @testset "HRRRArchiveDataset <: Dataset" begin
        @test HRRRArchiveDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = HRRRArchiveDataset()
        @test d.product == "sfc"
        @test d.domain == "conus"
        @test d.forecast_hours == [0]
        @test d.cycles == [0]
    end

    @testset "Dataset with custom parameters" begin
        d = HRRRArchiveDataset(product="prs", domain="alaska", forecast_hours=[0, 1, 2], cycles=[0, 6, 12, 18])
        @test d.product == "prs"
        @test d.domain == "alaska"
        @test d.forecast_hours == [0, 1, 2]
        @test d.cycles == [0, 6, 12, 18]
    end

    @testset "help" begin
        @test help(HRRRArchive()) isa AbstractString
        @test help(HRRRArchiveDataset()) isa AbstractString
    end

    @testset "URL construction" begin
        d = HRRRArchiveDataset(product="sfc", domain="conus")
        url = _hrrr_archive_url(d, Date(2024, 7, 4), 12, 3)
        @test url == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20240704/conus/hrrr.t12z.wrfsfcf03.grib2"
    end

    @testset "URL construction pressure" begin
        d = HRRRArchiveDataset(product="prs", domain="conus")
        url = _hrrr_archive_url(d, Date(2024, 1, 1), 0, 0)
        @test occursin("wrfprs", url)
        @test occursin("hrrr.t00z", url)
    end

    @testset "URL construction native" begin
        d = HRRRArchiveDataset(product="nat", domain="conus")
        url = _hrrr_archive_url(d, Date(2024, 1, 1), 6, 12)
        @test occursin("wrfnat", url)
    end

    @testset "HRRRArchiveChunk" begin
        c = HRRRArchiveChunk("https://example.com/hrrr.grib2", Date(2024, 7, 4), 12, 0, "sfc")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("hrrr_archive_sfc")
        @test GeoFetch.extension(c) == "grib2"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = HRRRArchiveDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid product" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1)))
        d = HRRRArchiveDataset(product="invalid")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid domain" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1)))
        d = HRRRArchiveDataset(domain="invalid")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks single day single cycle" begin
        p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4)))
        d = HRRRArchiveDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].date == Date(2024, 7, 4)
        @test cs[1].cycle == 0
        @test cs[1].forecast_hour == 0
    end

    @testset "chunks multi-day" begin
        p = Project(datetimes=(DateTime(2024, 7, 1), DateTime(2024, 7, 3)))
        d = HRRRArchiveDataset()
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3
        @test cs[1].date == Date(2024, 7, 1)
        @test cs[3].date == Date(2024, 7, 3)
    end

    @testset "chunks multi-cycle multi-forecast" begin
        p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4)))
        d = HRRRArchiveDataset(cycles=[0, 12], forecast_hours=[0, 1, 2])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 6
        @test cs[1].cycle == 0
        @test cs[1].forecast_hour == 0
        @test cs[4].cycle == 12
        @test cs[4].forecast_hour == 0
    end

    @testset "chunks URL structure" begin
        p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4)))
        d = HRRRArchiveDataset(product="sfc", domain="conus", cycles=[6], forecast_hours=[3])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        url = cs[1].url
        @test occursin("noaa-hrrr-bdp-pds", url)
        @test occursin("hrrr.20240704", url)
        @test occursin("conus", url)
        @test occursin("hrrr.t06z", url)
        @test occursin("wrfsfcf03", url)
        @test endswith(url, ".grib2")
    end

    @testset "datasets" begin
        ds = datasets(HRRRArchive())
        @test length(ds) == length(_HRRR_ARCHIVE_DATASETS)
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(HRRRArchive(); product="sfc")
        @test all(d -> d.product == "sfc", ds)

        ds = datasets(HRRRArchive(); domain="alaska")
        @test length(ds) == 1
        @test ds[1].domain == "alaska"
    end

    @testset "popular constants" begin
        @test HRRR_ARCHIVE_SFC isa HRRRArchiveDataset
        @test HRRR_ARCHIVE_SFC.product == "sfc"
        @test HRRR_ARCHIVE_PRS.product == "prs"
    end

    @testset "metadata" begin
        m = metadata(HRRRArchiveDataset())
        @test m[:data_type] == "gridded"
        @test haskey(m, :license)
        @test !haskey(m, :resolution)
    end

    @testset "filesize estimate returns nothing without resolution" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1)))
        @test filesize(p, HRRRArchiveDataset()) === nothing
    end

    @testset "live: HRRR Archive S3 file accessible" begin
        try
            url = _hrrr_archive_url(HRRRArchiveDataset(), Date(2024, 7, 4), 0, 0)
            Downloads.request(url; method="HEAD", output=devnull)
            @test true
        catch e
            @warn "live: HRRR Archive S3 file accessible" exception=(e, catch_backtrace())
        end
    end
end
