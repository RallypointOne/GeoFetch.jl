#------------------------------------------------------------------------------# Landfire
const _LANDFIRE_WCS_BASE = "https://edcintl.cr.usgs.gov/geoserver/landfire_wcs"

const _LANDFIRE_PRODUCTS = (
    "CBD", "CBH", "CC", "CH", "EVC", "EVH", "EVT",
    "FBFM13", "FBFM40", "FDist", "FVC", "FVH", "FVT",
    "SClass", "VCC", "VDep",
)

const _LANDFIRE_REGIONS = ("CONUS", "AK", "HI")

const _LANDFIRE_LATEST_CACHE = Dict{String, Int}()

function _landfire_latest_year(region::String)::Int
    get!(_LANDFIRE_LATEST_CACHE, region) do
        for y in year(today()):-1:2010
            url = "$(_LANDFIRE_WCS_BASE)/$(lowercase(region))_$(y)/wcs?service=WCS&version=2.0.1&request=GetCapabilities"
            try
                Downloads.download(url, devnull)
                return y
            catch
            end
        end
        error("Could not determine latest LANDFIRE year for region \"$region\"")
    end
end

_landfire_year(year::Int, ::String) = year
_landfire_year(::Latest, region::String) = _landfire_latest_year(region)

#------------------------------------------------------------------------------# LandfireDataset
"""LANDFIRE raster product accessed via WCS (30m resolution, GeoTIFF output)."""
@kwdef struct LandfireDataset <: Dataset
    product::String = "FBFM40"
    region::String = "CONUS"
    year::Union{Int, Latest} = Latest()
end

help(::Landfire) = "https://landfire.gov"
help(::LandfireDataset) = "https://landfire.gov/data/lf_wcs_wms"

#------------------------------------------------------------------------------# LandfireChunk
struct LandfireChunk <: Chunk
    dataset::LandfireDataset
    url::String
end

prefix(c::LandfireChunk)::Symbol = Symbol("landfire_", c.dataset.product)
extension(::LandfireChunk)::String = "tif"

fetch(c::LandfireChunk, file::String) = Downloads.download(c.url, file)

#------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::LandfireDataset)::Vector{LandfireChunk}
    d.product in _LANDFIRE_PRODUCTS || error("Invalid LANDFIRE product: \"$(d.product)\". Must be one of: $(join(_LANDFIRE_PRODUCTS, ", "))")
    d.region in _LANDFIRE_REGIONS || error("Invalid LANDFIRE region: \"$(d.region)\". Must be one of: $(join(_LANDFIRE_REGIONS, ", "))")
    p.extent == EARTH && error("LANDFIRE requires a bounded extent. Set geometry or extent on the Project.")
    yr = _landfire_year(d.year, d.region)
    ws = "$(lowercase(d.region))_$(yr)"
    cov = "landfire_wcs__LF$(yr)_$(d.product)_$(d.region)"
    base = "$(_LANDFIRE_WCS_BASE)/$(ws)/wcs"
    url = base * "?" * join([
        "service=WCS",
        "version=2.0.1",
        "request=GetCoverage",
        "CoverageId=$(cov)",
        "format=image/tiff",
        "subset=Long($(p.extent.X[1]),$(p.extent.X[2]))",
        "subset=Lat($(p.extent.Y[1]),$(p.extent.Y[2]))",
        "subsettingCrs=http://www.opengis.net/def/crs/EPSG/0/4326",
    ], "&")
    [LandfireChunk(d, url)]
end

#------------------------------------------------------------------------------# DATASETS
const _LANDFIRE_DATASETS = [
    LandfireDataset(product=p, region=r)
    for p in _LANDFIRE_PRODUCTS for r in _LANDFIRE_REGIONS
]

const LANDFIRE_FBFM40 = LandfireDataset(product="FBFM40")
const LANDFIRE_FBFM13 = LandfireDataset(product="FBFM13")

#------------------------------------------------------------------------------# datasets
function datasets(::Landfire; product=nothing, region=nothing)
    filter(d -> (product === nothing || d.product == product) &&
           (region === nothing || d.region == region), _LANDFIRE_DATASETS)
end
