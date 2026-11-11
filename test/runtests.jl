using Test
using GeoFetch

# Placeholder — fill in once we have stable tests for the new pipeline API.
@testset "GeoFetch" begin
    @test isdefined(GeoFetch, :execute)

    include("gfs_fixture.jl")
    include("core.jl")
    include("grib.jl")
    include("gfs.jl")
end
