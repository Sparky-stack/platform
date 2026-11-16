# PostgreSQL Composition fixtures

Inputs of `hack/tests/test_crossplane_render.sh`: per backend the addon values that select it (`values-<backend>.yaml`,
sample cluster facts), sample `PostgreSQL` XRs (`xr-*.yaml`) and the observed state of the composed resources once the
cloud reports endpoints (`observed-<backend>.yaml`), which drives the second render stage (connection Secret + XR status).
All ids are fake (TEST-NET addresses, 111111111111 accounts, example names).
