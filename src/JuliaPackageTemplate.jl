module JuliaPackageTemplate

export greet, Config, transform, DEFAULT_GREETING

"""
    Config

Configuration for the package.

# Fields
- `name::String`: The name to use in greetings.
- `verbose::Bool`: Whether to print extra information.
"""
struct Config
    name::String
    verbose::Bool
end

"""
    greet()
    greet(name::String)

Return a greeting string. If `name` is provided, greet that person.

### Examples
```julia
julia> greet()
"Hello from JuliaPackageTemplate!"

julia> greet("Julia")
"Hello, Julia!"
```
"""
greet() = "Hello from JuliaPackageTemplate!"
greet(name::String) = "Hello, $name!"

"""
    transform(x::AbstractVector; scale=1.0)

Apply a transformation to `x`, scaling each element by `scale`.

### Examples
```julia
julia> transform([1, 2, 3]; scale=2.0)
3-element Vector{Float64}:
 2.0
 4.0
 6.0
```
"""
transform(x::AbstractVector; scale=1.0) = x .* scale

"""
    DEFAULT_GREETING

The default greeting string used by [`greet`](@ref).
"""
const DEFAULT_GREETING = "Hello from JuliaPackageTemplate!"

end # module
