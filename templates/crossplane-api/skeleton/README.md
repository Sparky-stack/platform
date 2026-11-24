# ${{ values.name }}

${{ values.description }}

A platform API as a Crossplane Configuration package, laid out by `crossplane project init` (Crossplane CLI 2.4
Project tooling, beta) and scaffolded from the Sparky-stack/platform `crossplane-api` golden path:

| Path | What |
|---|---|
| `crossplane-project.yaml` | Project: package name, repository `ghcr.io/${{ values.imageOwner }}/${{ values.name }}`, dependencies |
| `apis/api/definition.yaml` | the XRD: `${{ values.kind }}` (`${{ values.group }}/v1alpha1`, namespaced) |
| `apis/api/composition.yaml` | the Composition: embedded function `compose`, then function-auto-ready |
| `functions/compose/` | embedded function-go-templating function, one file per composed resource |
| `examples/` | sample XRs, rendered by CI |
| `tests/`, `operations/` | render fixtures (`tests/render/expected/<example>`), Operations |

## Inner loop

```bash
mise install                                          # the pinned Crossplane CLI (mise.toml)
mise exec -- crossplane xrd generate examples/example.yaml --path apis/api/definition.yaml   # after changing the XR shape
mise exec -- crossplane dependency add 'xpkg.crossplane.io/crossplane-contrib/provider-aws-s3:>=v2.9.0'   # + schemas/
mise exec -- crossplane composition render examples/example.yaml apis/api/composition.yaml   # builds functions/compose
mise exec -- crossplane project build                 # _output/${{ values.name }}.xpkg
mise exec -- crossplane project run                   # optional: local dev control plane (KIND), `project stop`
```

The full loop and how it relates to the platform's k3d stack: Sparky-stack/platform `docs/crossplane.md` ("Inner loop").

## CI

`.github/workflows/ci.yaml` calls Sparky-stack/platform `app-crossplane-configuration.yaml` (pinned by SHA): PRs validate
and render every example (diffed against `tests/render/expected/<example>` when present); pushes to `main` and `v*`
tags build, push, sign (cosign keyless) and attest the Configuration and the embedded function.

## Installing it

A cluster installs the package through Sparky-stack/platform `addons/crossplane` (pinned by digest, dependency resolution
off). Composing plain Kubernetes kinds (the sample ConfigMap) needs a ClusterRole labelled
`rbac.crossplane.io/aggregate-to-crossplane: "true"` there.
