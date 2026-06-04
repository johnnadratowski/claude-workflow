---
layout: default
title: API Reference
---

# API Reference

> **⚠ This page ships with the template for projects that expose an HTTP/REST API.**
> It renders an OpenAPI spec (`swagger.json`) generated from in-code annotations.
> **If your project has no API surface, delete this file** (`docs/api.md`) and
> `docs/swagger.json` — the `/base-initialize` skill does this automatically when you
> answer "no API". If you keep it, replace the generation command below with your stack's.

Every endpoint, its request shape, and its response codes — **generated** from the API
annotations in the source (do not hand-edit `swagger.json`).

## Regenerating the spec

The OpenAPI spec is generated from annotations in the route handlers (e.g. `@swagger`
JSDoc with `swagger-jsdoc`, FastAPI's built-in `/openapi.json`, springdoc, etc. — whatever
your stack uses). Wire a script that writes `docs/swagger.json` and run it whenever a route
changes — this is part of the **doc-sync** step (see the `/todo` skill) and a `/base-pr`
doc-drift check. Example wiring (replace with your stack's command):

```bash
# e.g. a Node script that dumps the in-process OpenAPI spec to docs/swagger.json
node scripts/dump-swagger.mjs
```

Commit the regenerated `docs/swagger.json` alongside the route change. Consider a CI
drift-guard (regenerate + `git diff --exit-code docs/swagger.json`) so a stale spec fails
the build.

## Live API explorer

This page mounts [Swagger UI](https://github.com/swagger-api/swagger-ui) against the
generated `swagger.json`. (Hardening note: for a public site, pin the Swagger UI dist to a
fixed version and add `integrity="sha384-…" crossorigin="anonymous"` to the script/style
tags, or vendor the assets locally, rather than loading `@latest` from a CDN.)

<div id="swagger-ui"></div>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css" />
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>
  window.addEventListener('load', () => {
    window.ui = SwaggerUIBundle({
      url: '{{ "/swagger.json" | relative_url }}',
      dom_id: '#swagger-ui',
      deepLinking: true,
      presets: [SwaggerUIBundle.presets.apis],
      layout: 'BaseLayout',
      docExpansion: 'list',
    })
  })
</script>
