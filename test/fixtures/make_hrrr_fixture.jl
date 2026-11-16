# Regenerates the HRRR test fixture: a few real GRIB2 messages per file, cut out of the
# public NOAA bucket by byte range, with `.idx` sidecars rewritten for the cut-down files.
#
#     julia --startup-file=no test/fixtures/make_hrrr_fixture.jl [outdir]
#
# Needs network access.  Uses only stdlibs.

using Dates
using Downloads

# (product, step in hours) => idx "PARAM:level" keys to keep (every matching line is kept)
selection() = [
    ("wrfsfc", 0) => ["LAND:surface"],
    ("wrfsfc", 1) => ["TMP:2 m above ground", "APCP:surface", "LAND:surface"],
    ("wrfprs", 0) => ["TMP:500 mb"],
    ("wrfprs", 1) => ["TMP:500 mb", "TMP:850 mb"],
]

# path of a HRRR CONUS file relative to the bucket root, always with `/` separators
function hrrrpath(t::DateTime, product::AbstractString, h::Integer)
    ymd = Dates.format(t, dateformat"yyyymmdd")
    hh = Dates.format(t, dateformat"HH")
    "hrrr.$ymd/conus/hrrr.t$(hh)z.$(product)f$(lpad(h, 2, '0')).grib2"
end

# `range` is the value of an HTTP Range header without the `bytes=` prefix
function fetchbytes(url::AbstractString; range=nothing)
    io = IOBuffer()
    hdrs = isnothing(range) ? Pair{String, String}[] : ["Range" => "bytes=$range"]
    Downloads.download(url, io; headers=hdrs)
    take!(io)
end

# idx lines are "n:offset:d=YYYYMMDDHH:PARAM:level:forecast:"; `rest` is the text after
# "n:offset:" and `key` is "PARAM:level"
function idxlines(text::AbstractString)
    ls = filter(!isempty, map(strip, split(text, '\n')))
    map(ls) do l
        f = split(l, ':')
        rest = join(f[3:end], ':')
        (; offset=parse(Int, f[2]), key=f[4] * ":" * f[5], rest)
    end
end

# zero-based inclusive byte range of the message starting at offset `a`: it runs to the
# next strictly larger offset - 1, or to the end of the file
function byterange(ls, a::Integer)
    nxt = filter(>(a), map(l -> l.offset, ls))
    isempty(nxt) ? "$a-" : "$a-$(minimum(nxt) - 1)"
end

function makefile(outdir::AbstractString, url::AbstractString, rel::AbstractString, keys)
    ls = idxlines(String(fetchbytes(url * ".idx")))
    keep = filter(l -> l.key ∈ keys, ls)
    isempty(keep) && error("no idx lines matched in $url.idx")
    msgs = map(l -> fetchbytes(url; range=byterange(ls, l.offset)), keep)
    offs = cumsum(vcat(0, map(length, msgs)))
    path = joinpath(outdir, split(rel, '/')...)
    mkpath(dirname(path))
    write(path, reduce(vcat, msgs))
    open(path * ".idx", "w") do io
        foreach(n -> println(io, n, ":", offs[n], ":", keep[n].rest), eachindex(keep))
    end
    @info "wrote $path" messages=length(keep) bytes=filesize(path)
    path
end

function parseargs(args)
    length(args) ≤ 1 || error("usage: make_hrrr_fixture.jl [outdir]")
    (; outdir=isempty(args) ? joinpath(@__DIR__, "hrrr") : only(args))
end

function (@main)(args)
    o = parseargs(args)
    base = "https://noaa-hrrr-bdp-pds.s3.amazonaws.com"
    t = DateTime(2026, 11, 14, 0)
    foreach(selection()) do ((product, h), keys)
        rel = hrrrpath(t, product, h)
        makefile(o.outdir, "$base/$rel", rel, keys)
    end
    0
end
