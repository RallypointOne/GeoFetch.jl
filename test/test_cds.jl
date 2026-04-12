using GeoFetch
using GeoFetch: CDSChunk, _CDS_DATASETS, _CDS_API_BASE, _cds_post_json,
    ERA5_SINGLE_LEVELS, ERA5_PRESSURE_LEVELS, ERA5_SINGLE_LEVELS_MONTHLY,
    ERA5_PRESSURE_LEVELS_MONTHLY, ERA5_LAND
using Test
using Dates
using JSON
using Extents: Extent

@testset "CDS" begin
    @testset "CDS <: Source" begin
        @test CDS <: Source
    end

    @testset "CDSDataset <: Dataset" begin
        @test CDSDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = ERA5_SINGLE_LEVELS
        @test d.dataset_id == "reanalysis-era5-single-levels"
        @test d.product_type == "reanalysis"
        @test d.format == "netcdf"
        @test d.times == ["00:00", "06:00", "12:00", "18:00"]
    end

    @testset "Dataset with custom parameters" begin
        d = CDSDataset(
            dataset_id="reanalysis-era5-single-levels",
            variables=["2t", "10u"],
            times=["12:00"],
            format="grib"
        )
        @test d.variables == ["2t", "10u"]
        @test d.times == ["12:00"]
        @test d.format == "grib"
    end

    @testset "help URL" begin
        @test help(CDS()) isa AbstractString
        @test help(ERA5_SINGLE_LEVELS) == "https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels"
    end

    @testset "CDSChunk" begin
        c = CDSChunk("reanalysis-era5-single-levels", "{}")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("reanalysis-era5-single-levels")
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = ERA5_SINGLE_LEVELS
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks splits by month" begin
        p = Project(datetimes=(DateTime(2023, 1, 15), DateTime(2023, 3, 10)))
        d = CDSDataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3
        @test all(c -> c.dataset_id == "reanalysis-era5-single-levels", cs)
        @test occursin("2023-01-15/2023-01-31", cs[1].body)
        @test occursin("2023-02-01/2023-02-28", cs[2].body)
        @test occursin("2023-03-01/2023-03-10", cs[3].body)
    end

    @testset "body uses inputs wrapper" begin
        p = Project(datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)))
        d = CDSDataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        parsed = JSON.parse(cs[1].body)
        @test haskey(parsed, "inputs")
        @test parsed["inputs"]["data_format"] == "netcdf"
        @test parsed["inputs"]["product_type"] == ["reanalysis"]
    end

    @testset "chunks with subregion" begin
        p = Project(
            geometry=Extent(X=(-10.0, 30.0), Y=(35.0, 70.0)),
            datetimes=(DateTime(2023, 6, 1), DateTime(2023, 6, 30)),
        )
        d = CDSDataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test occursin("\"area\"", cs[1].body)
        @test occursin("70.0", cs[1].body)
        @test occursin("-10.0", cs[1].body)
    end

    @testset "chunks without subregion (EARTH)" begin
        p = Project(datetimes=(DateTime(2023, 6, 1), DateTime(2023, 6, 30)))
        d = CDSDataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test !occursin("\"area\"", cs[1].body)
    end

    @testset "body includes pressure_levels" begin
        p = Project(datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)))
        d = CDSDataset(
            dataset_id="reanalysis-era5-pressure-levels",
            variables=["t"],
            pressure_levels=["500", "850"]
        )
        cs = GeoFetch.chunks(p, d)
        @test occursin("\"pressure_level\"", cs[1].body)
        @test occursin("\"500\"", cs[1].body)
        @test occursin("\"850\"", cs[1].body)
    end

    @testset "body produces valid JSON" begin
        p = Project(
            geometry=Extent(X=(-80.0, -79.0), Y=(35.0, 36.0)),
            datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)),
        )
        d = CDSDataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        parsed = JSON.parse(cs[1].body)
        @test haskey(parsed, "inputs")
        @test parsed["inputs"]["variable"] == ["2t"]
        @test parsed["inputs"]["product_type"] == ["reanalysis"]
        @test parsed["inputs"]["area"] == [36.0, -80.0, 35.0, -79.0]
    end

    @testset "datasets" begin
        ds = datasets(CDS())
        @test length(ds) > 0
        @test all(d -> d isa Dataset, ds)
        @test all(d -> !isempty(d.dataset_id), ds)
    end

    @testset "Popular dataset consts" begin
        @test ERA5_SINGLE_LEVELS.dataset_id == "reanalysis-era5-single-levels"
        @test ERA5_PRESSURE_LEVELS.dataset_id == "reanalysis-era5-pressure-levels"
        @test ERA5_SINGLE_LEVELS_MONTHLY.dataset_id == "reanalysis-era5-single-levels-monthly-means"
        @test ERA5_PRESSURE_LEVELS_MONTHLY.dataset_id == "reanalysis-era5-pressure-levels-monthly-means"
        @test ERA5_LAND.dataset_id == "reanalysis-era5-land"
    end

    @testset "datasets filtering" begin
        era5 = datasets(CDS(); dataset_id="era5")
        @test all(d -> occursin("era5", d.dataset_id), era5)
        @test length(era5) > 0

        reanalysis = datasets(CDS(); product_type="reanalysis")
        @test all(d -> occursin("reanalysis", d.product_type), reanalysis)

        empty_result = datasets(CDS(); dataset_id="nonexistent-xyz")
        @test isempty(empty_result)
    end

    has_cds_key = !isempty(get(ENV, "CDSAPI_KEY", "")) || isfile(joinpath(homedir(), ".cdsapirc"))

    if has_cds_key
        @testset "live: CDS API responds" begin
            d = CDSDataset(
                dataset_id="reanalysis-era5-single-levels",
                variables=["2m_temperature"],
                times=["12:00"],
            )
            p = Project(
                geometry=Extent(X=(-80.0, -79.0), Y=(35.0, 36.0)),
                datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 1)),
            )
            cs = GeoFetch.chunks(p, d)
            @test length(cs) == 1
            url = "$(_CDS_API_BASE)/retrieve/v1/processes/reanalysis-era5-single-levels/execute/"
            resp = _cds_post_json(url, first(cs).body)
            @test haskey(resp, "jobID") || haskey(resp, "type") || haskey(resp, "status")
        end
    else
        @info "Skipping live CDS tests (no CDSAPI_KEY or ~/.cdsapirc found)"
    end
end
