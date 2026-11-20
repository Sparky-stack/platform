# PostgreSQL Composition fixtures

Inputs of `hack/tests/test_crossplane_render.sh`: per backend the addon values that select it (`values-<backend>.yaml`,
sample cluster facts) and the observed state of the composed resources once the cloud reports endpoints
(`observed-<backend>.yaml`), which drives the second render stage (connection Secret + XR status). The sample
`PostgreSQL` XRs are the package's own `packages/postgresql/examples/xr-*.yaml`.
All ids are fake (TEST-NET addresses, 111111111111 accounts, example names).
