"""
    CDS

Access the Copernicus Climate Data Store (CDS) API for ERA5, CERRA, satellite, and
seasonal forecast data.

Requires a CDS API key: set `CDSAPI_KEY` environment variable or create `~/.cdsapirc`
with `key: <your-key>`.  Register at <https://cds.climate.copernicus.eu>.

Browse available datasets with `CDS.DATASETS` or `CDS.datasets(...)`.
Popular datasets are available as constants: `CDS.ERA5_SINGLE_LEVELS`, etc.

### Examples

```julia
era5 = CDS.ERA5_SINGLE_LEVELS
era5.variables = ["2m_temperature"]
era5.times = ["12:00"]
```
"""
module CDS

using ..GeoFetch
using Dates
using Downloads
using JSON

#------------------------------------------------------------------------------# Auth
const API_BASE = "https://cds.climate.copernicus.eu/api"

# Read CDS API key from CDSAPI_KEY env var or ~/.cdsapirc
function _api_key()::String
    key = get(ENV, "CDSAPI_KEY", "")
    !isempty(key) && return key
    rc = joinpath(homedir(), ".cdsapirc")
    if isfile(rc)
        for line in eachline(rc)
            m = match(r"^\s*key\s*:\s*(.+)$", line)
            !isnothing(m) && return strip(m.captures[1])
        end
    end
    error("CDS API key not found. Set CDSAPI_KEY or create ~/.cdsapirc with `key: <your-key>`")
end

# Build authorization headers for CDS API requests
function _auth_headers()::Vector{Pair{String,String}}
    ["PRIVATE-TOKEN" => _api_key()]
end

#------------------------------------------------------------------------------# HTTP helpers
# POST JSON to a URL and return parsed response
function _post_json(url::AbstractString, body::AbstractString)
    headers = [_auth_headers(); "Content-Type" => "application/json"]
    io = IOBuffer()
    Downloads.request(url; method="POST", headers, input=IOBuffer(body), output=io)
    JSON.parse(String(take!(io)))
end

# GET a URL and return parsed response
function _get_json(url::AbstractString)
    io = IOBuffer()
    Downloads.download(url, io; headers=_auth_headers())
    JSON.parse(String(take!(io)))
end

#------------------------------------------------------------------------------# Dataset
"""
    Dataset(; dataset_id, product_type="reanalysis", variables=[], times=["00:00","06:00","12:00","18:00"], format="netcdf", pressure_levels=[])

A CDS dataset.

# Const Fields
- `dataset_id::String` — CDS dataset identifier (e.g. `"reanalysis-era5-single-levels"`).
- `product_type::String` — product type (e.g. `"reanalysis"`, `"monthly_averaged_reanalysis"`).

# Mutable Fields
- `variables::Vector{String}` — variable short names (e.g. `["2m_temperature"]`).
- `times::Vector{String}` — hours to request (e.g. `["00:00", "12:00"]`).
- `format::String` — output format: `"netcdf"` or `"grib"`.
- `pressure_levels::Vector{String}` — pressure levels for upper-air datasets (e.g. `["500", "850"]`).
"""
@kwdef mutable struct Dataset <: GeoFetch.Dataset
    const dataset_id::String
    const product_type::String = "reanalysis"
    variables::Vector{String} = String[]
    times::Vector{String} = ["00:00", "06:00", "12:00", "18:00"]
    format::String = "netcdf"
    pressure_levels::Vector{String} = String[]
end

GeoFetch.help(d::Dataset) = "https://cds.climate.copernicus.eu/datasets/$(d.dataset_id)"

#------------------------------------------------------------------------------# CDSChunk
"""
    CDSChunk

A single CDS API request.  Implements the [`Chunk`](@ref GeoFetch.Chunk) interface.

`fetch` submits the job, polls until completion, and downloads the result.
"""
struct CDSChunk <: GeoFetch.Chunk
    dataset_id::String
    body::String
end

GeoFetch.prefix(c::CDSChunk)::Symbol = Symbol(c.dataset_id)
GeoFetch.extension(c::CDSChunk)::String = "nc"

function GeoFetch.fetch(c::CDSChunk, file::String)
    url = "$API_BASE/retrieve/v1/processes/$(c.dataset_id)/execute/"
    resp = _post_json(url, c.body)
    job_id = get(resp, "jobID", get(resp, "request_id", nothing))
    isnothing(job_id) && error("CDS job submission failed: $(JSON.json(resp))")
    status_url = "$API_BASE/retrieve/v1/jobs/$job_id"
    while true
        status = _get_json(status_url)
        state = get(status, "status", get(status, "state", "unknown"))
        state == "successful" && break
        state in ("failed", "dismissed") && error("CDS job $job_id failed: $(JSON.json(status))")
        sleep(5)
    end
    results = _get_json("$status_url/results")
    result_list = get(results, "asset", get(results, "results", nothing))
    download_url = if result_list isa Dict
        result_list["value"]["href"]
    elseif result_list isa Vector
        result_list[1]["href"]
    else
        error("Unexpected CDS results format: $(JSON.json(results))")
    end
    Downloads.download(download_url, file; headers=_auth_headers())
    file
end

# Build the JSON request body from Dataset + Project (CDS v2 "inputs" format)
function _build_body(p::GeoFetch.Project, d::Dataset, date_str::AbstractString)::String
    inputs = Dict{String,Any}()
    inputs["product_type"] = [d.product_type]
    !isempty(d.variables) && (inputs["variable"] = d.variables)
    inputs["date"] = [date_str]
    !isempty(d.times) && (inputs["time"] = d.times)
    !isempty(d.pressure_levels) && (inputs["pressure_level"] = d.pressure_levels)
    if p.extent != GeoFetch.EARTH
        ext = p.extent
        inputs["area"] = [ext.Y[2], ext.X[1], ext.Y[1], ext.X[2]]
    end
    inputs["data_format"] = d.format
    JSON.json(Dict("inputs" => inputs))
end

#------------------------------------------------------------------------------# chunks
function GeoFetch.chunks(p::GeoFetch.Project, d::Dataset)::Vector{CDSChunk}
    if isnothing(p.datetimes)
        error("CDS requires datetimes on the Project")
    end
    t_start, t_stop = p.datetimes
    chunks = CDSChunk[]
    dt = Date(t_start)
    while dt <= Date(t_stop)
        last_day = min(lastdayofmonth(dt), Date(t_stop))
        date_str = Dates.format(dt, "yyyy-mm-dd") * "/" * Dates.format(last_day, "yyyy-mm-dd")
        body = _build_body(p, d, date_str)
        push!(chunks, CDSChunk(d.dataset_id, body))
        dt = firstdayofmonth(dt) + Month(1)
    end
    chunks
end

#------------------------------------------------------------------------------# DATASETS
const DATASETS = [
    # ERA5 Reanalysis
    Dataset(dataset_id="reanalysis-era5-single-levels"),
    Dataset(dataset_id="reanalysis-era5-pressure-levels"),
    Dataset(dataset_id="reanalysis-era5-single-levels-monthly-means", product_type="monthly_averaged_reanalysis"),
    Dataset(dataset_id="reanalysis-era5-pressure-levels-monthly-means", product_type="monthly_averaged_reanalysis"),
    Dataset(dataset_id="reanalysis-era5-land"),
    Dataset(dataset_id="reanalysis-era5-land-monthly-means", product_type="monthly_averaged_reanalysis"),
    # ERA5 Preliminary (near-real-time)
    Dataset(dataset_id="reanalysis-era5-single-levels-preliminary-back-extension"),
    Dataset(dataset_id="reanalysis-era5-pressure-levels-preliminary-back-extension"),
    # CERRA Regional Reanalysis
    Dataset(dataset_id="reanalysis-cerra-single-levels"),
    Dataset(dataset_id="reanalysis-cerra-pressure-levels"),
    Dataset(dataset_id="reanalysis-cerra-land"),
    # Satellite
    Dataset(dataset_id="satellite-sea-surface-temperature"),
    Dataset(dataset_id="satellite-sea-level-global"),
    Dataset(dataset_id="satellite-soil-moisture"),
    # Seasonal Forecasts
    Dataset(dataset_id="seasonal-original-single-levels", product_type="ensemble_mean"),
    Dataset(dataset_id="seasonal-original-pressure-levels", product_type="ensemble_mean"),
    Dataset(dataset_id="seasonal-monthly-single-levels", product_type="ensemble_mean"),
    Dataset(dataset_id="seasonal-monthly-pressure-levels", product_type="ensemble_mean"),
    # Climate Projections
    Dataset(dataset_id="projections-cmip6"),
    Dataset(dataset_id="projections-cordex-domains-single-levels"),
    # Other Reanalyses
    Dataset(dataset_id="reanalysis-uerra-europe-single-levels"),
    Dataset(dataset_id="reanalysis-oras5"),
]

#------------------------------------------------------------------------------# Popular Datasets
const ERA5_SINGLE_LEVELS = DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-single-levels", DATASETS)]
const ERA5_PRESSURE_LEVELS = DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-pressure-levels", DATASETS)]
const ERA5_SINGLE_LEVELS_MONTHLY = DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-single-levels-monthly-means", DATASETS)]
const ERA5_PRESSURE_LEVELS_MONTHLY = DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-pressure-levels-monthly-means", DATASETS)]
const ERA5_LAND = DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-land", DATASETS)]

#------------------------------------------------------------------------------# Dataset querying
"""
    datasets(; dataset_id=nothing, product_type=nothing) -> Dict{String, Dataset}

Filter `DATASETS` by keyword.  Both filters use substring matching.

### Examples

```julia
CDS.datasets(dataset_id="era5")
CDS.datasets(product_type="monthly")
```
"""
function datasets(; dataset_id=nothing, product_type=nothing)
    out = filter(d -> (dataset_id === nothing || occursin(dataset_id, d.dataset_id)) &&
                 (product_type === nothing || occursin(product_type, d.product_type)), DATASETS)
    Dict(x.dataset_id => x for x in out)
end

end
