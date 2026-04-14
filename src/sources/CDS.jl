#------------------------------------------------------------------------------# CDS
const _CDS_API_BASE = "https://cds.climate.copernicus.eu/api"

function _cds_api_key()::String
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

function _cds_auth_headers()::Vector{Pair{String,String}}
    ["PRIVATE-TOKEN" => _cds_api_key()]
end

_cds_post_json(url::AbstractString, body::AbstractString) = post_json(url, body; headers=_cds_auth_headers())
_cds_get_json(url::AbstractString) = get_json(url; headers=_cds_auth_headers())

#------------------------------------------------------------------------------# CDSDataset
"""CDS dataset configured by dataset ID, variables, times, and output format. Requires API key."""
@kwdef mutable struct CDSDataset <: Dataset
    const dataset_id::String
    const product_type::String = "reanalysis"
    variables::Vector{String} = String[]
    times::Vector{String} = ["00:00", "06:00", "12:00", "18:00"]
    format::String = "netcdf"
    pressure_levels::Vector{String} = String[]
end

help(::CDS) = "https://cds.climate.copernicus.eu"
help(d::CDSDataset) = "https://cds.climate.copernicus.eu/datasets/$(d.dataset_id)"

#------------------------------------------------------------------------------# CDSChunk
struct CDSChunk <: Chunk
    dataset_id::String
    body::String
end

prefix(c::CDSChunk)::Symbol = Symbol(c.dataset_id)
extension(::CDSChunk)::String = "nc"

function fetch(c::CDSChunk, file::String)
    url = "$_CDS_API_BASE/retrieve/v1/processes/$(c.dataset_id)/execute/"
    resp = _cds_post_json(url, c.body)
    job_id = get(resp, "jobID", get(resp, "request_id", nothing))
    isnothing(job_id) && error("CDS job submission failed: $(JSON.json(resp))")
    status_url = "$_CDS_API_BASE/retrieve/v1/jobs/$job_id"
    while true
        status = _cds_get_json(status_url)
        state = get(status, "status", get(status, "state", "unknown"))
        state == "successful" && break
        state in ("failed", "dismissed") && error("CDS job $job_id failed: $(JSON.json(status))")
        sleep(5)
    end
    results = _cds_get_json("$status_url/results")
    result_list = get(results, "asset", get(results, "results", nothing))
    download_url = if result_list isa AbstractDict
        result_list["value"]["href"]
    elseif result_list isa AbstractVector
        result_list[1]["href"]
    else
        error("Unexpected CDS results format: $(JSON.json(results))")
    end
    Downloads.download(download_url, file; headers=_cds_auth_headers())
    file
end

function _cds_build_body(p::Project, d::CDSDataset, date_str::AbstractString)::String
    inputs = Dict{String,Any}()
    inputs["product_type"] = [d.product_type]
    !isempty(d.variables) && (inputs["variable"] = d.variables)
    inputs["date"] = [date_str]
    !isempty(d.times) && (inputs["time"] = d.times)
    !isempty(d.pressure_levels) && (inputs["pressure_level"] = d.pressure_levels)
    if p.extent != EARTH
        ext = p.extent
        inputs["area"] = [ext.Y[2], ext.X[1], ext.Y[1], ext.X[2]]
    end
    inputs["data_format"] = d.format
    JSON.json(Dict("inputs" => inputs))
end

#------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::CDSDataset)::Vector{CDSChunk}
    isnothing(p.datetimes) && error("CDS requires datetimes on the Project")
    t_start, t_stop = p.datetimes
    result = CDSChunk[]
    dt = Date(t_start)
    while dt <= Date(t_stop)
        last_day = min(lastdayofmonth(dt), Date(t_stop))
        date_str = Dates.format(dt, "yyyy-mm-dd") * "/" * Dates.format(last_day, "yyyy-mm-dd")
        body = _cds_build_body(p, d, date_str)
        push!(result, CDSChunk(d.dataset_id, body))
        dt = firstdayofmonth(dt) + Month(1)
    end
    result
end

#------------------------------------------------------------------------------# DATASETS
const _CDS_DATASETS = [
    # ERA5 Reanalysis
    CDSDataset(dataset_id="reanalysis-era5-single-levels"),
    CDSDataset(dataset_id="reanalysis-era5-pressure-levels"),
    CDSDataset(dataset_id="reanalysis-era5-single-levels-monthly-means", product_type="monthly_averaged_reanalysis"),
    CDSDataset(dataset_id="reanalysis-era5-pressure-levels-monthly-means", product_type="monthly_averaged_reanalysis"),
    CDSDataset(dataset_id="reanalysis-era5-land"),
    CDSDataset(dataset_id="reanalysis-era5-land-monthly-means", product_type="monthly_averaged_reanalysis"),
    # ERA5 Preliminary (near-real-time)
    CDSDataset(dataset_id="reanalysis-era5-single-levels-preliminary-back-extension"),
    CDSDataset(dataset_id="reanalysis-era5-pressure-levels-preliminary-back-extension"),
    # CERRA Regional Reanalysis
    CDSDataset(dataset_id="reanalysis-cerra-single-levels"),
    CDSDataset(dataset_id="reanalysis-cerra-pressure-levels"),
    CDSDataset(dataset_id="reanalysis-cerra-land"),
    # Satellite
    CDSDataset(dataset_id="satellite-sea-surface-temperature"),
    CDSDataset(dataset_id="satellite-sea-level-global"),
    CDSDataset(dataset_id="satellite-soil-moisture"),
    # Seasonal Forecasts
    CDSDataset(dataset_id="seasonal-original-single-levels", product_type="ensemble_mean"),
    CDSDataset(dataset_id="seasonal-original-pressure-levels", product_type="ensemble_mean"),
    CDSDataset(dataset_id="seasonal-monthly-single-levels", product_type="ensemble_mean"),
    CDSDataset(dataset_id="seasonal-monthly-pressure-levels", product_type="ensemble_mean"),
    # Climate Projections
    CDSDataset(dataset_id="projections-cmip6"),
    CDSDataset(dataset_id="projections-cordex-domains-single-levels"),
    # Other Reanalyses
    CDSDataset(dataset_id="reanalysis-uerra-europe-single-levels"),
    CDSDataset(dataset_id="reanalysis-oras5"),
]

#------------------------------------------------------------------------------# Popular Datasets
const ERA5_SINGLE_LEVELS = _CDS_DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-single-levels", _CDS_DATASETS)]
const ERA5_PRESSURE_LEVELS = _CDS_DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-pressure-levels", _CDS_DATASETS)]
const ERA5_SINGLE_LEVELS_MONTHLY = _CDS_DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-single-levels-monthly-means", _CDS_DATASETS)]
const ERA5_PRESSURE_LEVELS_MONTHLY = _CDS_DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-pressure-levels-monthly-means", _CDS_DATASETS)]
const ERA5_LAND = _CDS_DATASETS[findfirst(d -> d.dataset_id == "reanalysis-era5-land", _CDS_DATASETS)]

#------------------------------------------------------------------------------# datasets
function datasets(::CDS; dataset_id=nothing, product_type=nothing)
    filter(d -> (dataset_id === nothing || occursin(dataset_id, d.dataset_id)) &&
           (product_type === nothing || occursin(product_type, d.product_type)), _CDS_DATASETS)
end
