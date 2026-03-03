[![CI](https://github.com/RallypointOne/JuliaPackageTemplate.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/RallypointOne/JuliaPackageTemplate.jl/actions/workflows/CI.yml)
[![Docs Build](https://github.com/RallypointOne/JuliaPackageTemplate.jl/actions/workflows/Docs.yml/badge.svg)](https://github.com/RallypointOne/JuliaPackageTemplate.jl/actions/workflows/Docs.yml)
[![Stable Docs](https://img.shields.io/badge/docs-stable-blue)](https://RallypointOne.github.io/JuliaPackageTemplate.jl/stable/)
[![Dev Docs](https://img.shields.io/badge/docs-dev-blue)](https://RallypointOne.github.io/JuliaPackageTemplate.jl/dev/)

# JuliaPackageTemplate.jl

A template for generating Julia packages developed by Rallypoint One.  Features:

- Docs built via [quarto](https://quarto.org), deployed via GitHub Action
- Versioned docs
- Coverage report hosted alongside docs, built with [LocalCoverage](https://github.com/JuliaCI/LocalCoverage.jl)
- A thoughtful CLAUDE.md for AI-assisted development
- Rallypoint One branding/styles

## Docs Structure (gh-pages)

After several releases, the `gh-pages` branch will have this structure:

```
gh-pages/
├── .nojekyll
├── index.html              # redirect → /RepoName/stable/
├── versions.json           # ["v1.0.0", "v0.2.0", "v0.1.0"]
├── stable/
│   └── index.html          # redirect → /RepoName/<latest tag>/
├── dev/
│   └── <full quarto site>  # rebuilt on every push to main
├── v0.1.0/
│   └── <full quarto site>  # built on release publish
├── v0.2.0/
│   └── <full quarto site>
└── v1.0.0/
    └── <full quarto site>
```

- **`/`** redirects to **`/stable/`**
- **`/stable/`** redirects to the latest release tag
- **`/dev/`** is rebuilt on every push to `main`
- **`/vX.Y.Z/`** directories are created on each release
- **`versions.json`** tracks all released versions, sorted by semver descending
- Before any release exists, `/stable/` shows a placeholder page linking to `/dev/`
