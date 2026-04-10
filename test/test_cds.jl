using GeoFetch
using Test
using Dates
using Extents: Extent

const CDS = GeoFetch.CDS

@testset "CDS" begin
    @testset "Dataset <: GeoFetch.Dataset" begin
        @test CDS.Dataset <: GeoFetch.Dataset
    end

    @testset "Dataset defaults" begin
        d = CDS.ERA5_SINGLE_LEVELS
        @test d.dataset_id == "reanalysis-era5-single-levels"
        @test d.product_type == "reanalysis"
        @test d.format == "netcdf"
        @test d.times == ["00:00", "06:00", "12:00", "18:00"]
    end

    @testset "Dataset with custom parameters" begin
        d = CDS.Dataset(
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
        d = CDS.ERA5_SINGLE_LEVELS
        @test GeoFetch.help(d) == "https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels"
    end

    @testset "CDSChunk" begin
        c = CDS.CDSChunk("reanalysis-era5-single-levels", "{}")
        @test c isa GeoFetch.Chunk
        @test GeoFetch.prefix(c) == Symbol("reanalysis-era5-single-levels")
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = CDS.ERA5_SINGLE_LEVELS
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks splits by month" begin
        p = Project(
            datetimes=(DateTime(2023, 1, 15), DateTime(2023, 3, 10)),
        )
        d = CDS.Dataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 3  # Jan, Feb, Mar
        @test all(c -> c.dataset_id == "reanalysis-era5-single-levels", cs)
        @test occursin("2023-01-15/2023-01-31", cs[1].body)
        @test occursin("2023-02-01/2023-02-28", cs[2].body)
        @test occursin("2023-03-01/2023-03-10", cs[3].body)
    end

    @testset "body uses inputs wrapper" begin
        using JSON
        p = Project(datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)))
        d = CDS.Dataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
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
        d = CDS.Dataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test occursin("\"area\"", cs[1].body)
        @test occursin("70.0", cs[1].body)
        @test occursin("-10.0", cs[1].body)
    end

    @testset "chunks without subregion (EARTH)" begin
        p = Project(
            datetimes=(DateTime(2023, 6, 1), DateTime(2023, 6, 30)),
        )
        d = CDS.Dataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        @test !occursin("\"area\"", cs[1].body)
    end

    @testset "_build_body includes pressure_levels" begin
        p = Project(datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)))
        d = CDS.Dataset(
            dataset_id="reanalysis-era5-pressure-levels",
            variables=["t"],
            pressure_levels=["500", "850"]
        )
        cs = GeoFetch.chunks(p, d)
        @test occursin("\"pressure_level\"", cs[1].body)
        @test occursin("\"500\"", cs[1].body)
        @test occursin("\"850\"", cs[1].body)
    end

    @testset "_build_body produces valid JSON" begin
        using JSON
        p = Project(
            geometry=Extent(X=(-80.0, -79.0), Y=(35.0, 36.0)),
            datetimes=(DateTime(2023, 1, 1), DateTime(2023, 1, 31)),
        )
        d = CDS.Dataset(dataset_id="reanalysis-era5-single-levels", variables=["2t"])
        cs = GeoFetch.chunks(p, d)
        parsed = JSON.parse(cs[1].body)
        @test haskey(parsed, "inputs")
        @test parsed["inputs"]["variable"] == ["2t"]
        @test parsed["inputs"]["product_type"] == ["reanalysis"]
        @test parsed["inputs"]["area"] == [36.0, -80.0, 35.0, -79.0]
    end

    @testset "DATASETS" begin
        @test length(CDS.DATASETS) > 0
        @test all(d -> d isa GeoFetch.Dataset, CDS.DATASETS)
        @test all(d -> !isempty(d.dataset_id), CDS.DATASETS)
    end

    @testset "Popular dataset consts" begin
        @test CDS.ERA5_SINGLE_LEVELS.dataset_id == "reanalysis-era5-single-levels"
        @test CDS.ERA5_PRESSURE_LEVELS.dataset_id == "reanalysis-era5-pressure-levels"
        @test CDS.ERA5_SINGLE_LEVELS_MONTHLY.dataset_id == "reanalysis-era5-single-levels-monthly-means"
        @test CDS.ERA5_PRESSURE_LEVELS_MONTHLY.dataset_id == "reanalysis-era5-pressure-levels-monthly-means"
        @test CDS.ERA5_LAND.dataset_id == "reanalysis-era5-land"
    end

    @testset "datasets filtering" begin
        era5 = CDS.datasets(dataset_id="era5")
        @test all(k -> occursin("era5", k), keys(era5))
        @test length(era5) > 0

        reanalysis = CDS.datasets(product_type="reanalysis")
        @test all(d -> occursin("reanalysis", d.product_type), values(reanalysis))

        empty_result = CDS.datasets(dataset_id="nonexistent-xyz")
        @test isempty(empty_result)
    end

    has_cds_key = !isempty(get(ENV, "CDSAPI_KEY", "")) || isfile(joinpath(homedir(), ".cdsapirc"))

    if has_cds_key
        @testset "live: CDS API responds" begin
            d = CDS.Dataset(
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
            url = "$(CDS.API_BASE)/retrieve/v1/processes/reanalysis-era5-single-levels/execute/"
            resp = CDS._post_json(url, first(cs).body)
            # Either a job was created or we got a known error (license, etc.)
            @test haskey(resp, "jobID") || haskey(resp, "type") || haskey(resp, "status")
        end
    else
        @info "Skipping live CDS tests (no CDSAPI_KEY or ~/.cdsapirc found)"
    end
end
