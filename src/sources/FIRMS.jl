#------------------------------------------------------------------------------# FIRMS
const _FIRMS_BASE_URL = "https://firms.modaps.eosdis.nasa.gov/api/area"

function _firms_map_key()::String
    key = get(ENV, "FIRMS_MAP_KEY", "")
    isempty(key) && error("FIRMS MAP_KEY not found. Set FIRMS_MAP_KEY environment variable. " *
        "Register at https://firms.modaps.eosdis.nasa.gov/api/map_key/")
    key
end

# Satellite fire detection sources: NRT = near real-time, SP = standard processing
const FIRMS_SOURCES = [
    "LANDSAT_NRT",       # Landsat 8/9 near real-time
    "MODIS_NRT",         # Terra/Aqua MODIS near real-time
    "MODIS_SP",          # Terra/Aqua MODIS standard processing
    "VIIRS_SNPP_NRT",    # Suomi NPP VIIRS near real-time
    "VIIRS_SNPP_SP",     # Suomi NPP VIIRS standard processing
    "VIIRS_NOAA20_NRT",  # NOAA-20 VIIRS near real-time
    "VIIRS_NOAA20_SP",   # NOAA-20 VIIRS standard processing
    "VIIRS_NOAA21_NRT",  # NOAA-21 VIIRS near real-time
]

#------------------------------------------------------------------------------# FIRMSDataset
"""FIRMS active fire dataset by satellite source (VIIRS, MODIS, LANDSAT). Requires MAP_KEY."""
@kwdef struct FIRMSDataset <: Dataset
    source::String = "VIIRS_SNPP_NRT"
    format::String = "csv"
end

help(::FIRMS) = "https://firms.modaps.eosdis.nasa.gov"
help(::FIRMSDataset) = "https://firms.modaps.eosdis.nasa.gov"

#------------------------------------------------------------------------------# FireChunk
struct FireChunk <: Chunk
    url::String
    source::String
    start_date::Date
    day_range::Int
end

prefix(c::FireChunk)::Symbol = Symbol("firms_", c.source)

function extension(c::FireChunk)::String
    parts = split(c.url, '/')
    parts[6] == "json" ? "json" : "csv"
end

fetch(c::FireChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::FireChunk) = _head_content_length(c.url)

#------------------------------------------------------------------------------# chunks
const _FIRMS_MAX_DAYS = 5

function _firms_area_string(extent)::String
    extent == EARTH && return "world"
    "$(extent.X[1]),$(extent.Y[1]),$(extent.X[2]),$(extent.Y[2])"
end

function chunks(p::Project, d::FIRMSDataset)::Vector{FireChunk}
    isnothing(p.datetimes) && error("FIRMS requires datetimes on the Project")
    d.source in FIRMS_SOURCES || error("Unknown FIRMS source: \"$(d.source)\". Must be one of: $(join(FIRMS_SOURCES, ", "))")
    key = _firms_map_key()
    area = _firms_area_string(p.extent)
    t_start, t_stop = Date(first(p.datetimes)), Date(last(p.datetimes))
    t_start > t_stop && error("start date must be on or before stop date")
    result = FireChunk[]
    current = t_start
    while current <= t_stop
        remaining = Dates.value(t_stop - current) + 1
        day_range = min(remaining, _FIRMS_MAX_DAYS)
        date_str = Dates.format(current, dateformat"yyyy-mm-dd")
        url = "$(_FIRMS_BASE_URL)/$(d.format)/$key/$(d.source)/$area/$day_range/$date_str"
        push!(result, FireChunk(url, d.source, current, day_range))
        current += Day(day_range)
    end
    result
end

#------------------------------------------------------------------------------# DATASETS
const _FIRMS_DATASETS = [FIRMSDataset(source=s) for s in FIRMS_SOURCES]

datasets(::FIRMS) = _FIRMS_DATASETS
