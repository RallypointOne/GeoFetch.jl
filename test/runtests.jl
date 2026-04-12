using GeoFetch
using Test

include("test_regions.jl")
include("test_nomads.jl")
include("test_cds.jl")
include("test_firms.jl")
include("test_etopo.jl")
include("test_srtm.jl")
include("test_goes.jl")
include("test_hrrr_archive.jl")
include("test_nasapower.jl")
include("test_usgswater.jl")
include("test_ncei.jl")
include("test_oisst.jl")

if Base.find_package("Landfire") !== nothing
    include("test_landfire.jl")
end
