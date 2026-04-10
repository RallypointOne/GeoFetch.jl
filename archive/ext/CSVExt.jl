module CSVExt

using GeoFetch
using DataFrames
using CSV

import GeoFetch: DataAccessPlan, load, fetch, NASAFIRMS

#--------------------------------------------------------------------------------# NASA FIRMS

function GeoFetch.load(plan::DataAccessPlan{NASAFIRMS})
    files = fetch(plan)
    dfs = [CSV.read(f, DataFrame) for f in files]
    length(dfs) == 1 ? dfs[1] : vcat(dfs...; cols=:union)
end

end # module
