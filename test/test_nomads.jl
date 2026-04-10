using GeoFetch
using Test
using Dates
using Extents: Extent

const NOMADS = GeoFetch.NOMADS

@testset "NOMADS" begin
    @testset "Dataset <: GeoFetch.Dataset" begin
        @test NOMADS.Dataset <: GeoFetch.Dataset
    end

    @testset "DATASETS" begin
        @test length(NOMADS.DATASETS) > 0
        @test all(d -> d isa GeoFetch.Dataset, NOMADS.DATASETS)
        @test all(d -> !isempty(d.name), NOMADS.DATASETS)
    end

    @testset "Dataset defaults" begin
        d = NOMADS.DATASETS[5]
        @test d.parameters isa All
        @test d.levels isa All
    end

    @testset "Dataset with custom parameters" begin
        d = NOMADS.Dataset(category=NOMADS.Global, name="Test", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP", "UGRD"], levels=["2_m_above_ground"])
        @test d.parameters == ["TMP", "UGRD"]
        @test d.levels == ["2_m_above_ground"]
    end

    @testset "URLs" begin
        d = NOMADS.Dataset(category=NOMADS.Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod")
        @test NOMADS._filter_base(d) == "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
        @test NOMADS._https_url(d) == "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
    end

    @testset "_download_url with All() and no extent" begin
        d = NOMADS.Dataset(category=NOMADS.Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod")
        url = NOMADS._download_url(d, "/gfs.20260409/00/atmos", "gfs.t00z.pgrb2.0p25.f000", nothing)
        @test occursin("all_var=on", url)
        @test occursin("all_lev=on", url)
        @test occursin("dir=%2Fgfs.20260409%2F00%2Fatmos", url)
        @test occursin("file=gfs.t00z.pgrb2.0p25.f000", url)
        @test !occursin("subregion", url)
    end

    @testset "_download_url with specific parameters and extent" begin
        d = NOMADS.Dataset(category=NOMADS.Global, name="GFS", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP", "UGRD"], levels=["2_m_above_ground"])
        ext = Extent(X=(-100.0, -80.0), Y=(30.0, 45.0))
        url = NOMADS._download_url(d, "/gfs.20260409/00/atmos", "gfs.t00z.pgrb2.0p25.f000", ext)
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

    @testset "_dir_date" begin
        @test NOMADS._dir_date("/gfs.20260409/12/atmos") == Date(2026, 4, 9)
        @test NOMADS._dir_date("/hrrr.20251225/conus") == Date(2025, 12, 25)
        @test NOMADS._dir_date("no-date-here") === nothing
    end

    @testset "GribChunk" begin
        c = NOMADS.GribChunk("https://example.com/file", "gfs.t00z.pgrb2.0p25.f000", "gfs_0p25")
        @test c isa GeoFetch.Chunk
        @test GeoFetch.prefix(c) == :gfs_0p25
        @test GeoFetch.extension(c) == "grib2"
    end

    @testset "chunks errors without grib_filter" begin
        no_filter = NOMADS.Dataset(category=NOMADS.Global, name="Test", freq="",
            grib_filter="", https="test/prod")
        p = Project()
        @test_throws ErrorException GeoFetch.chunks(p, no_filter)
    end

    @testset "help" begin
        @test hasmethod(GeoFetch.help, Tuple{NOMADS.Dataset})
        @test GeoFetch.help(NOMADS.DATASETS[1]) isa AbstractString
    end

    @testset "Popular dataset consts" begin
        @test NOMADS.GFS_025.grib_filter == "gfs_0p25"
        @test NOMADS.GFS_025_HOURLY.grib_filter == "gfs_0p25_1hr"
        @test NOMADS.HRRR_CONUS.grib_filter == "hrrr_2d"
    end

    @testset "Category enum" begin
        @test NOMADS.Global isa NOMADS.Category
        @test NOMADS.Regional isa NOMADS.Category
        @test NOMADS.Climate isa NOMADS.Category
        @test NOMADS.Ocean isa NOMADS.Category
        @test NOMADS.SpaceWeather isa NOMADS.Category
        @test NOMADS.External isa NOMADS.Category
    end

    @testset "all categories represented" begin
        cats = Set(d.category for d in NOMADS.DATASETS)
        @test NOMADS.Global in cats
        @test NOMADS.Regional in cats
        @test NOMADS.Climate in cats
        @test NOMADS.Ocean in cats
        @test NOMADS.SpaceWeather in cats
        @test NOMADS.External in cats
    end

    @testset "live: _discover GFS" begin
        base = NOMADS._filter_base(NOMADS.GFS_025)
        server_dir, files = NOMADS._discover(base, nothing)
        @test !isempty(server_dir)
        @test startswith(server_dir, "/gfs.")
        @test length(files) > 0
        @test any(f -> occursin("pgrb2", f), files)
    end

    @testset "live: chunks for GFS" begin
        gfs = NOMADS.Dataset(category=NOMADS.Global, name="GFS 0.25 Degree", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP"], levels=["2_m_above_ground"])
        p = Project(geometry=Extent(X=(-90.0, -80.0), Y=(35.0, 40.0)))
        cs = GeoFetch.chunks(p, gfs)
        @test length(cs) > 0
        @test all(c -> c isa NOMADS.GribChunk, cs)
        @test all(c -> occursin("var_TMP=on", c.url), cs)
        @test all(c -> occursin("subregion", c.url), cs)
    end

    @testset "live: fetch single GribChunk" begin
        gfs = NOMADS.Dataset(category=NOMADS.Global, name="GFS 0.25 Degree", freq="",
            grib_filter="gfs_0p25", https="gfs/prod",
            parameters=["TMP"], levels=["surface"])
        p = Project(geometry=Extent(X=(-85.0, -84.0), Y=(35.0, 36.0)))
        cs = GeoFetch.chunks(p, gfs)
        # Pick an f000 file (not anl) for reliable results
        c = cs[findfirst(c -> occursin("f000", c.remote_filename), cs)]
        dir = mktempdir()
        file = joinpath(dir, GeoFetch.filename(c))
        GeoFetch.fetch(c, file)
        @test isfile(file)
        @test filesize(file) > 0
        # GRIB2 magic bytes
        @test read(file, 4) == UInt8[0x47, 0x52, 0x49, 0x42]
    end
end
