#--------------------------------------------------------------------------------# GOES
# GOES-16 = East (operational), GOES-17 = decommissioned, GOES-18 = West (operational)
const _GOES_SATELLITES = ("goes16", "goes17", "goes18")

const _GOES_S3_BASE = Dict(
    # GOES-East - operational, covers eastern Americas/Atlantic
    "goes16" => "https://noaa-goes16.s3.amazonaws.com",
    # Decommissioned, replaced by GOES-18
    "goes17" => "https://noaa-goes17.s3.amazonaws.com",
    # GOES-West - operational, covers western Americas/Pacific
    "goes18" => "https://noaa-goes18.s3.amazonaws.com",
)

"""GOES satellite imagery dataset by satellite (16/17/18), product, and optional band."""
@kwdef mutable struct GOESDataset <: Dataset
    const satellite::String = "goes16"
    const product::String = "ABI-L2-CMIPF"
    band::Union{Nothing, Int} = nothing
end

help(::GOES) = "https://www.goes.noaa.gov"
help(::GOESDataset) = "https://registry.opendata.aws/noaa-goes/"
GI.crs(::GOESDataset) = nothing

#--------------------------------------------------------------------------------# GOESChunk
struct GOESChunk <: Chunk
    url::String
    key::String
    satellite::String
    product::String
end

prefix(c::GOESChunk)::Symbol = Symbol("goes_", c.satellite)
extension(::GOESChunk)::String = "nc"
fetch(c::GOESChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::GOESChunk) = _head_content_length(c.url)

#--------------------------------------------------------------------------------# S3 listing
function _goes_urlencode(s::AbstractString)::String
    io = IOBuffer()
    for c in s
        if isletter(c) || isdigit(c) || c in ('-', '_', '.', '~')
            write(io, c)
        else
            for b in codeunits(string(c))
                write(io, '%', uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(io))
end

function _goes_list_keys(satellite::String, prefix::String)::Vector{String}
    base = _GOES_S3_BASE[satellite]
    keys = String[]
    url = "$base?list-type=2&prefix=$prefix"
    while true
        io = IOBuffer()
        Downloads.download(url, io)
        xml = String(take!(io))
        for m in eachmatch(r"<Key>([^<]+)</Key>", xml)
            push!(keys, m.captures[1])
        end
        occursin("<IsTruncated>true</IsTruncated>", xml) || break
        token_m = match(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
        isnothing(token_m) && break
        url = "$base?list-type=2&prefix=$prefix&continuation-token=$(_goes_urlencode(token_m.captures[1]))"
    end
    keys
end

function _goes_s3_prefix(product::String, dt::DateTime)::String
    doy = Dates.dayofyear(dt)
    hour = lpad(Dates.hour(dt), 2, '0')
    "$product/$(Dates.year(dt))/$(lpad(doy, 3, '0'))/$hour/"
end

#--------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::GOESDataset)::Vector{GOESChunk}
    d.satellite in _GOES_SATELLITES || error("Invalid GOES satellite: \"$(d.satellite)\". Must be one of: $(join(_GOES_SATELLITES, ", "))")
    isnothing(p.datetimes) && error("GOES requires datetimes on the Project")
    base = _GOES_S3_BASE[d.satellite]
    t_start, t_stop = p.datetimes
    result = GOESChunk[]
    current = floor(t_start, Dates.Hour)
    stop_hour = floor(t_stop, Dates.Hour)
    while current <= stop_hour
        s3_prefix = _goes_s3_prefix(d.product, current)
        for key in _goes_list_keys(d.satellite, s3_prefix)
            if !isnothing(d.band)
                band_str = "_C" * lpad(d.band, 2, '0') * "_"
                occursin(band_str, key) || continue
            end
            push!(result, GOESChunk("$base/$key", key, d.satellite, d.product))
        end
        current += Dates.Hour(1)
    end
    result
end

#--------------------------------------------------------------------------------# DATASETS
const _GOES_DATASETS = [
    GOESDataset(satellite="goes16", product="ABI-L2-CMIPF"),
    GOESDataset(satellite="goes16", product="ABI-L1b-RadC"),
    GOESDataset(satellite="goes16", product="ABI-L2-SSTF"),
    GOESDataset(satellite="goes18", product="ABI-L2-CMIPF"),
    GOESDataset(satellite="goes18", product="ABI-L1b-RadC"),
    GOESDataset(satellite="goes18", product="ABI-L2-SSTF"),
    GOESDataset(satellite="goes16", product="GLM-L2-LCFA"),
    GOESDataset(satellite="goes18", product="GLM-L2-LCFA"),
]

const GOES16_CMIP = _GOES_DATASETS[1]
const GOES18_CMIP = _GOES_DATASETS[4]
const GOES16_SST = _GOES_DATASETS[3]
const GOES18_SST = _GOES_DATASETS[6]
const GOES16_GLM = _GOES_DATASETS[7]

#--------------------------------------------------------------------------------# datasets
function datasets(::GOES; satellite=nothing, product=nothing)
    filter(d -> (satellite === nothing || d.satellite == satellite) &&
           (product === nothing || occursin(product, d.product)), _GOES_DATASETS)
end
