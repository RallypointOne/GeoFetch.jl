using GeoFetch
using Test
using Extents: Extent

@testset "Regions" begin
    @testset "region returns Extent" begin
        @test region("CONUS") isa Extent
        @test region("California") isa Extent
        @test region("Japan") isa Extent
    end

    @testset "region errors on unknown" begin
        @test_throws ErrorException region("Narnia")
    end

    @testset "regions returns sorted list" begin
        r = regions()
        @test r isa Vector{String}
        @test issorted(r)
        @test "CONUS" in r
        @test "Alaska" in r
        @test "Texas" in r
        @test "Europe" in r
    end

    @testset "all 50 US states present" begin
        r = regions()
        for state in ["Alabama", "Alaska", "Arizona", "Arkansas", "California",
                       "Colorado", "Connecticut", "Delaware", "Florida", "Georgia",
                       "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa",
                       "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland",
                       "Massachusetts", "Michigan", "Minnesota", "Mississippi", "Missouri",
                       "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey",
                       "New Mexico", "New York", "North Carolina", "North Dakota", "Ohio",
                       "Oklahoma", "Oregon", "Pennsylvania", "Rhode Island", "South Carolina",
                       "South Dakota", "Tennessee", "Texas", "Utah", "Vermont",
                       "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming"]
            @test state in r
        end
    end

    @testset "all extents are valid" begin
        for (name, ext) in GeoFetch.REGIONS
            @test ext.X[1] < ext.X[2]
            @test ext.Y[1] < ext.Y[2]
            @test ext.X[1] >= -180.0
            @test ext.X[2] <= 180.0
            @test ext.Y[1] >= -90.0
            @test ext.Y[2] <= 90.0
        end
    end

    @testset "works with Project" begin
        p = Project(geometry=region("CONUS"))
        @test p.extent == region("CONUS")
    end
end
