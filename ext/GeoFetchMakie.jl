module GeoFetchMakie

using GeoFetch, Makie

#--------------------------------------------------------------------------------# ProjectPlot Recipe
@recipe(ProjectPlot, project) do scene
    Attributes(
        extent_color = (:dodgerblue, 0.15),
        extent_strokecolor = :dodgerblue,
        extent_strokewidth = 2,
    )
end

function Makie.plot!(p::ProjectPlot)
    proj = p[:project]
    rect = lift(proj) do pr
        ext = pr.extent
        x1, x2 = ext.X
        y1, y2 = ext.Y
        Point2f[(x1, y1), (x2, y1), (x2, y2), (x1, y2)]
    end
    poly!(p, rect;
        color = p[:extent_color],
        strokecolor = p[:extent_strokecolor],
        strokewidth = p[:extent_strokewidth],
    )
    return p
end

end # module GeoFetchMakie
