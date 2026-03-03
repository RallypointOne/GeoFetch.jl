using WeatherData
using Test

@testset "WeatherData.jl" begin
    @test WeatherData.greet() == "Hello from WeatherData!"
end
