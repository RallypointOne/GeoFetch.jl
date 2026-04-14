#-----------------------------------------------------------------------------# Nominatim
const _NOMINATIM_BASE_URL = "https://nominatim.openstreetmap.org"
const _NOMINATIM_ENDPOINTS = ("search", "reverse", "lookup")
const _NOMINATIM_FORMATS = ("json", "jsonv2", "geojson", "geocodejson")
const _NOMINATIM_LAYERS = ("address", "poi", "railway", "natural", "manmade")

@kwdef struct NominatimDataset <: Dataset
    endpoint::String = "search"
    q::String = ""
    osm_ids::Vector{String} = String[]
    format::String = "jsonv2"
    addressdetails::Bool = true
    extratags::Bool = false
    namedetails::Bool = false
    limit::Int = 10
    zoom::Int = 18
    polygon_geojson::Bool = false
    countrycodes::Vector{String} = String[]
    layer::Vector{String} = String[]
    accept_language::String = ""
    email::String = ""
    base_url::String = _NOMINATIM_BASE_URL
end

help(::Nominatim) = "https://nominatim.org/release-docs/develop/api/Overview/"
help(::NominatimDataset) = "https://nominatim.org/release-docs/develop/api/Overview/"

function metadata(::NominatimDataset)
    Dict{Symbol,Any}(:data_type => "geocoding", :license => "OpenStreetMap/ODbL")
end

#-----------------------------------------------------------------------------# NominatimChunk
struct NominatimChunk <: Chunk
    url::String
    endpoint::String
    format::String
end

prefix(c::NominatimChunk)::Symbol = Symbol("nominatim_", c.endpoint)

extension(c::NominatimChunk)::String = c.format in ("geojson", "geocodejson") ? "geojson" : "json"

function fetch(c::NominatimChunk, file::String)
    Downloads.download(c.url, file; headers=["User-Agent" => "GeoFetch.jl"])
end

Base.filesize(c::NominatimChunk) = nothing

#-----------------------------------------------------------------------------# URL building
function _nominatim_urlencode(s::AbstractString)
    io = IOBuffer()
    for c in s
        if (isletter(c) && isascii(c)) || isdigit(c) || c in "-_.~"
            print(io, c)
        elseif c == ' '
            print(io, '+')
        else
            for b in codeunits(string(c))
                print(io, '%', uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(io))
end

function _nominatim_params(d::NominatimDataset)
    params = ["format=$(d.format)"]
    d.addressdetails && push!(params, "addressdetails=1")
    d.extratags && push!(params, "extratags=1")
    d.namedetails && push!(params, "namedetails=1")
    d.polygon_geojson && push!(params, "polygon_geojson=1")
    isempty(d.countrycodes) || push!(params, "countrycodes=" * join(d.countrycodes, ","))
    isempty(d.layer) || push!(params, "layer=" * join(d.layer, ","))
    isempty(d.accept_language) || push!(params, "accept-language=$(d.accept_language)")
    isempty(d.email) || push!(params, "email=$(d.email)")
    params
end

function _nominatim_search_url(d::NominatimDataset, extent)
    params = _nominatim_params(d)
    push!(params, "q=$(_nominatim_urlencode(d.q))")
    push!(params, "limit=$(d.limit)")
    if extent != EARTH
        push!(params, "viewbox=$(extent.X[1]),$(extent.Y[1]),$(extent.X[2]),$(extent.Y[2])")
    end
    "$(d.base_url)/search?" * join(params, "&")
end

function _nominatim_reverse_url(d::NominatimDataset, extent)
    params = _nominatim_params(d)
    lat = (extent.Y[1] + extent.Y[2]) / 2
    lon = (extent.X[1] + extent.X[2]) / 2
    push!(params, "lat=$lat")
    push!(params, "lon=$lon")
    push!(params, "zoom=$(d.zoom)")
    "$(d.base_url)/reverse?" * join(params, "&")
end

function _nominatim_lookup_url(d::NominatimDataset)
    params = _nominatim_params(d)
    push!(params, "osm_ids=" * join(d.osm_ids, ","))
    "$(d.base_url)/lookup?" * join(params, "&")
end

#-----------------------------------------------------------------------------# chunks
function chunks(p::Project, d::NominatimDataset)::Vector{NominatimChunk}
    d.endpoint in _NOMINATIM_ENDPOINTS || error("Invalid Nominatim endpoint: \"$(d.endpoint)\". Must be one of: $(join(_NOMINATIM_ENDPOINTS, ", "))")
    d.format in _NOMINATIM_FORMATS || error("Invalid Nominatim format: \"$(d.format)\". Must be one of: $(join(_NOMINATIM_FORMATS, ", "))")
    if d.endpoint == "search"
        isempty(d.q) && error("Nominatim search requires a non-empty `q` (query string)")
        url = _nominatim_search_url(d, p.extent)
    elseif d.endpoint == "reverse"
        p.extent == EARTH && error("Nominatim reverse requires a bounded extent on the Project")
        url = _nominatim_reverse_url(d, p.extent)
    else
        isempty(d.osm_ids) && error("Nominatim lookup requires non-empty `osm_ids`")
        url = _nominatim_lookup_url(d)
    end
    [NominatimChunk(url, d.endpoint, d.format)]
end

#-----------------------------------------------------------------------------# datasets
function datasets(::Nominatim; endpoint=nothing)
    ds = [
        NominatimDataset(endpoint="search"),
        NominatimDataset(endpoint="reverse"),
        NominatimDataset(endpoint="lookup"),
    ]
    endpoint === nothing ? ds : filter(d -> d.endpoint == endpoint, ds)
end
