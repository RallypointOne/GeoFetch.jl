#--------------------------------------------------------------------------------# OISST
const _OISST_BASE_URL = "https://www.ncei.noaa.gov/thredds/fileServer/OisstBase/NetCDF/V2.1/AVHRR"

"""NOAA OISST v2.1 daily global SST on a 0.25° grid. One NetCDF file per day, 1981–present."""
@kwdef struct OISSTDataset <: Dataset end

help(::OISST) = "https://www.ncei.noaa.gov/products/optimum-interpolation-sst"
help(::OISSTDataset) = "https://www.ncei.noaa.gov/products/optimum-interpolation-sst"

#--------------------------------------------------------------------------------# OISSTChunk
struct OISSTChunk <: Chunk
    url::String
    date::Date
end

prefix(c::OISSTChunk)::Symbol = :oisst
extension(::OISSTChunk)::String = "nc"
fetch(c::OISSTChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::OISSTChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# URL
function _oisst_url(date::Date)::String
    ym = Dates.format(date, dateformat"yyyymm")
    ymd = Dates.format(date, dateformat"yyyymmdd")
    "$(_OISST_BASE_URL)/$ym/oisst-avhrr-v02r01.$ymd.nc"
end

#--------------------------------------------------------------------------------# chunks
function chunks(p::Project, ::OISSTDataset)::Vector{OISSTChunk}
    isnothing(p.datetimes) && error("OISST requires datetimes on the Project")
    t_start = Date(first(p.datetimes))
    t_stop = Date(last(p.datetimes))
    [OISSTChunk(_oisst_url(d), d) for d in t_start:Day(1):t_stop]
end

#--------------------------------------------------------------------------------# DATASETS
const _OISST_DATASETS = [OISSTDataset()]

const OISST_DAILY = _OISST_DATASETS[1]

#--------------------------------------------------------------------------------# datasets
datasets(::OISST) = _OISST_DATASETS
