#--------------------------------------------------------------------------------# NCEI
const _NCEI_BASE_URL = "https://www.ncei.noaa.gov/access/services/data/v1"

const _NCEI_DATASET_INFO = Dict(
    "daily-summaries"              => "Daily station observations (GHCND stations)",
    "global-summary-of-the-month"  => "Monthly aggregations (GHCND stations)",
    "global-summary-of-the-year"   => "Annual aggregations (GHCND stations)",
    "global-summary-of-the-day"    => "Daily summaries from ISD stations",
    "global-hourly"                => "Hourly observations from ISD stations",
    "local-climatological-data"    => "LCD reports from ISD stations",
    "normals-daily"                => "30-year daily climate normals (GHCND stations)",
    "normals-monthly"              => "30-year monthly climate normals (GHCND stations)",
    "global-marine"                => "Ship and buoy marine observations (supports bbox)",
)

"""NCEI Data Access Service by dataset, data types, and stations or bbox. No API key required."""
@kwdef struct NCEIDataset <: Dataset
    dataset::String = "daily-summaries"
    datatypes::Vector{String} = ["TMAX", "TMIN", "PRCP"]
    stations::Vector{String} = String[]
    format::String = "json"
    units::String = "metric"
end

help(::NCEI) = "https://www.ncei.noaa.gov"
help(::NCEIDataset) = "https://www.ncei.noaa.gov/support/access-data-service-api-user-documentation"

function metadata(::NCEIDataset)
    Dict{Symbol,Any}(:data_type => "station", :license => "NOAA/NCEI public domain")
end

#--------------------------------------------------------------------------------# NCEIChunk
struct NCEIChunk <: Chunk
    url::String
    dataset::String
    start_date::Date
    end_date::Date
end

prefix(c::NCEIChunk)::Symbol = Symbol("ncei_", replace(c.dataset, "-" => "_"))
extension(c::NCEIChunk)::String = occursin("format=csv", c.url) ? "csv" : "json"
fetch(c::NCEIChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::NCEIChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# URL
function _ncei_build_url(d::NCEIDataset, extent, t_start::Date, t_stop::Date)::String
    params = [
        "dataset=$(d.dataset)",
        "startDate=$(Dates.format(t_start, dateformat"yyyy-mm-dd"))",
        "endDate=$(Dates.format(t_stop, dateformat"yyyy-mm-dd"))",
        "format=$(d.format)",
        "units=$(d.units)",
    ]
    if !isempty(d.datatypes)
        push!(params, "dataTypes=" * join(d.datatypes, ","))
    end
    if !isempty(d.stations)
        push!(params, "stations=" * join(d.stations, ","))
    elseif !isnothing(extent)
        push!(params, "boundingBox=$(extent.Y[2]),$(extent.X[1]),$(extent.Y[1]),$(extent.X[2])")
    end
    "$(_NCEI_BASE_URL)?" * join(params, "&")
end

#--------------------------------------------------------------------------------# chunks
const _NCEI_MAX_DAYS = 365

function chunks(p::Project, d::NCEIDataset)::Vector{NCEIChunk}
    isnothing(p.datetimes) && error("NCEI requires datetimes on the Project")
    haskey(_NCEI_DATASET_INFO, d.dataset) || error("Unknown NCEI dataset: \"$(d.dataset)\". Must be one of: $(join(sort(collect(keys(_NCEI_DATASET_INFO))), ", "))")
    isempty(d.stations) && p.extent == EARTH && error("NCEI requires stations on the dataset or a bounded extent on the Project")
    t_start = Date(first(p.datetimes))
    t_stop = Date(last(p.datetimes))
    result = NCEIChunk[]
    current = t_start
    while current <= t_stop
        chunk_stop = min(current + Day(_NCEI_MAX_DAYS - 1), t_stop)
        url = _ncei_build_url(d, p.extent, current, chunk_stop)
        push!(result, NCEIChunk(url, d.dataset, current, chunk_stop))
        current = chunk_stop + Day(1)
    end
    result
end

#--------------------------------------------------------------------------------# DATASETS
const _NCEI_DATASETS = [
    NCEIDataset(dataset="daily-summaries", datatypes=["TMAX", "TMIN", "PRCP"]),
    NCEIDataset(dataset="global-summary-of-the-month", datatypes=["TMAX", "TMIN", "PRCP"]),
    NCEIDataset(dataset="global-summary-of-the-year", datatypes=["TMAX", "TMIN", "PRCP"]),
    NCEIDataset(dataset="global-hourly", datatypes=String[]),
    NCEIDataset(dataset="normals-daily", datatypes=String[]),
    NCEIDataset(dataset="global-marine", datatypes=String[]),
]

const NCEI_DAILY = _NCEI_DATASETS[1]
const NCEI_MONTHLY = _NCEI_DATASETS[2]
const NCEI_YEARLY = _NCEI_DATASETS[3]
const NCEI_HOURLY = _NCEI_DATASETS[4]
const NCEI_NORMALS = _NCEI_DATASETS[5]
const NCEI_MARINE = _NCEI_DATASETS[6]

#--------------------------------------------------------------------------------# datasets
function datasets(::NCEI; dataset=nothing)
    filter(d -> dataset === nothing || d.dataset == dataset, _NCEI_DATASETS)
end
