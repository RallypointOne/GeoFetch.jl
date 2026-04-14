using GeoFetch
using GeoFetch: NominatimChunk, _NOMINATIM_ENDPOINTS, _NOMINATIM_FORMATS, _nominatim_urlencode
using Test
using Extents: Extent

@testset "Nominatim" begin
    @testset "Nominatim <: Source" begin
        @test Nominatim <: Source
    end

    @testset "NominatimDataset <: Dataset" begin
        @test NominatimDataset <: Dataset
    end

    @testset "Dataset defaults" begin
        d = NominatimDataset()
        @test d.endpoint == "search"
        @test d.q == ""
        @test d.osm_ids == String[]
        @test d.format == "jsonv2"
        @test d.addressdetails == true
        @test d.limit == 10
        @test d.zoom == 18
    end

    @testset "Dataset with custom parameters" begin
        d = NominatimDataset(endpoint="reverse", format="geojson", zoom=10, countrycodes=["us", "ca"])
        @test d.endpoint == "reverse"
        @test d.format == "geojson"
        @test d.zoom == 10
        @test d.countrycodes == ["us", "ca"]
    end

    @testset "help" begin
        @test help(Nominatim()) isa AbstractString
        @test help(NominatimDataset()) isa AbstractString
    end

    @testset "NominatimChunk" begin
        c = NominatimChunk("https://nominatim.openstreetmap.org/search?q=test", "search", "jsonv2")
        @test c isa Chunk
        @test GeoFetch.prefix(c) == :nominatim_search
        @test GeoFetch.extension(c) == "json"
    end

    @testset "NominatimChunk geojson extension" begin
        c = NominatimChunk("https://nominatim.openstreetmap.org/search?q=test", "search", "geojson")
        @test GeoFetch.extension(c) == "geojson"

        c2 = NominatimChunk("https://nominatim.openstreetmap.org/search?q=test", "search", "geocodejson")
        @test GeoFetch.extension(c2) == "geojson"
    end

    @testset "urlencode" begin
        @test _nominatim_urlencode("hello world") == "hello+world"
        @test _nominatim_urlencode("abc123") == "abc123"
        @test _nominatim_urlencode("a&b=c") == "a%26b%3Dc"
    end

    @testset "chunks search requires q" begin
        p = Project()
        d = NominatimDataset(endpoint="search", q="")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks search" begin
        p = Project()
        d = NominatimDataset(endpoint="search", q="Berlin, Germany")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1] isa NominatimChunk
        @test cs[1].endpoint == "search"
        @test occursin("/search?", cs[1].url)
        @test occursin("q=Berlin", cs[1].url)
    end

    @testset "chunks search with viewbox" begin
        ext = Extent(X=(13.0, 14.0), Y=(52.0, 53.0))
        p = Project(extent=ext)
        d = NominatimDataset(endpoint="search", q="cafe")
        cs = GeoFetch.chunks(p, d)
        @test occursin("viewbox=13.0,52.0,14.0,53.0", cs[1].url)
    end

    @testset "chunks reverse requires bounded extent" begin
        p = Project()
        d = NominatimDataset(endpoint="reverse")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks reverse" begin
        ext = Extent(X=(13.3, 13.5), Y=(52.4, 52.6))
        p = Project(extent=ext)
        d = NominatimDataset(endpoint="reverse")
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].endpoint == "reverse"
        @test occursin("/reverse?", cs[1].url)
        @test occursin("lat=52.5", cs[1].url)
        @test occursin("lon=13.4", cs[1].url)
    end

    @testset "chunks lookup requires osm_ids" begin
        p = Project()
        d = NominatimDataset(endpoint="lookup", osm_ids=String[])
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks lookup" begin
        p = Project()
        d = NominatimDataset(endpoint="lookup", osm_ids=["R146656", "W104393803"])
        cs = GeoFetch.chunks(p, d)
        @test length(cs) == 1
        @test cs[1].endpoint == "lookup"
        @test occursin("/lookup?", cs[1].url)
        @test occursin("osm_ids=R146656,W104393803", cs[1].url)
    end

    @testset "chunks rejects invalid endpoint" begin
        p = Project()
        d = NominatimDataset(endpoint="invalid", q="test")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "chunks rejects invalid format" begin
        p = Project()
        d = NominatimDataset(endpoint="search", q="test", format="xml")
        @test_throws ErrorException GeoFetch.chunks(p, d)
    end

    @testset "datasets" begin
        ds = datasets(Nominatim())
        @test length(ds) == 3
        @test all(d -> d isa Dataset, ds)
    end

    @testset "datasets filtering" begin
        ds = datasets(Nominatim(); endpoint="search")
        @test length(ds) == 1
        @test ds[1].endpoint == "search"

        ds = datasets(Nominatim(); endpoint="reverse")
        @test length(ds) == 1
    end

    @testset "custom base_url" begin
        d = NominatimDataset(endpoint="search", q="test", base_url="https://my-nominatim.example.com")
        p = Project()
        cs = GeoFetch.chunks(p, d)
        @test startswith(cs[1].url, "https://my-nominatim.example.com/search?")
    end

    @testset "optional params in URL" begin
        d = NominatimDataset(endpoint="search", q="test", extratags=true, namedetails=true, email="test@example.com", countrycodes=["de"], layer=["poi", "address"])
        p = Project()
        cs = GeoFetch.chunks(p, d)
        url = cs[1].url
        @test occursin("extratags=1", url)
        @test occursin("namedetails=1", url)
        @test occursin("email=test@example.com", url)
        @test occursin("countrycodes=de", url)
        @test occursin("layer=poi,address", url)
    end

    @testset "metadata" begin
        m = metadata(NominatimDataset())
        @test m[:data_type] == "geocoding"
        @test haskey(m, :license)
    end

    @testset "filesize estimate returns nothing for geocoding" begin
        p = Project()
        @test filesize(p, NominatimDataset()) === nothing
    end

    @testset "live: Nominatim search" begin
        try
            p = Project()
            d = NominatimDataset(endpoint="search", q="Statue of Liberty")
            cs = GeoFetch.chunks(p, d)
            dir = mktempdir()
            file = joinpath(dir, GeoFetch.filename(cs[1]))
            GeoFetch.fetch(cs[1], file)
            @test isfile(file)
            @test filesize(file) > 0
        catch e
            @warn "live: Nominatim search" exception=(e, catch_backtrace())
        end
    end
end
