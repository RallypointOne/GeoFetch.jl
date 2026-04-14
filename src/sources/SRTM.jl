#--------------------------------------------------------------------------------# SRTM
# SRTMGL1 = 1 arc-second (~30m), SRTMGL3 = 3 arc-second (~90m)
const _SRTM_PRODUCTS = ("SRTMGL1", "SRTMGL3")

"""SRTM elevation tiles (SRTMGL1 at 1\" or SRTMGL3 at 3\"). Requires Earthdata login."""
@kwdef struct SRTMDataset <: Dataset
    product::String = "SRTMGL1"
    version::String = "003"
end

help(::SRTM) = "https://www.earthdata.nasa.gov/sensors/srtm"
help(::SRTMDataset) = "https://www.earthdata.nasa.gov/sensors/srtm"

function metadata(d::SRTMDataset)
    res = d.product == "SRTMGL1" ? 1/3600 : 1/1200
    Dict{Symbol,Any}(:data_type => "gridded", :resolution => res, :bytes_per_value => 2, :license => "NASA/USGS public domain", :requires_auth => true)
end

#--------------------------------------------------------------------------------# SRTMChunk
struct SRTMChunk <: Chunk
    url::String
    tile_name::String
    product::String
end

prefix(c::SRTMChunk)::Symbol = Symbol("srtm_", c.tile_name)
extension(::SRTMChunk)::String = "hgt.zip"
function fetch(c::SRTMChunk, file::String)
    token = _srtm_earthdata_token()
    Downloads.download(c.url, file; headers=["Authorization" => "Bearer $token"])
end
Base.filesize(c::SRTMChunk) = _head_content_length(c.url; headers=["Authorization" => "Bearer $(_srtm_earthdata_token())"])

#--------------------------------------------------------------------------------# Auth
function _srtm_earthdata_token()::String
    token = get(ENV, "EARTHDATA_TOKEN", "")
    !isempty(token) && return token
    error("NASA EarthData token not found. Set EARTHDATA_TOKEN environment variable. " *
        "Generate a token at https://urs.earthdata.nasa.gov/users/tokens")
end

#--------------------------------------------------------------------------------# Tile math
function _srtm_tile_name(lat::Int, lon::Int)::String
    ns = lat >= 0 ? "N" : "S"
    ew = lon >= 0 ? "E" : "W"
    string(ns, lpad(abs(lat), 2, '0'), ew, lpad(abs(lon), 3, '0'))
end

function _srtm_tiles_for_extent(extent)::Vector{String}
    lat_min = floor(Int, extent.Y[1])
    lat_max = ceil(Int, extent.Y[2]) - 1
    lon_min = floor(Int, extent.X[1])
    lon_max = ceil(Int, extent.X[2]) - 1
    lat_min = max(lat_min, -60)
    lat_max = min(lat_max, 59)
    tiles = String[]
    for lat in lat_min:lat_max, lon in lon_min:lon_max
        push!(tiles, _srtm_tile_name(lat, lon))
    end
    tiles
end

function _srtm_build_url(d::SRTMDataset, tile::String)::String
    "https://e4ftl01.cr.usgs.gov/MEASURES/$(d.product).$(d.version)/2000.02.11/$(tile).$(d.product).hgt.zip"
end

#--------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::SRTMDataset)::Vector{SRTMChunk}
    d.product in _SRTM_PRODUCTS || error("Invalid SRTM product: \"$(d.product)\". Must be one of: $(join(_SRTM_PRODUCTS, ", "))")
    p.extent == EARTH && error("SRTM requires a bounded extent (not global). Set geometry or extent on the Project.")
    tiles = _srtm_tiles_for_extent(p.extent)
    isempty(tiles) && error("No SRTM tiles found for the given extent. SRTM covers latitudes 60°S to 60°N.")
    [SRTMChunk(_srtm_build_url(d, t), t, d.product) for t in tiles]
end

#--------------------------------------------------------------------------------# DATASETS
const _SRTM_DATASETS = [
    SRTMDataset(product="SRTMGL1", version="003"),
    SRTMDataset(product="SRTMGL3", version="003"),
]

const SRTM_30m = _SRTM_DATASETS[1]
const SRTM_90m = _SRTM_DATASETS[2]

#--------------------------------------------------------------------------------# datasets
function datasets(::SRTM; product=nothing)
    filter(d -> (product === nothing || d.product == product), _SRTM_DATASETS)
end
