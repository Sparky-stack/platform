# Changelog

Platform releases (`vX.Y.Z`), maintained by release-please ([docs/releases.md](docs/releases.md)).

## [0.2.0](https://github.com/koorikla/platform/compare/v0.1.0...v0.2.0) (2026-11-19)


### ⚠ BREAKING CHANGES

* **platform:** remove examples/ (east-west custom chart); apps ship as OpenChoreo objects ([#234](https://github.com/koorikla/platform/issues/234))

### Features

* **apps:** resilience defaults for OpenChoreo components - spread, PDB, graceful shutdown, priority; production enforcement ([#251](https://github.com/koorikla/platform/issues/251)) ([#264](https://github.com/koorikla/platform/issues/264)) ([a54aec7](https://github.com/koorikla/platform/commit/a54aec79c1c24c3d958adbfb2b7ba4ec85330f4f))
* **ci:** scope PR validation to changed charts, addons, packages and ci stacks ([#242](https://github.com/koorikla/platform/issues/242)) ([6a6038a](https://github.com/koorikla/platform/commit/6a6038a505ece84cea64a07d2910126729c4870f))
* **crossplane:** layout-only Configuration packages for MySQL, Valkey, Bucket, KafkaTopic (Refs [#241](https://github.com/koorikla/platform/issues/241)) ([#260](https://github.com/koorikla/platform/issues/260)) ([91ad14b](https://github.com/koorikla/platform/commit/91ad14b89de78bd1fbc1df641574aed10222986c))
* **crossplane:** pin the split postgresql Configuration and its embedded function compose-postgresql (Refs [#116](https://github.com/koorikla/platform/issues/116)) ([#272](https://github.com/koorikla/platform/issues/272)) ([e009b04](https://github.com/koorikla/platform/commit/e009b044644b889f9f76590463f54e6647927956))
* **postgresql:** Crossplane Configuration package for the PostgreSQL API ([#239](https://github.com/koorikla/platform/issues/239)) ([7dad12e](https://github.com/koorikla/platform/commit/7dad12e3309ff0b73b0dd1ed3c235f48c71c6d0c))
* release-please with two release lines, platform vX.Y.Z and ci ci-vX.Y.Z ([#222](https://github.com/koorikla/platform/issues/222)) ([dd28954](https://github.com/koorikla/platform/commit/dd2895422477b97c43c0dc1c64e8e9ac6e70712d))
* **secrets:** app secrets from OpenBao via OpenChoreo SecretReference, demo-check + negatives + docs ([#250](https://github.com/koorikla/platform/issues/250)) ([#262](https://github.com/koorikla/platform/issues/262)) ([e14372a](https://github.com/koorikla/platform/commit/e14372aded430bebc67e905861baf4563781c45a))


### Bug Fixes

* **apps:** app PriorityClasses never preempt platform pods ([#276](https://github.com/koorikla/platform/issues/276)) ([#279](https://github.com/koorikla/platform/issues/279)) ([45aafff](https://github.com/koorikla/platform/commit/45aafff3687c4f015d5e9742703e74fb20de6c9c))
* **argocd:** Argo CD detects changes to hook-rendered config (thunder-bootstrap ExternalSecret, authz bootstrap) ([#221](https://github.com/koorikla/platform/issues/221)) ([#278](https://github.com/koorikla/platform/issues/278)) ([4dd400f](https://github.com/koorikla/platform/commit/4dd400f8e4dce049d8d5c05c2e3351ee46ecdd1a))
* **argocd:** detect Argo Workflows spec changes under server-side diff ([#184](https://github.com/koorikla/platform/issues/184)) ([#273](https://github.com/koorikla/platform/issues/273)) ([0a5d2f4](https://github.com/koorikla/platform/commit/0a5d2f45a27725fc9c362d80ed5128914f5d16f0))
* **ci:** docs changes run the tests that read them ([#253](https://github.com/koorikla/platform/issues/253)) ([#261](https://github.com/koorikla/platform/issues/261)) ([39599e7](https://github.com/koorikla/platform/commit/39599e7ad65258a8d989f9e28fcb8d514bf78b3c))
* **ci:** docs read through a path prefix also select their tests ([#277](https://github.com/koorikla/platform/issues/277)) ([#280](https://github.com/koorikla/platform/issues/280)) ([3a4738b](https://github.com/koorikla/platform/commit/3a4738bb8d5b49a2e4ee7a7f8a91c14c2d5e6fae))
* **ci:** publish toolbox and selftest packages under ghcr.io/koorikla/platform; toolbox tags on ci-v* ([#254](https://github.com/koorikla/platform/issues/254)) ([#263](https://github.com/koorikla/platform/issues/263)) ([db7bcac](https://github.com/koorikla/platform/commit/db7bcac349534a2429809c6744816e0800e2a457))
* **cluster:** byo unittests point at templates/common paths; contract test rejects stale unittest template paths ([#236](https://github.com/koorikla/platform/issues/236)) ([#238](https://github.com/koorikla/platform/issues/238)) ([474e8af](https://github.com/koorikla/platform/commit/474e8af27553368b262f7fc5d10318edb53bd38d))
* **crossplane:** package signature verification off until Crossplane reads Sigstore bundles ([#247](https://github.com/koorikla/platform/issues/247)) ([#248](https://github.com/koorikla/platform/issues/248)) ([020fbc0](https://github.com/koorikla/platform/commit/020fbc0658edf9eb3cf1b7659558209a41664d01))
* **openchoreo-data-plane:** gate the agent on every addon CRD traits and resource types render ([#255](https://github.com/koorikla/platform/issues/255)) ([#265](https://github.com/koorikla/platform/issues/265)) ([d2a68a1](https://github.com/koorikla/platform/commit/d2a68a1c570b26a3106d01f23c3060ddba5715dc))
* **openchoreo-data-plane:** start the cluster agent only after opt-in addon CRDs exist ([#246](https://github.com/koorikla/platform/issues/246)) ([#249](https://github.com/koorikla/platform/issues/249)) ([e57329f](https://github.com/koorikla/platform/commit/e57329f7f91e54e7ef9f1cb29784258c192676c8))
* QA findings - pin app-* workflow actions by SHA, repoint ci/ templates, live Rust toolchain check, mcp-service tests ([#226](https://github.com/koorikla/platform/issues/226), [#227](https://github.com/koorikla/platform/issues/227)) ([#228](https://github.com/koorikla/platform/issues/228)) ([c760dc6](https://github.com/koorikla/platform/commit/c760dc6157c582f3a7a983a76de7a2ce178251f3))
* **workflow-plane:** pin the toolbox to ghcr.io/koorikla/platform/ci-toolbox ([#254](https://github.com/koorikla/platform/issues/254)) ([#271](https://github.com/koorikla/platform/issues/271)) ([c945e4d](https://github.com/koorikla/platform/commit/c945e4dda5f18ef20d06ffbb9ba60f49d09e62d5))


### Performance Improvements

* **bootstrap:** clean bootstrap 33 -&gt; ~15 min warm (registry caches, 1m backoff, 120s resync, task timings) ([#266](https://github.com/koorikla/platform/issues/266)) ([018a996](https://github.com/koorikla/platform/commit/018a996d87db3d87c0a737709a997b2fb8f81697))


### Code Refactoring

* **platform:** remove examples/ (east-west custom chart); apps ship as OpenChoreo objects ([#234](https://github.com/koorikla/platform/issues/234)) ([5a13e94](https://github.com/koorikla/platform/commit/5a13e9449859703466d97105892ea5731811a978))

## 0.1.0 (2026-11-18)

First tagged release: CAPI + Argo CD + OpenChoreo + ESO platform lab (see [README.md](README.md)).
