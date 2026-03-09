module RastersExt

using GeoDataAccess
using Rasters

import GeoDataAccess: DataAccessPlan, load, fetch, NOAAGFS, ERA5, CopernicusDEM

#--------------------------------------------------------------------------------# NOAA GFS

function GeoDataAccess.load(plan::DataAccessPlan{NOAAGFS})
    files = fetch(plan)
    if length(files) == 1
        Raster(files[1])
    else
        RasterStack(files)
    end
end

#--------------------------------------------------------------------------------# ERA5

function GeoDataAccess.load(plan::DataAccessPlan{ERA5})
    files = fetch(plan)
    if length(files) == 1
        Raster(files[1])
    else
        RasterStack(files)
    end
end

#--------------------------------------------------------------------------------# Copernicus DEM

function GeoDataAccess.load(plan::DataAccessPlan{CopernicusDEM})
    files = fetch(plan)
    if length(files) == 1
        Raster(files[1])
    else
        RasterStack(files)
    end
end

end # module
