using GeoFetch
using GeoFetch: GOESChunk, _GOES_DATASETS, _GOES_S3_BASE, _goes_s3_prefix, _goes_urlencode, GOES16_CMIP, GOES18_CMIP, GOES16_SST, GOES16_GLM
using Test
using Dates

@testset "GOES" begin
    @testset "GOES <: Source" begin
        @test GOES <: Source
    end

    @testset "GOESDataset <: Dataset" begin
        @test GOESDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = GOESDataset()
        @test d.satellite == "goes16"
        @test d.product == "ABI-L2-CMIPF"
        @test isnothing(d.band)
    end

    @testset "Dataset with custom parameters" begin
        d = GOESDataset(satellite="goes18", product="ABI-L2-SSTF", band=13)
        @test d.satellite == "goes18"
        @test d.product == "ABI-L2-SSTF"
        @test d.band == 13
    end

    @testset "help" begin
        @test help(GOES()) isa AbstractString
        @test help(GOESDataset()) isa AbstractString
    end

    @testset "S3 base URLs" begin
        @test haskey(_GOES_S3_BASE, "goes16")
        @test haskey(_GOES_S3_BASE, "goes17")
        @test haskey(_GOES_S3_BASE, "goes18")
    end

    @testset "S3 prefix construction" begin
        dt = DateTime(2024, 7, 4, 18, 30)
        prefix = _goes_s3_prefix("ABI-L2-CMIPF", dt)
        @test prefix == "ABI-L2-CMIPF/2024/186/18/"

        dt2 = DateTime(2024, 1, 1, 0, 0)
        prefix2 = _goes_s3_prefix("ABI-L1b-RadC", dt2)
        @test prefix2 == "ABI-L1b-RadC/2024/001/00/"
    end

    @testset "URL encoding" begin
        @test _goes_urlencode("hello") == "hello"
        @test _goes_urlencode("a b") == "a%20b"
        @test _goes_urlencode("a+b") == "a%2Bb"
    end

    @testset "GOESChunk" begin
        c = GOESChunk("https://noaa-goes16.s3.amazonaws.com/ABI-L2-CMIPF/file.nc", "ABI-L2-CMIPF/file.nc", "goes16", "ABI-L2-CMIPF")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == Symbol("goes_goes16")
        @test GeoFetch.extension(c) == "nc"
    end

    @testset "chunks requires datetimes" begin
        p = Project()
        d = GOESDataset()
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid satellite" begin
        p = Project(datetimes=(DateTime(2024, 1, 1), DateTime(2024, 1, 1, 0, 30)))
        d = GOESDataset(satellite="goes15")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "datasets" begin
        ds = datasets(GOES())
        @test length(ds) == length(_GOES_DATASETS)
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(GOES(); satellite="goes18")
        @test all(d -> d.satellite == "goes18", ds)

        ds = datasets(GOES(); product="SST")
        @test all(d -> occursin("SST", d.product), ds)
    end

    @testset "popular constants" begin
        @test GOES16_CMIP isa GOESDataset
        @test GOES16_CMIP.satellite == "goes16"
        @test GOES18_CMIP.satellite == "goes18"
        @test GOES16_SST.product == "ABI-L2-SSTF"
        @test GOES16_GLM.product == "GLM-L2-LCFA"
    end

    @testset "live: GOES S3 listing" begin
        try
            p = Project(datetimes=(DateTime(2024, 7, 4), DateTime(2024, 7, 4, 0, 30)))
            cs = GeoFetch.chunks(p, GOESDataset())
            @test length(cs) > 0
            @test all(c -> c isa GOESChunk, cs)
        catch e
            @warn "live: GOES S3 listing" exception=(e, catch_backtrace())
        end
    end
end
