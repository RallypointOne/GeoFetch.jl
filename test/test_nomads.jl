using GeoFetch
using GeoFetch: Category, Global, Regional, Climate, Ocean, SpaceWeather, External,
    GribChunk, _NOMADS_DATASETS, _nomads_filter_base, _nomads_https_url,
    _nomads_download_url, _nomads_dir_date, _nomads_discover, GFS_025, GFS_025_HOURLY,
    HRRR_CONUS
using Test
using Dates
using Extents: Extent

@testset "NOMADS" begin
    @testset "NOMADS <: Source" begin
        @test NOMADS <: Source
    end

    @testset "NomadsDataset <: Dataset" begin
        @test NomadsDataset <: Dataset
    end

    @testset "datasets" begin
        ds = datasets(NOMADS())
        @test length(ds) > 0
        @test all(d -> d isa Dataset, ds)
        @test all(d -> !isempty(d.name), ds)
    end

    @testset "Dataset defaults" begin
        d = _NOMADS_DATASETS[5]
        @test d.parameters isa All
        @test d.levels isa All
    end

    @testset "Dataset with custom parameters" begin
        d = NomadsDataset(category=Global, name="Test", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP", "UGRD"], levels=["2_m_above_ground"])
        @test d.parameters == ["TMP", "UGRD"]
        @test d.levels == ["2_m_above_ground"]
    end

    @testset "URLs" begin
        d = NomadsDataset(category=Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod")
        @test _nomads_filter_base(d) == "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
        @test _nomads_https_url(d) == "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
    end

    @testset "_nomads_download_url with All() and no extent" begin
        d = NomadsDataset(category=Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod")
        url = _nomads_download_url(d, "/gfs.20260409/00/atmos", "gfs.t00z.pgrb2.0p25.f000", nothing)
        @test occursin("all_var=on", url)
        @test occursin("all_lev=on", url)
        @test occursin("dir=%2Fgfs.20260409%2F00%2Fatmos", url)
        @test occursin("file=gfs.t00z.pgrb2.0p25.f000", url)
        @test !occursin("subregion", url)
    end

    @testset "_nomads_download_url with specific parameters and extent" begin
        d = NomadsDataset(category=Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP", "UGRD"], levels=["2_m_above_ground"])
        ext = Extent(X=(-100.0, -80.0), Y=(30.0, 45.0))
        url = _nomads_download_url(d, "/gfs.20260409/00/atmos", "gfs.t00z.pgrb2.0p25.f000", ext)
        @test occursin("var_TMP=on", url)
        @test occursin("var_UGRD=on", url)
        @test !occursin("all_var=on", url)
        @test occursin("lev_2_m_above_ground=on", url)
        @test !occursin("all_lev=on", url)
        @test occursin("subregion=", url)
        @test occursin("toplat=45.0", url)
        @test occursin("bottomlat=30.0", url)
        @test occursin("leftlon=-100.0", url)
        @test occursin("rightlon=-80.0", url)
    end

    @testset "_nomads_dir_date" begin
        @test _nomads_dir_date("/gfs.20260409/12/atmos") == Date(2026, 4, 9)
        @test _nomads_dir_date("/hrrr.20251225/conus") == Date(2025, 12, 25)
        @test _nomads_dir_date("no-date-here") === nothing
    end

    @testset "GribChunk" begin
        c = GribChunk("https://example.com/file", "gfs.t00z.pgrb2.0p25.f000", "gfs_0p25")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :gfs_0p25
        @test GeoFetch.extension(c) == "grib2"
    end

    @testset "chunks errors without grib_filter" begin
        no_filter = NomadsDataset(category=Global, name="Test", freq="",
            grib_filter="", https="test/prod")
        p = Project()
        @test_throws ErrorException GeoFetch.chunks(p, no_filter)
    end

    @testset "help" begin
        @test help(NOMADS()) isa AbstractString
        @test help(_NOMADS_DATASETS[1]) isa AbstractString
    end

    @testset "Popular dataset consts" begin
        @test GFS_025.grib_filter == "gfs_0p25"
        @test GFS_025_HOURLY.grib_filter == "gfs_0p25_1hr"
        @test HRRR_CONUS.grib_filter == "hrrr_2d"
    end

    @testset "Category enum" begin
        @test Global isa Category
        @test Regional isa Category
        @test Climate isa Category
        @test Ocean isa Category
        @test SpaceWeather isa Category
        @test External isa Category
    end

    @testset "all categories represented" begin
        cats = Set(d.category for d in datasets(NOMADS()))
        @test Global in cats
        @test Regional in cats
        @test Climate in cats
        @test Ocean in cats
        @test SpaceWeather in cats
        @test External in cats
    end

    @testset "datasets filtering" begin
        gfs = datasets(NOMADS(); name="GFS")
        @test all(d -> occursin("GFS", d.name), gfs)
        @test length(gfs) > 0

        regional = datasets(NOMADS(); category=Regional)
        @test all(d -> d.category == Regional, regional)

        empty_result = datasets(NOMADS(); name="nonexistent-xyz")
        @test isempty(empty_result)
    end

    @testset "live: _nomads_discover GFS" begin
        try
            base = _nomads_filter_base(GFS_025)
            server_dir, files = _nomads_discover(base, nothing)
            @test !isempty(server_dir)
            @test startswith(server_dir, "/gfs.")
            @test length(files) > 0
            @test any(f -> occursin("pgrb2", f), files)
        catch e
            @warn "live: _nomads_discover GFS" exception=(e, catch_backtrace())
        end
    end

    @testset "live: chunks for GFS" begin
        try
            gfs = NomadsDataset(category=Global, name="GFS 0.25 Degree", freq="",
                grib_filter="gfs_0p25", https="gfs/prod",
                parameters=["TMP"], levels=["2_m_above_ground"])
            p = Project(geometry=Extent(X=(-90.0, -80.0), Y=(35.0, 40.0)))
            cs = GeoFetch.chunks(p, gfs)
            @test length(cs) > 0
            @test all(c -> c isa GribChunk, cs)
            @test all(c -> occursin("var_TMP=on", c.url), cs)
            @test all(c -> occursin("subregion", c.url), cs)
        catch e
            @warn "live: chunks for GFS" exception=(e, catch_backtrace())
        end
    end

    @testset "live: fetch single GribChunk" begin
        try
            gfs = NomadsDataset(category=Global, name="GFS 0.25 Degree", freq="",
                grib_filter="gfs_0p25", https="gfs/prod",
                parameters=["TMP"], levels=["surface"])
            p = Project(geometry=Extent(X=(-85.0, -84.0), Y=(35.0, 36.0)))
            cs = GeoFetch.chunks(p, gfs)
            c = cs[findfirst(c -> occursin("f000", c.remote_filename), cs)]
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(c))
            GeoFetch.fetch(c, file)
            @test isfile(file)
            @test filesize(file) > 0
            @test read(file, 4) == UInt8[0x47, 0x52, 0x49, 0x42]
        catch e
            @warn "live: fetch single GribChunk" exception=(e, catch_backtrace())
        end
    end
end
