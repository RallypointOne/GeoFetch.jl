# Regenerates the ECMWF test fixture: a few real GRIB2 messages per file, cut out of the
# open data mirror by byte range, with `.index` sidecars rewritten for the cut-down files.
#
#     julia --startup-file=no test/fixtures/make_ecmwf_fixture.jl [outdir]
#
# Needs network access.  Uses only stdlibs.

using Dates
using Downloads

# (model, step in hours) => index "param:levtype:levelist" keys to keep, in file order
selection() = [
    ("ifs", 0) => ["2t:sfc:", "t:pl:500"],
    ("ifs", 6) => ["2t:sfc:", "t:pl:500", "t:pl:850", "tp:sfc:"],
    ("aifs-single", 6) => ["2t:sfc:"],
]

# path of an open data file relative to the mirror root, always with `/` separators
function ecmwfpath(model::AbstractString, t::DateTime, h::Integer)
    ymd = Dates.format(t, dateformat"yyyymmdd")
    hh = Dates.format(t, dateformat"HH")
    "$ymd/$(hh)z/$model/0p25/oper/$ymd$(hh)0000-$(h)h-oper-fc.grib2"
end

# `range` is the value of an HTTP Range header without the `bytes=` prefix
function fetchbytes(url::AbstractString; range=nothing)
    io = IOBuffer()
    hdrs = isnothing(range) ? Pair{String, String}[] : ["Range" => "bytes=$range"]
    Downloads.download(url, io; headers=hdrs)
    take!(io)
end

# value of the string-valued key `k` in the JSON object text `l`, "" if absent
function jsonstr(l::AbstractString, k::AbstractString)
    m = match(Regex("\"$k\": \"([^\"]*)\""), l)
    isnothing(m) ? "" : String(m[1])
end

jsonint(l::AbstractString, k::AbstractString) = parse(Int, match(Regex("\"$k\": (\\d+)"), l)[1])

# index lines are JSON objects with MARS keys plus `_offset` and `_length`
function indexlines(text::AbstractString)
    ls = filter(!isempty, map(strip, split(text, '\n')))
    map(ls) do l
        key = join((jsonstr(l, "param"), jsonstr(l, "levtype"), jsonstr(l, "levelist")), ':')
        (; offset=jsonint(l, "_offset"), length=jsonint(l, "_length"), key, text=String(l))
    end
end

function makefile(outdir::AbstractString, url::AbstractString, rel::AbstractString, keys)
    ls = indexlines(String(fetchbytes(replace(url, r"\.grib2$" => ".index"))))
    keep = map(keys) do k
        i = findfirst(l -> l.key == k, ls)
        isnothing(i) && error("no index line matched $k in $url")
        ls[i]
    end
    msgs = map(l -> fetchbytes(url; range="$(l.offset)-$(l.offset + l.length - 1)"), keep)
    offs = cumsum(vcat(0, map(length, msgs)))
    path = joinpath(outdir, split(rel, '/')...)
    mkpath(dirname(path))
    write(path, reduce(vcat, msgs))
    open(replace(path, r"\.grib2$" => ".index"), "w") do io
        foreach(eachindex(keep)) do n
            println(io, replace(keep[n].text, r"\"_offset\": \d+" => "\"_offset\": $(offs[n])"))
        end
    end
    @info "wrote $path" messages=length(keep) bytes=filesize(path)
    path
end

function parseargs(args)
    length(args) ≤ 1 || error("usage: make_ecmwf_fixture.jl [outdir]")
    (; outdir=isempty(args) ? joinpath(@__DIR__, "ecmwf") : only(args))
end

function (@main)(args)
    o = parseargs(args)
    base = "https://storage.googleapis.com/ecmwf-open-data"
    t = DateTime(2026, 11, 14, 0)
    foreach(selection()) do ((model, h), keys)
        rel = ecmwfpath(model, t, h)
        makefile(o.outdir, "$base/$rel", rel, keys)
    end
    0
end
