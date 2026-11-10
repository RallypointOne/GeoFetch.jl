using Dates
import NCDatasets
import Zarr

# In-memory source: `data` holds each variable on the full (un-narrowed) grid.
struct MemSource <: GeoFetch.Source
    schema::GeoFetch.SourceSchema
    units::Vector{GeoFetch.FetchUnit}
    data::Dict{Symbol, Array}
end

function GeoFetch.fetch!(src::MemSource, u::GeoFetch.FetchUnit, sch::GeoFetch.SourceSchema)
    full = src.schema
    names = GeoFetch._unitvars(u, sch)
    arrs = map(names) do n
        idx = map(GeoFetch.var(sch, n).dims) do d
            haskey(u.coords, d) || return GeoFetch._dimindex(full, sch, d)
            convert(Vector{Int}, indexin(u.coords[d], GeoFetch.dim(full, d).values))
        end
        src.data[n][idx...]
    end
    NamedTuple{Tuple(names)}(Tuple(arrs))
end

# Schema with dims x (6), y (4), time (`ts`) and Float32 vars `names` on [:x, :y, :time].
function _coreschema(ts, names)
    dims = [
        GeoFetch.DimSpec(:x, collect(0.0:5.0); attrs=Dict(:units => "m")),
        GeoFetch.DimSpec(:y, collect(10.0:10.0:40.0)),
        GeoFetch.DimSpec(:time, ts; attrs=Dict(:long_name => "time")),
    ]
    vars = map(n -> GeoFetch.VarSpec(n, [:x, :y, :time], Float32), names)
    GeoFetch.SourceSchema(dims, vars)
end

function _memsource(ts)
    sch = _coreschema(ts, [:a, :b])
    us = map(t -> GeoFetch.FetchUnit(; coords=Dict(:time => [t])), ts)
    a = reshape(Float32.(1:6*4*length(ts)), 6, 4, length(ts))
    MemSource(sch, us, Dict{Symbol, Array}(:a => a, :b => -a))
end

# NetCDF file with vars `v` (has a _FillValue, one missing cell) and `w`, both
# with in-memory dim order [:x, :y, :time]. Returns the in-memory `v`.
function _writenc(path, nt)
    v = Array{Union{Missing, Float32}}(reshape(Float32.(1:6*4*nt), 6, 4, nt))
    v[3, 2, 1] = missing
    NCDatasets.NCDataset(path, "c") do ds
        NCDatasets.defDim(ds, "x", 6)
        NCDatasets.defDim(ds, "y", 4)
        NCDatasets.defDim(ds, "time", nt)
        nv = NCDatasets.defVar(ds, "v", Float32, ("x", "y", "time"); fillvalue=-999.0f0)
        nw = NCDatasets.defVar(ds, "w", Float32, ("x", "y", "time"))
        nv[:, :, :] = v
        nw[:, :, :] = fill(7.0f0, 6, 4, nt)
    end
    v
end

@testset "core" begin
    @testset "_dimindex" begin
        ts = collect(Date(2025, 1, 1):Day(1):Date(2025, 1, 3))
        full = _coreschema(ts, [:a])
        (sch, _) = GeoFetch.apply_select(Select(x=[4.0, 1.0], y=All()), full, GeoFetch.FetchUnit[])
        @test GeoFetch._dimindex(full, sch, :y) === Colon()
        @test GeoFetch._dimindex(full, sch, :time) === Colon()
        @test GeoFetch._dimindex(full, sch, :x) == [2, 5]
        @test GeoFetch._dimindex(full, sch, :x) isa Vector{Int}
    end

    @testset "Select reaches fetch! (zarr v$zv)" for zv ∈ (2, 3)
        ts = collect(Date(2025, 1, 1):Day(1):Date(2025, 1, 3))
        src = _memsource(ts)
        path = joinpath(mktempdir(), "mem.zarr")
        sel = Select(vars=:a, x=Between(1.0, 3.0), time=Between(Date(2025, 1, 2), Date(2025, 1, 3)))
        execute(src | sel | Store(path; zarr_version=zv))
        g = Zarr.zopen(path)
        @test size(g["a"]) == (3, 4, 2)
        @test g["a"][:, :, :] == src.data[:a][2:4, :, 2:3]
        @test eltype(g["a"]) == Float32
        @test !haskey(g.arrays, "b")
        @test g["x"][:] == [1.0, 2.0, 3.0]
        @test g["x"].attrs["units"] == "m"
        @test g["y"][:] == [10.0, 20.0, 30.0, 40.0]
        t = g["time"]
        @test eltype(t) == Int64
        @test t[:] == [Dates.value(Date(2025, 1, 2) - Date(1970, 1, 1)), Dates.value(Date(2025, 1, 3) - Date(1970, 1, 1))]
        @test t[:] == [20090, 20091]
        @test t.attrs["units"] == "days since 1970-01-01"
        @test t.attrs["calendar"] == "proleptic_gregorian"
        @test t.attrs["long_name"] == "time"
        # the source's DimSpec attrs are not mutated by the encoding
        @test collect(keys(GeoFetch.dim(src.schema, :time).attrs)) == [:long_name]
    end

    @testset "DateTime dims (zarr v$zv)" for zv ∈ (2, 3)
        ts = collect(DateTime(2025, 1, 1):Hour(6):DateTime(2025, 1, 1, 12))
        src = _memsource(ts)
        path = joinpath(mktempdir(), "mem.zarr")
        execute(src | Store(path; zarr_version=zv))
        g = Zarr.zopen(path)
        @test size(g["a"]) == (6, 4, 3)
        @test g["a"][:, :, :] == src.data[:a]
        @test g["b"][:, :, :] == src.data[:b]
        t = g["time"]
        @test eltype(t) == Int64
        @test t[:] == 1735689600 .+ [0, 21600, 43200]
        @test t.attrs["units"] == "seconds since 1970-01-01T00:00:00"
        @test t.attrs["calendar"] == "proleptic_gregorian"
    end

    ts = [Date(2025, 1, 1), Date(2025, 1, 2)]
    ncpath = joinpath(mktempdir(), "core.nc")
    v = _writenc(ncpath, length(ts))
    full = _coreschema(ts, [:v, :w])
    u = GeoFetch.FetchUnit(; coords=Dict(:time => ts), payload="file://" * ncpath)

    @testset "_read_netcdf crop" begin
        sel = Select(vars=:v, x=Between(1.0, 3.0), y=[10.0, 20.0, 40.0])
        (sch, us) = GeoFetch.apply_select(sel, full, [u])
        data = GeoFetch._read_netcdf(ncpath, only(us), full, sch)
        @test keys(data) == (:v,)
        @test data.v isa Array{Float32, 3}
        @test size(data.v) == (3, 3, 2)
        # missing cell (x=3, y=2, t=1 on disk) lands at (2, 2, 1) after the crop
        @test isnan(data.v[2, 2, 1])
        @test count(isnan, data.v) == 1
        ex = coalesce.(v[2:4, [1, 2, 4], :], NaN32)
        @test isequal(data.v, ex)

        # un-narrowed schema: every variable, full extent
        data = GeoFetch._read_netcdf(ncpath, u, full, full)
        @test keys(data) == (:v, :w)
        @test size(data.v) == (6, 4, 2)
        @test data.w == fill(7.0f0, 6, 4, 2)
    end

    if !Sys.iswindows()
        @testset "HTTPFileSource pipeline" begin
            src = GeoFetch.HTTPFileSource(; schema=full, units=[u])
            path = joinpath(mktempdir(), "nc.zarr")
            execute(src | Select(vars=:v, x=Between(2.0, 4.0)) | Store(path))
            g = Zarr.zopen(path)
            @test !haskey(g.arrays, "w")
            @test size(g["v"]) == (3, 4, 2)
            @test isequal(g["v"][:, :, :], coalesce.(v[3:5, :, :], NaN32))
            @test g["x"][:] == [2.0, 3.0, 4.0]
            @test g["time"][:] == [20089, 20090]
        end
    end
end
