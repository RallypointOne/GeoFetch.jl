#--------------------------------------------------------------------------------# Copernicus DEM

"""
    CopernicusDEM(; resolution=30)

Copernicus DEM elevation data from [AWS Open Data](https://registry.opendata.aws/copernicus-dem/).
Downloads Cloud Optimized GeoTIFF (COG) tiles.  Each tile covers a 1°×1° area.

Two resolutions are available:
- `30` — GLO-30 (~30 m, 10 arc-second tiles)
- `90` — GLO-90 (~90 m, 30 arc-second tiles)

- **Coverage**: Global
- **Format**: Cloud Optimized GeoTIFF (COG)
- **API Key**: None required
- **Rate Limit**: None (AWS S3)
- **Temporal**: Static (snapshot)

Tiles are identified by their southwest corner coordinates.  For a given spatial extent,
all overlapping 1°×1° tiles are downloaded.

### Examples

```julia
using GeoInterface.Extents: Extent

# 30 m resolution (default)
plan = DataAccessPlan(CopernicusDEM(), (-105.0, 40.0))
files = fetch(plan)

# 90 m resolution
plan = DataAccessPlan(CopernicusDEM(resolution=90),
    Extent(X=(-106.0, -104.0), Y=(39.0, 41.0)))
files = fetch(plan)
```
"""
struct CopernicusDEM <: AbstractDataSource
    resolution::Int
    function CopernicusDEM(; resolution::Int=30)
        resolution in (30, 90) || error("resolution must be 30 or 90 (got $resolution)")
        new(resolution)
    end
end

_register_source!(CopernicusDEM())

const COPERNICUS_DEM_VARIABLES = Dict{Symbol, String}(
    :elevation => "Elevation above sea level (m)",
)

#--------------------------------------------------------------------------------# MetaData

function MetaData(source::CopernicusDEM)
    MetaData(
        "", "None (AWS S3)",
        :terrain, COPERNICUS_DEM_VARIABLES,
        :raster, "$(source.resolution) m", "Global",
        :snapshot, nothing, "Static",
        "Copernicus License",
        "https://copernicus-dem-$(source.resolution)m.s3.amazonaws.com/readme.html";
        load_packages = Dict("Rasters" => "a3a2b9e3-a471-40c9-b274-f788e487c689"),
    )
end

#--------------------------------------------------------------------------------# DataAccessPlan

function DataAccessPlan(source::CopernicusDEM, extent;
                        variables::Vector{Symbol} = [:elevation])
    lons, lats = _copernicus_tile_range(extent)
    requests = RequestInfo[]
    for lat in lats, lon in lons
        url = _copernicus_tile_url(source.resolution, lat, lon)
        desc = "DEM tile $(lat >= 0 ? "N" : "S")$(lpad(abs(lat), 2, '0'))_$(lon >= 0 ? "E" : "W")$(lpad(abs(lon), 3, '0'))"
        push!(requests, RequestInfo(source, url, :GET, desc; ext=".tif"))
    end
    extent_desc = _describe_extent(extent)
    est_bytes = source.resolution == 30 ? 25_000_000 : 3_000_000
    DataAccessPlan(source, requests, extent_desc,
        nothing, variables, Dict{Symbol, Any}(:resolution => source.resolution),
        length(requests) * est_bytes)
end

#--------------------------------------------------------------------------------# Helpers

function _copernicus_tile_url(resolution::Int, lat::Int, lon::Int)
    ns = lat >= 0 ? "N" : "S"
    ew = lon >= 0 ? "E" : "W"
    lat_str = "$(ns)$(lpad(abs(lat), 2, '0'))_00"
    lon_str = "$(ew)$(lpad(abs(lon), 3, '0'))_00"
    arcsec = resolution == 30 ? "10" : "30"
    bucket = "copernicus-dem-$(resolution)m"
    tile = "Copernicus_DSM_COG_$(arcsec)_$(lat_str)_$(lon_str)_DEM"
    return "https://$(bucket).s3.eu-central-1.amazonaws.com/$tile/$tile.tif"
end

function _copernicus_tile_range(extent)
    trait = GI.geomtrait(extent)
    _copernicus_tile_range(trait, extent)
end

function _copernicus_tile_range(::GI.PointTrait, geom)
    lon = floor(Int, GI.x(geom))
    lat = floor(Int, GI.y(geom))
    [lon], [lat]
end

function _copernicus_tile_range(::GI.AbstractPolygonTrait, geom)
    _copernicus_tile_range(nothing, GI.extent(geom))
end

function _copernicus_tile_range(::Nothing, geom)
    if hasproperty(geom, :X) && hasproperty(geom, :Y)
        xmin, xmax = geom.X
        ymin, ymax = geom.Y
        lons = floor(Int, xmin):floor(Int, xmax)
        lats = floor(Int, ymin):floor(Int, ymax)
        return collect(lons), collect(lats)
    end
    error("Cannot extract bounding box from $(typeof(geom)) for Copernicus DEM.")
end

function _copernicus_tile_range(::Union{GI.MultiPointTrait, GI.AbstractCurveTrait}, geom)
    points = collect(GI.getpoint(geom))
    lon_vals = [GI.x(p) for p in points]
    lat_vals = [GI.y(p) for p in points]
    lons = floor(Int, minimum(lon_vals)):floor(Int, maximum(lon_vals))
    lats = floor(Int, minimum(lat_vals)):floor(Int, maximum(lat_vals))
    collect(lons), collect(lats)
end
