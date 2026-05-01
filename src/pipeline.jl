# The Stage hierarchy + Pipeline type. A Pipeline is just an ordered list of
# Stages — building one is value-level only, no I/O. Execution happens in
# `execute.jl`.

#-----------------------------------------------------------------------------# Stage hierarchy
# Every node in a pipeline is a `Stage`. The three subkinds correspond to
# the three roles a stage can play. A well-formed pipeline starts with one
# Source, ends with one Sink, and has zero or more Transforms in between.
abstract type Stage end
abstract type Source <: Stage end
abstract type Transform <: Stage end
abstract type Sink <: Stage end

# Source interface: every Source must expose its `SourceSchema` and a list
# of `FetchUnit`s. The default implementation reads them from struct fields
# of the same names; concrete sources can override these methods if they
# compute the schema/units lazily.
schema(s::Source) = s.schema
units(s::Source) = s.units

#-----------------------------------------------------------------------------# Pipeline
# A linear sequence of stages. We don't model branching DAGs yet — a
# pipeline is one source feeding one chain of transforms feeding one sink.
struct Pipeline
    stages::Vector{Stage}
end

Pipeline(s::Stage) = Pipeline(Stage[s])

# `|` is overloaded as the pipeline-build operator. Each combination either
# starts a new Pipeline (Stage | Stage) or extends/merges existing ones.
# This is bitwise-or, not Julia's `|>` pipe — we picked it because it reads
# closer to a shell pipeline than `|>` does.
Base.:|(a::Stage, b::Stage)         = Pipeline(Stage[a, b])
Base.:|(p::Pipeline, b::Stage)      = Pipeline(Stage[p.stages..., b])
Base.:|(a::Stage, p::Pipeline)      = Pipeline(Stage[a, p.stages...])
Base.:|(p1::Pipeline, p2::Pipeline) = Pipeline(Stage[p1.stages..., p2.stages...])

# Convenience accessors. `transforms_of` is a view, not a copy, since it's
# only iterated.
source(p::Pipeline) = p.stages[1]
sink(p::Pipeline) = p.stages[end]
transforms_of(p::Pipeline) = @view p.stages[2:end-1]

function Base.show(io::IO, ::MIME"text/plain", p::Pipeline)
    print(io, "Pipeline ($(length(p.stages)) stages)")
    for (i, s) in enumerate(p.stages)
        print(io, "\n  $i. ")
        show(io, s)
    end
end

Base.show(io::IO, p::Pipeline) = print(io, "Pipeline($(length(p.stages)) stages)")
