#--------------------------------------------------------------------------------# ETOPO
# Arc-second grid spacing: 60s ≈ 1.85km, 30s ≈ 0.93km, 15s ≈ 0.46km
const _ETOPO_RESOLUTIONS = ("60s", "30s", "15s")
# "surface" = ice surface elevation, "bedrock" = sub-ice bedrock elevation
const _ETOPO_SURFACES = ("surface", "bedrock")

"""ETOPO 2022 global relief at 60\", 30\", or 15\" resolution (surface or bedrock)."""
@kwdef struct ETOPODataset <: Dataset
    resolution::String = "60s"
    surface_type::String = "surface"
    format::String = "netcdf"
end

help(::ETOPO) = "https://www.ncei.noaa.gov/products/etopo-global-relief-model"
help(::ETOPODataset) = "https://www.ncei.noaa.gov/products/etopo-global-relief-model"

const _ETOPO_RESOLUTION_DEG = Dict("60s" => 1/60, "30s" => 1/120, "15s" => 1/240)

function metadata(d::ETOPODataset)
    Dict{Symbol,Any}(:data_type => "gridded", :resolution => _ETOPO_RESOLUTION_DEG[d.resolution], :license => "NOAA/NCEI public domain")
end

#--------------------------------------------------------------------------------# ETOPOChunk
struct ETOPOChunk <: Chunk
    url::String
    resolution::String
    surface_type::String
    format::String
end

prefix(c::ETOPOChunk)::Symbol = Symbol("etopo_", c.resolution, "_", c.surface_type)
extension(c::ETOPOChunk)::String = c.format == "geotiff" ? "tif" : "nc"
fetch(c::ETOPOChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::ETOPOChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# URL
function _etopo_build_url(d::ETOPODataset)::String
    ext = d.format == "geotiff" ? "tif" : "nc"
    "https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/$(d.resolution)/$(d.resolution)_$(d.surface_type)/ETOPO_2022_v1_$(d.resolution)_$(d.surface_type).$(ext)"
end

#--------------------------------------------------------------------------------# chunks
function chunks(::Project, d::ETOPODataset)::Vector{ETOPOChunk}
    d.resolution in _ETOPO_RESOLUTIONS || error("Invalid ETOPO resolution: \"$(d.resolution)\". Must be one of: $(join(_ETOPO_RESOLUTIONS, ", "))")
    d.surface_type in _ETOPO_SURFACES || error("Invalid ETOPO surface_type: \"$(d.surface_type)\". Must be one of: $(join(_ETOPO_SURFACES, ", "))")
    [ETOPOChunk(_etopo_build_url(d), d.resolution, d.surface_type, d.format)]
end

#--------------------------------------------------------------------------------# DATASETS
const _ETOPO_DATASETS = [
    ETOPODataset(resolution="60s", surface_type="surface"),
    ETOPODataset(resolution="60s", surface_type="bedrock"),
    ETOPODataset(resolution="30s", surface_type="surface"),
    ETOPODataset(resolution="30s", surface_type="bedrock"),
    ETOPODataset(resolution="15s", surface_type="surface"),
    ETOPODataset(resolution="15s", surface_type="bedrock"),
]

const ETOPO_60s = _ETOPO_DATASETS[1]
const ETOPO_30s = _ETOPO_DATASETS[3]
const ETOPO_15s = _ETOPO_DATASETS[5]

#--------------------------------------------------------------------------------# datasets
function datasets(::ETOPO; resolution=nothing, surface_type=nothing)
    filter(d -> (resolution === nothing || d.resolution == resolution) &&
           (surface_type === nothing || d.surface_type == surface_type), _ETOPO_DATASETS)
end
