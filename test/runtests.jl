using JuliaPackageTemplate
using Test

@testset "JuliaPackageTemplate.jl" begin
    @test JuliaPackageTemplate.greet() == "Hello from JuliaPackageTemplate!"
end
