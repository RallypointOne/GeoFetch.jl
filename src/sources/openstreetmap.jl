#--------------------------------------------------------------------------------# OpenStreetMap

"""
    OpenStreetMap()

Vector feature data from [OpenStreetMap](https://www.openstreetmap.org/) via the
[Overpass API](https://overpass-api.de/).  Query buildings, roads, amenities, and other
map features by bounding box.

- **Coverage**: Global, continuously updated
- **Resolution**: Varies (individual features)
- **API Key**: Not required
- **Rate Limit**: Informal (be respectful, avoid heavy queries)
- **Response Format**: JSON (Overpass JSON)

Each variable corresponds to an OSM tag key (e.g., `:building`, `:highway`).  One API
request is made per variable for caching efficiency.  Keep bounding boxes small to avoid
timeouts and large responses.

### Examples

```julia
using GeoInterface.Extents: Extent

# Buildings in a small area
plan = DataAccessPlan(OpenStreetMap(),
    Extent(X=(-74.01, -73.99), Y=(40.70, 40.72));
    variables = [:building])
files = fetch(plan)

# Roads and amenities near a point
plan = DataAccessPlan(OpenStreetMap(), (-74.0, 40.7);
    variables = [:highway, :amenity],
    timeout = 60)
files = fetch(plan)
```
"""
struct OpenStreetMap <: AbstractDataSource end

_register_source!(OpenStreetMap())

const OVERPASS_API_URL = "https://overpass-api.de/api/interpreter"

const OSM_VARIABLES = Dict{Symbol, String}(
    :building  => "Buildings (residential, commercial, etc.)",
    :highway   => "Roads, paths, and streets",
    :natural   => "Natural features (water, wood, etc.)",
    :amenity   => "Amenities (restaurants, schools, hospitals, etc.)",
    :shop      => "Shops and retail",
    :leisure   => "Leisure areas (parks, playgrounds, etc.)",
    :landuse   => "Land use zones (residential, industrial, etc.)",
    :waterway  => "Waterways (rivers, streams, canals)",
    :railway   => "Railway infrastructure",
    :boundary  => "Administrative boundaries",
    :tourism   => "Tourism features (hotels, attractions, etc.)",
    :power     => "Power infrastructure (lines, substations, etc.)",
)

#--------------------------------------------------------------------------------# MetaData

MetaData(::OpenStreetMap) = MetaData(
    "", "Informal (be respectful)",
    Infrastructure, OSM_VARIABLES,
    VectorFeature, "Varies (individual features)", "Global",
    :snapshot, nothing, "Continuously updated",
    ODbL_1_0,
    "https://wiki.openstreetmap.org/wiki/Overpass_API";
    load_packages = Dict("DataFrames" => "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"),
)

#--------------------------------------------------------------------------------# DataAccessPlan

function DataAccessPlan(source::OpenStreetMap, extent;
                        variables::Vector{Symbol} = [:building],
                        timeout::Int = 90)
    south, west, north, east = _osm_bbox(extent)

    requests = RequestInfo[]
    for var in variables
        query = _overpass_query(var, south, west, north, east; timeout)
        url = _build_url(OVERPASS_API_URL, Dict("data" => query))
        push!(requests, RequestInfo(source, url, :GET, "OSM $var"))
    end

    extent_desc = _describe_extent(extent)
    area_deg2 = max((north - south) * (east - west), 0.001)
    est_bytes = round(Int, area_deg2 * 500_000 * length(variables))

    DataAccessPlan(source, requests, extent_desc,
        nothing, variables, Dict{Symbol, Any}(:timeout => timeout),
        est_bytes)
end

#--------------------------------------------------------------------------------# Helpers

function _overpass_query(tag::Symbol, south, west, north, east; timeout=90)
    "[out:json][timeout:$timeout];(nwr[\"$tag\"]($south,$west,$north,$east););out center body qt;"
end

function _osm_bbox(extent)
    trait = GI.geomtrait(extent)
    _osm_bbox(trait, extent)
end

function _osm_bbox(::GI.PointTrait, geom)
    lon, lat = GI.x(geom), GI.y(geom)
    (lat - 0.005, lon - 0.005, lat + 0.005, lon + 0.005)  # S, W, N, E
end

function _osm_bbox(::GI.AbstractPolygonTrait, geom)
    _osm_bbox(nothing, GI.extent(geom))
end

function _osm_bbox(::Nothing, geom)
    if hasproperty(geom, :X) && hasproperty(geom, :Y)
        xmin, xmax = geom.X
        ymin, ymax = geom.Y
        return (ymin, xmin, ymax, xmax)  # S, W, N, E
    end
    error("Cannot extract bounding box from $(typeof(geom)) for OpenStreetMap.")
end

function _osm_bbox(::Union{GI.MultiPointTrait, GI.AbstractCurveTrait}, geom)
    points = collect(GI.getpoint(geom))
    lons = [GI.x(p) for p in points]
    lats = [GI.y(p) for p in points]
    (minimum(lats), minimum(lons), maximum(lats), maximum(lons))  # S, W, N, E
end
