#--------------------------------------------------------------------------------# USGSWater
const _USGS_BASE_URL = "https://api.waterdata.usgs.gov/ogcapi/v0"

# daily = one value per day, continuous = high-frequency (typically 15-minute intervals)
const _USGS_COLLECTIONS = ("daily", "continuous")

const _USGS_PARAMETER_CODES = Dict(
    "00060" => "Discharge (ft³/s)",
    "00065" => "Gage height (ft)",
    "00010" => "Water temperature (°C)",
    "00045" => "Precipitation (in)",
    "00400" => "pH",
    "00300" => "Dissolved oxygen (mg/L)",
    "00095" => "Specific conductance (µS/cm)",
    "72019" => "Groundwater level (ft below land surface)",
)

const _USGS_STATISTICS = Dict(
    "00001" => "Maximum",
    "00002" => "Minimum",
    "00003" => "Mean",
)

"""USGS water observations by parameter codes, collection (daily/continuous), and site IDs or bbox."""
@kwdef struct USGSWaterDataset <: Dataset
    parameter_codes::Vector{String} = ["00060"]
    collection::String = "daily"
    statistic_id::String = "00003"
    site_ids::Vector{String} = String[]
    format::String = "json"
end

help(::USGSWater) = "https://waterdata.usgs.gov"
help(::USGSWaterDataset) = "https://api.waterdata.usgs.gov"

function metadata(::USGSWaterDataset)
    Dict{Symbol,Any}(:data_type => "station", :license => "USGS public domain")
end

#--------------------------------------------------------------------------------# USGSWaterChunk
struct USGSWaterChunk <: Chunk
    url::String
    parameter_code::String
    collection::String
end

prefix(c::USGSWaterChunk)::Symbol = Symbol("usgswater_", c.collection, "_", c.parameter_code)
fetch(c::USGSWaterChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::USGSWaterChunk) = _head_content_length(c.url)

function extension(c::USGSWaterChunk)::String
    m = match(r"[?&]f=([^&]+)", c.url)
    fmt = isnothing(m) ? "json" : m.captures[1]
    fmt == "csv" ? "csv" : "json"
end

#--------------------------------------------------------------------------------# URL
function _usgs_build_url(d::USGSWaterDataset, extent, pc::String, t_start::Date, t_stop::Date)::String
    base = "$(_USGS_BASE_URL)/collections/$(d.collection)/items"
    params = ["f=$(d.format)", "parameter_code=$pc", "limit=10000"]
    push!(params, "time=$(Dates.format(t_start, dateformat"yyyy-mm-dd"))/$(Dates.format(t_stop, dateformat"yyyy-mm-dd"))")
    if !isempty(d.site_ids)
        push!(params, "monitoring_location_id=" * join(d.site_ids, ","))
    else
        push!(params, "bbox=$(extent.X[1]),$(extent.Y[1]),$(extent.X[2]),$(extent.Y[2])")
    end
    if d.collection == "daily"
        push!(params, "statistic_id=$(d.statistic_id)")
    end
    "$base?" * join(params, "&")
end

#--------------------------------------------------------------------------------# chunks
const _USGS_MAX_CONTINUOUS_DAYS = 90

function chunks(p::Project, d::USGSWaterDataset)::Vector{USGSWaterChunk}
    isnothing(p.datetimes) && error("USGS Water requires datetimes on the Project")
    d.collection in _USGS_COLLECTIONS || error("Invalid USGS Water collection: \"$(d.collection)\". Must be one of: $(join(_USGS_COLLECTIONS, ", "))")
    t_start = Date(first(p.datetimes))
    t_stop = Date(last(p.datetimes))
    result = USGSWaterChunk[]
    for pc in d.parameter_codes
        if d.collection == "daily"
            url = _usgs_build_url(d, p.extent, pc, t_start, t_stop)
            push!(result, USGSWaterChunk(url, pc, d.collection))
        else
            current = t_start
            while current <= t_stop
                chunk_stop = min(current + Day(_USGS_MAX_CONTINUOUS_DAYS - 1), t_stop)
                url = _usgs_build_url(d, p.extent, pc, current, chunk_stop)
                push!(result, USGSWaterChunk(url, pc, d.collection))
                current = chunk_stop + Day(1)
            end
        end
    end
    result
end

#--------------------------------------------------------------------------------# DATASETS
const _USGS_WATER_DATASETS = [
    USGSWaterDataset(parameter_codes=["00060"], collection="daily"),
    USGSWaterDataset(parameter_codes=["00065"], collection="daily"),
    USGSWaterDataset(parameter_codes=["00060"], collection="continuous"),
    USGSWaterDataset(parameter_codes=["00060", "00065", "00010"], collection="daily"),
]

const USGS_WATER_DAILY_DISCHARGE = _USGS_WATER_DATASETS[1]
const USGS_WATER_DAILY_GAGE_HEIGHT = _USGS_WATER_DATASETS[2]
const USGS_WATER_CONTINUOUS_DISCHARGE = _USGS_WATER_DATASETS[3]

#--------------------------------------------------------------------------------# datasets
function datasets(::USGSWater; collection=nothing, parameter_code=nothing)
    filter(d -> (collection === nothing || d.collection == collection) &&
           (parameter_code === nothing || parameter_code in d.parameter_codes), _USGS_WATER_DATASETS)
end
