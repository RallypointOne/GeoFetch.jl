import GRIB

# Checks the fixture independently of the package's own idx parser:
# "n:offset:..." lines → zero-based inclusive byte ranges (last message runs to EOF).
function _fixtureranges(path)
    a = map(l -> parse(Int, split(l, ':')[2]), filter(!isempty, readlines(path * ".idx")))
    b = vcat(a[2:end] .- 1, filesize(path) - 1)
    map(tuple, a, b)
end

@testset "GFS fixture" begin
    dir = joinpath(@__DIR__, "fixtures", "gfs", "gfs.20261108", "00", "atmos")
    @testset "$f" for (f, n) ∈ ("gfs.t00z.pgrb2.1p00.f000" => 2, "gfs.t00z.pgrb2.1p00.f006" => 5)
        path = joinpath(dir, f)
        r = _fixtureranges(path)
        @test length(r) == n
        data = read(path)
        foreach(r) do (a, b)
            bytes = data[a+1:b+1]
            GC.@preserve bytes begin
                m = GRIB.Message(bytes)
                @test size(m["values"]) == (360, 181)
                @test m["latitudeOfFirstGridPointInDegrees"] == 90
                @test m["longitudeOfFirstGridPointInDegrees"] == 0
            end
        end
    end
end
