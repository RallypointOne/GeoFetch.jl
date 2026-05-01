"""
    GeoFetch

Build Zarr stores on disk from remote geospatial data sources using a small
DAG-style pipeline. A pipeline is a chain of `Stage`s combined with the `|`
operator and has the shape

    Source | [Transform ...] | Sink

Components:

- `Source`     — describes upstream data (a `SourceSchema`) and how it is
                 partitioned for fetching (a list of `FetchUnit`s). Sources
                 are organized by *transport* (`HTTPFileSource`,
                 `CDSAPISource`, …); user-friendly presets like `OISST(...)`
                 build a transport source pre-configured for a known dataset.
- `Transform`  — narrows or reshapes the pipeline. `Select` filters dims and
                 variables (and the unit list along with them). `Rechunk`
                 overrides the output chunk shape but does not affect what
                 gets fetched.
- `Sink`       — the materialization target. Currently only `Store`, which
                 writes a Zarr v2 or v3 store on local disk.

Building a pipeline is purely value-level: nothing is downloaded, no I/O
happens, no Zarr is created. The pipeline value can be inspected, printed,
or composed further. Calling `execute(pipeline)` is the one operation that
actually does work — it resolves the effective schema and unit list,
creates the Zarr group + arrays, then iterates the unit list and writes
each fetched chunk into place.

Public exports:
- Stage hierarchy: `Stage`, `Source`, `Transform`, `Sink`, `Pipeline`
- Transforms / sink: `Select`, `Rechunk`, `Store`
- Selectors: `All`, `Between`
- Presets: `OISST`, `ERA5`
- Entry point: `execute`
"""
module GeoFetch

using Dates
using Downloads
using Zarr
using NCDatasets

export Pipeline, Stage, Source, Transform, Sink
export Select, Rechunk, Store
export All, Between
export OISST, ERA5
export execute

# Order matters: schema types are referenced by every stage, the Stage
# hierarchy is referenced by transforms/sinks/sources, and execute pulls
# everything together at the bottom.
include("schema.jl")
include("pipeline.jl")
include("transforms.jl")
include("store.jl")
include("transports.jl")
include("presets.jl")
include("execute.jl")

end # module
