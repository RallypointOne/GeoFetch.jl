#--------------------------------------------------------------------------------# NASAPower
const _NASAPOWER_POINT_URL = "https://power.larc.nasa.gov/api/temporal/daily/point"
const _NASAPOWER_REGIONAL_URL = "https://power.larc.nasa.gov/api/temporal/daily/regional"

# AG = Agroclimatology, RE = Renewable Energy, SB = Sustainable Buildings
const _NASAPOWER_COMMUNITIES = ("AG", "RE", "SB")

const _NASAPOWER_VARIABLES = [
    "T2M", "T2M_MAX", "T2M_MIN", "T2M_RANGE", "T2MDEW", "RH2M",
    "PRECTOTCORR", "WS2M", "WS10M", "WD2M", "WD10M", "PS",
    "QV2M", "CLOUD_AMT", "ALLSKY_SFC_SW_DWN", "CLRSKY_SFC_SW_DWN", "ALLSKY_SFC_LW_DWN",
]

"""NASA POWER daily data by variables, community (AG/RE/SB), and query type (point/regional)."""
@kwdef struct NASAPowerDataset <: Dataset
    variables::Vector{String} = ["T2M", "PRECTOTCORR"]
    community::String = "AG"
    query_type::String = "point"
end

help(::NASAPower) = "https://power.larc.nasa.gov"
help(::NASAPowerDataset) = "https://power.larc.nasa.gov/docs/services/api/"

#--------------------------------------------------------------------------------# NASAPowerChunk
struct NASAPowerChunk <: Chunk
    url::String
    variables::Vector{String}
    query_type::String
end

prefix(c::NASAPowerChunk)::Symbol = Symbol("nasapower_", c.query_type)
extension(::NASAPowerChunk)::String = "json"
fetch(c::NASAPowerChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::NASAPowerChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# URL
function _nasapower_build_url(d::NASAPowerDataset, ext, t_start::Date, t_stop::Date)::String
    start_str = Dates.format(t_start, dateformat"yyyymmdd")
    stop_str = Dates.format(t_stop, dateformat"yyyymmdd")
    params_str = join(d.variables, ",")
    if d.query_type == "point"
        lon = (ext.X[1] + ext.X[2]) / 2
        lat = (ext.Y[1] + ext.Y[2]) / 2
        "$(_NASAPOWER_POINT_URL)?parameters=$params_str&community=$(d.community)&longitude=$lon&latitude=$lat&start=$start_str&end=$stop_str&format=JSON"
    else
        "$(_NASAPOWER_REGIONAL_URL)?parameters=$params_str&community=$(d.community)&longitude-min=$(ext.X[1])&longitude-max=$(ext.X[2])&latitude-min=$(ext.Y[1])&latitude-max=$(ext.Y[2])&start=$start_str&end=$stop_str&format=JSON"
    end
end

#--------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::NASAPowerDataset)::Vector{NASAPowerChunk}
    isnothing(p.datetimes) && error("NASA POWER requires datetimes on the Project")
    d.community in _NASAPOWER_COMMUNITIES || error("Invalid NASA POWER community: \"$(d.community)\". Must be one of: $(join(_NASAPOWER_COMMUNITIES, ", "))")
    d.query_type in ("point", "regional") || error("Invalid NASA POWER query_type: \"$(d.query_type)\". Must be \"point\" or \"regional\"")
    if d.query_type == "regional"
        dx = p.extent.X[2] - p.extent.X[1]
        dy = p.extent.Y[2] - p.extent.Y[1]
        dx < 2 && error("NASA POWER regional endpoint requires at least 2° longitude range (got $(dx)°). Use query_type=\"point\" instead.")
        dy < 2 && error("NASA POWER regional endpoint requires at least 2° latitude range (got $(dy)°). Use query_type=\"point\" instead.")
    end
    t_start = Date(first(p.datetimes))
    t_stop = Date(last(p.datetimes))
    url = _nasapower_build_url(d, p.extent, t_start, t_stop)
    [NASAPowerChunk(url, d.variables, d.query_type)]
end

#--------------------------------------------------------------------------------# DATASETS
const _NASAPOWER_DATASETS = [
    NASAPowerDataset(variables=["T2M", "PRECTOTCORR"]),
    NASAPowerDataset(variables=["T2M", "T2M_MAX", "T2M_MIN", "RH2M", "WS2M", "PS"]),
    NASAPowerDataset(variables=["ALLSKY_SFC_SW_DWN", "CLRSKY_SFC_SW_DWN", "ALLSKY_SFC_LW_DWN"]),
]

const NASAPOWER_WEATHER = _NASAPOWER_DATASETS[1]
const NASAPOWER_SURFACE = _NASAPOWER_DATASETS[2]
const NASAPOWER_SOLAR = _NASAPOWER_DATASETS[3]

#--------------------------------------------------------------------------------# datasets
function datasets(::NASAPower; community=nothing)
    filter(d -> community === nothing || d.community == community, _NASAPOWER_DATASETS)
end
