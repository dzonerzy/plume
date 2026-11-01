# Project templates

What `plume init` writes, embedded in the plume tool at its build:

- `base/`: every project's files (plume.json, package.json, build.zig, src/).
- `vanilla/`, `react/`, `svelte/`, `vue/`: each template's `frontend/`.

In file contents, `{{name}}`, `{{title}}`, `{{app_id}}` and `{{plume_dependency}}`
are replaced when the project is written.
