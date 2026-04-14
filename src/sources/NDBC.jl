#------------------------------------------------------------------------------# NDBC
const _NDBC_BASE = "https://www.ndbc.noaa.gov/data"
const _NDBC_THREDDS = "https://dods.ndbc.noaa.gov/thredds/fileServer/data"

const _NDBC_DATATYPES = Dict(
    "stdmet" => "h",
    "cwind"  => "c",
    "ocean"  => "o",
    "swden"  => "w",
    "swdir"  => "d",
    "swdir2" => "j",
    "swr1"   => "k",
    "swr2"   => "l",
    "adcp"   => "a",
    "dart"   => "d",
    "srad"   => "r",
    "supl"   => "s",
)

const _NDBC_REALTIME_EXT = Dict(
    "stdmet" => "txt",
    "cwind"  => "cwind",
    "ocean"  => "ocean",
    "swden"  => "data_spec",
    "swdir"  => "swdir",
    "swdir2" => "swdir2",
    "swr1"   => "swr1",
    "swr2"   => "swr2",
    "adcp"   => "adcp",
    "dart"   => "dart",
    "srad"   => "srad",
    "supl"   => "supl",
)

#------------------------------------------------------------------------------# NDBCDataset
"""NDBC buoy observations by station, data type, and format (text or NetCDF)."""
@kwdef struct NDBCDataset <: Dataset
    stations::Vector{String} = String[]
    datatype::String = "stdmet"
    format::String = "txt"
end

help(::NDBC) = "https://www.ndbc.noaa.gov"
help(::NDBCDataset) = "https://www.ndbc.noaa.gov/docs/ndbc_web_data_guide.pdf"

function metadata(::NDBCDataset)
    Dict{Symbol,Any}(:data_type => "station", :license => "NOAA public domain")
end

#------------------------------------------------------------------------------# NDBCChunk
struct NDBCChunk <: Chunk
    url::String
    station::String
    datatype::String
    year::Int
end

prefix(c::NDBCChunk)::Symbol = Symbol("ndbc_", c.station, "_", c.datatype)

function extension(c::NDBCChunk)::String
    endswith(c.url, ".gz") && return "txt.gz"
    endswith(c.url, ".nc") && return "nc"
    "txt"
end

fetch(c::NDBCChunk, file::String) = Downloads.download(c.url, file)

#------------------------------------------------------------------------------# Station discovery
function _ndbc_stations_in_extent(extent)::Vector{String}
    data = get_json("https://www.ndbc.noaa.gov/ndbcmapstations.json")
    stations = String[]
    for info in get(data, "station", [])
        lat = get(info, "lat", nothing)
        lon = get(info, "lon", nothing)
        (lat === nothing || lon === nothing) && continue
        lat = Float64(lat)
        lon = Float64(lon)
        if extent.X[1] <= lon <= extent.X[2] && extent.Y[1] <= lat <= extent.Y[2]
            push!(stations, string(info["id"]))
        end
    end
    stations
end

#------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::NDBCDataset)::Vector{NDBCChunk}
    haskey(_NDBC_DATATYPES, d.datatype) || error("Invalid NDBC datatype: \"$(d.datatype)\". Must be one of: $(join(keys(_NDBC_DATATYPES), ", "))")
    d.format in ("txt", "nc") || error("Invalid NDBC format: \"$(d.format)\". Must be \"txt\" or \"nc\"")
    isnothing(p.datetimes) && error("NDBC requires datetimes on the Project")

    station_ids = if isempty(d.stations)
        p.extent == EARTH && error("NDBC requires station IDs or a bounded extent. Set stations on the dataset or geometry on the Project.")
        _ndbc_stations_in_extent(p.extent)
    else
        d.stations
    end
    isempty(station_ids) && error("No NDBC stations found for the given extent")

    t_start, t_stop = p.datetimes
    prefix = _NDBC_DATATYPES[d.datatype]
    result = NDBCChunk[]
    for station in station_ids
        for y in year(t_start):year(t_stop)
            if d.format == "nc"
                url = "$(_NDBC_THREDDS)/$(d.datatype)/$(station)/$(station)$(prefix)$(y).nc"
            else
                url = "$(_NDBC_BASE)/historical/$(d.datatype)/$(station)$(prefix)$(y).txt.gz"
            end
            push!(result, NDBCChunk(url, station, d.datatype, y))
        end
    end
    result
end

#------------------------------------------------------------------------------# DATASETS
const _NDBC_DATASETS = [
    NDBCDataset(datatype="stdmet"),
    NDBCDataset(datatype="ocean"),
    NDBCDataset(datatype="cwind"),
    NDBCDataset(datatype="swden"),
]

const NDBC_STDMET = _NDBC_DATASETS[1]
const NDBC_OCEAN = _NDBC_DATASETS[2]

#------------------------------------------------------------------------------# datasets
function datasets(::NDBC; datatype=nothing)
    filter(d -> (datatype === nothing || d.datatype == datatype), _NDBC_DATASETS)
end
