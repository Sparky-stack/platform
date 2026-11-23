---
title: OpenChoreo Console - Catalog Opens on Projects; Templates Need spec.type Component
created: 2026-11-23
updated: 2026-11-23
type: gotcha
tags: [openchoreo, upstream]
confidence: high
---

# OpenChoreo Console - Catalog Opens on Projects; Templates Need spec.type Component

## Symptom
- "No components or resources in the console", even though the Backstage catalog DB holds `Component/hello-world`,
  `Resource/orders-db`, both ClusterResourceTypes and every golden-path Template, with no refresh errors.
- The golden-path service templates (docker, go, java-quarkus, node-fastify, python, rust) are missing from
  *Create* > *Component* and from a project's *Create Component* button.
- Backstage logs `Thunder IDP not configured (thunder.baseUrl missing) - skipping user/group sync`. It looks like the
  cause, but it is not.

## Cause (openchoreo-ui / backstage-plugins v1.3.3)
- `packages/portal-app/src/apis/customOverrides.tsx:196` mounts `CustomCatalogPage initialKind="system"`. The catalog
  opens on Projects and has only a *Kind* picker, with no *Owned* / *All* filter (nothing in portal-app uses
  `UserListPicker` or `ownedBy`). Components and resources are one *Kind* switch away.
- Visibility is decided by `permission-backend-module-openchoreo-policy`
  (`OpenChoreoPermissionPolicy.ts` handleCatalogPermission -> `matchesCatalogEntityCapability`). It checks only
  OpenChoreo capabilities from `/authz/profile`, which come from the token's `groups` claim. Ownership plays no part.
  The sign-in resolver (`auth-backend-module-openchoreo-auth/src/auth.ts:112`) builds `user:default/<email>` without
  a catalog User entity.
- `CustomTemplateListPage.tsx:298` lists only `spec.type === 'Component'` under Create > Component. Other types go to
  *Other Templates*. `openchoreo-react/src/routing/pathBuilders.ts:114` (project *Create Component*) also adds
  `filters[type]=component` and `filters[namespace]=<project ns>,openchoreo-cluster`.
- The upstream chart never sets `THUNDER_BASE_URL`. The Thunder provider (`thunder-idp-client-node/src/factory.ts:144`)
  takes only a static bearer `thunder.token`, and the entity names it builds (`admin-openchoreo-dev`, members by user
  ID) do not match the sign-in refs.

## Fix
- Service templates use `spec.type: Component` and keep the Backstage namespace `default` (= the OpenChoreo org
  namespace). `crossplane-api` stays `platform-api` and appears under Other Templates.
- Leave the Thunder sync off. Point people to the Kind picker or to deep links such as
  `/catalog?filters[kind]=component`.

## Where enforced
- `hack/tests/test_project_templates.sh` (the type and namespace of every service template).
- [docs/openchoreo.md "Finding things in the console"](../../docs/openchoreo.md#finding-things-in-the-console).

## Links
- Related: [OpenChoreo authz per project](openchoreo-authz-per-project-developers.md),
  [OpenChoreo SDLC and promotion flow](../concepts/openchoreo-sdlc-and-promotion-flow.md).
- [docs/project-templates.md](../../docs/project-templates.md).
