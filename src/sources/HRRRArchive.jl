#--------------------------------------------------------------------------------# HRRRArchive
const _HRRR_ARCHIVE_BASE = "https://noaa-hrrr-bdp-pds.s3.amazonaws.com"
# sfc = 2D surface fields, prs = 3D pressure levels, nat = 3D native model levels
const _HRRR_ARCHIVE_PRODUCTS = ("sfc", "prs", "nat")
# conus = contiguous US (3km), alaska = Alaska domain (3km)
const _HRRR_ARCHIVE_DOMAINS = ("conus", "alaska")

"""HRRR archived GRIB2 files by product (sfc/prs/nat), domain, forecast hours, and cycles."""
@kwdef mutable struct HRRRArchiveDataset <: Dataset
    const product::String = "sfc"
    const domain::String = "conus"
    forecast_hours::Vector{Int} = [0]
    cycles::Vector{Int} = [0]
end

help(::HRRRArchive) = "https://mesowest.utah.edu/html/hrrr/"
help(::HRRRArchiveDataset) = "https://registry.opendata.aws/noaa-hrrr-pds/"
GI.crs(::HRRRArchiveDataset) = nothing

function metadata(::HRRRArchiveDataset)
    Dict{Symbol,Any}(:data_type => "gridded", :license => "NOAA public domain")
end

#--------------------------------------------------------------------------------# HRRRArchiveChunk
struct HRRRArchiveChunk <: Chunk
    url::String
    date::Date
    cycle::Int
    forecast_hour::Int
    product::String
end

prefix(c::HRRRArchiveChunk)::Symbol = Symbol("hrrr_archive_", c.product)
extension(::HRRRArchiveChunk)::String = "grib2"
fetch(c::HRRRArchiveChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::HRRRArchiveChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# URL
function _hrrr_archive_url(d::HRRRArchiveDataset, date::Date, cycle::Int, fhour::Int)::String
    datestr = Dates.format(date, dateformat"yyyymmdd")
    cycle_str = lpad(cycle, 2, '0')
    fhour_str = lpad(fhour, 2, '0')
    file_prefix = d.product == "sfc" ? "wrfsfc" :
                  d.product == "prs" ? "wrfprs" : "wrfnat"
    "$(_HRRR_ARCHIVE_BASE)/hrrr.$(datestr)/$(d.domain)/hrrr.t$(cycle_str)z.$(file_prefix)f$(fhour_str).grib2"
end

#--------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::HRRRArchiveDataset)::Vector{HRRRArchiveChunk}
    d.product in _HRRR_ARCHIVE_PRODUCTS || error("Invalid HRRRArchive product: \"$(d.product)\". Must be one of: $(join(_HRRR_ARCHIVE_PRODUCTS, ", "))")
    d.domain in _HRRR_ARCHIVE_DOMAINS || error("Invalid HRRRArchive domain: \"$(d.domain)\". Must be one of: $(join(_HRRR_ARCHIVE_DOMAINS, ", "))")
    isnothing(p.datetimes) && error("HRRRArchive requires datetimes on the Project")
    t_start, t_stop = Date(first(p.datetimes)), Date(last(p.datetimes))
    result = HRRRArchiveChunk[]
    dt = t_start
    while dt <= t_stop
        for cycle in d.cycles
            for fhour in d.forecast_hours
                push!(result, HRRRArchiveChunk(_hrrr_archive_url(d, dt, cycle, fhour), dt, cycle, fhour, d.product))
            end
        end
        dt += Day(1)
    end
    result
end

#--------------------------------------------------------------------------------# DATASETS
const _HRRR_ARCHIVE_DATASETS = [
    HRRRArchiveDataset(product="sfc", domain="conus"),
    HRRRArchiveDataset(product="prs", domain="conus"),
    HRRRArchiveDataset(product="nat", domain="conus"),
    HRRRArchiveDataset(product="sfc", domain="alaska"),
]

const HRRR_ARCHIVE_SFC = _HRRR_ARCHIVE_DATASETS[1]
const HRRR_ARCHIVE_PRS = _HRRR_ARCHIVE_DATASETS[2]

#--------------------------------------------------------------------------------# datasets
function datasets(::HRRRArchive; product=nothing, domain=nothing)
    filter(d -> (product === nothing || d.product == product) &&
           (domain === nothing || d.domain == domain), _HRRR_ARCHIVE_DATASETS)
end
