# openbao

## Purpose

Wrapper chart for `openbao` (`0.30.7` / `v2.7.2`) on `mgmt`. Runs the Istio multicluster mesh CA and, opt-in, the per-tenant secret backend (one root + intermediate PKI mount per `mesh.groups` entry with private keys generated inside OpenBao), per-member Kubernetes JWT auth, static auto-unseal via ESO, and a TLS-passthrough `Gateway`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openbao`).
- **Catalog label:** `addons.platform.koorikla.io/openbao` (`default: false`, opt-in via `installation.yaml` `mgmt.addons.openbao: "true"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admission.enabled | bool | `true` |  |
| admission.readerMaxDuration | string | `"168h"` |  |
| admission.readerNamespace | string | `"fleet"` |  |
| admission.readerUser | string | `"platform:istio-reader"` |  |
| admission.requestCreators[0] | string | `"system:serviceaccount:cert-manager:cert-manager"` |  |
| caPublic.namespaces[0] | string | `"fleet"` |  |
| caPublic.pkiReader | string | `"eso-openbao-pki-public"` |  |
| caPublic.secretName | string | `"openbao-ca-bundle"` |  |
| caPublic.store | string | `"mgmt-openbao"` | Publishes root/CA bundles (`caPublic.{store,secretName,namespaces}`) through `ClusterSecretStore/mgmt-openbao` to `fleet`. |
| cluster.name | string | `"mgmt"` |  |
| cluster.provider | string | `"docker"` |  |
| gateway.className | string | `"kgateway"` |  |
| gateway.loadBalancerSourceRanges | list | `[]` |  |
| gateway.name | string | `"openbao-gateway"` |  |
| installation.name | string | `"local"` |  |
| memberAuth.audience | string | `"vault://istio-system/openbao-mesh"` |  |
| memberAuth.policy | string | `"mesh-member"` |  |
| memberAuth.role | string | `"istio-csr"` |  |
| memberAuth.serviceAccount | string | `"istio-system:istio-csr-openbao"` |  |
| memberAuth.tokenTTL | string | `"10m"` |  |
| mesh.ca.host | string | `"openbao.openchoreo.localhost"` |  |
| mesh.ca.port | int | `8200` |  |
| mesh.groups | list | `[]` | Mesh groups (`mesh.{groups,ca.host,ca.port}`) reconciled into PKI mounts and the passthrough endpoint. |
| meshClients.label | string | `"mesh.platform.koorikla.io/openbao-client"` |  |
| meshClients.secretName | string | `"mesh-clients"` |  |
| meshClients.store | string | `"mgmt-fleet"` |  |
| openbao.csi.enabled | bool | `false` |  |
| openbao.global.tlsDisable | bool | `false` |  |
| openbao.injector.enabled | bool | `false` |  |
| openbao.server.auditStorage.enabled | bool | `false` |  |
| openbao.server.authDelegator.enabled | bool | `true` |  |
| openbao.server.dataStorage.enabled | bool | `true` |  |
| openbao.server.dataStorage.size | string | `"1Gi"` |  |
| openbao.server.extraEnvironmentVars.BAO_CACERT | string | `"/openbao/tls/ca.crt"` |  |
| openbao.server.extraEnvironmentVars.BAO_TLS_SERVER_NAME | string | `"openbao.openbao.svc"` |  |
| openbao.server.ha.enabled | bool | `true` |  |
| openbao.server.ha.raft.config | string | `"ui = false\nlistener \"tcp\" {\n  address            = \"[::]:8200\"\n  cluster_address    = \"[::]:8201\"\n  tls_cert_file      = \"/openbao/tls/tls.crt\"\n  tls_key_file       = \"/openbao/tls/tls.key\"\n  tls_min_version    = \"tls12\"\n  tls_auto_reload    = true\n}\nstorage \"raft\" {\n  path = \"/openbao/data\"\n  retry_join {\n    leader_api_addr     = \"https://openbao-0.openbao-internal:8200\"\n    leader_ca_cert_file = \"/openbao/tls/ca.crt\"\n  }\n}\nservice_registration \"kubernetes\" {}\n# Static auto-unseal (local backend). Production: seal \"awskms\" { ... } with workload identity.\nseal \"static\" {\n  current_key_id = \"platform-1\"\n  current_key    = \"file:///openbao/unseal/key\"\n}\naudit \"file\" \"stdout\" {\n  description = \"every request and response (HMAC'd secrets) to the container log\"\n  options {\n    file_path = \"stdout\"\n  }\n}\n# One-time self-initialisation (first start only; the root token is revoked afterwards and never returned).\n# Every mgmt identity and every non-tenant ACL policy is written HERE, once; later, only the policy\n# reconciler (below) may author policies, and only tenant-* ones (docs/multicluster.md \"Who may do what in\n# OpenBao\"). Identities (Kubernetes auth, projected tokens with\n# audience \"openbao\"; names == addon values reconcile.*, caPublic.pkiReader, contract test server_test.yaml):\n#   platform-mesh-bootstrap  SA openbao-mesh-bootstrap (Sync-hook Job only): group CAs. CA-equivalent - it\n#                            can sign an intermediate CSR with a group root - so it never runs on a schedule.\n#   platform-mesh-config     SAs openbao-mesh-config (CronJob) + openbao-mesh-bootstrap: member enrolment\n#                            (jwt mounts, PKI roles with pinned safety flags, identity entities). No key,\n#                            no signing, no policy writes.\n#   mesh-ca-read             SA eso-openbao-pki-public: the group roots' public certificates, plus the\n#                            token self-operations ESO's vault provider needs without the default policy\n#                            (lookup-self validates the SecretStore, revoke-self closes the client).\n# Members get the static templated policy mesh-member: sign on pki-mesh-<group>-int/sign/<cluster>, where\n# group/cluster are metadata of the identity entity mesh-<cluster> the reconcile binds to auth/mesh-<cluster>.\n# Changing these (non-tenant) policies later is an admin action (re-initialise) by design.\ninitialize \"kubernetes-auth\" {\n  request \"enable\" {\n    operation = \"update\"\n    path      = \"sys/auth/kubernetes\"\n    data = {\n      type        = \"kubernetes\"\n      description = \"mgmt ServiceAccounts (mesh reconcile, ESO public-certificate reader)\"\n    }\n  }\n  request \"config\" {\n    operation = \"update\"\n    path      = \"auth/kubernetes/config\"\n    data = {\n      kubernetes_host = \"https://kubernetes.default.svc\"\n    }\n  }\n}\ninitialize \"mesh-policies\" {\n  request \"member\" {\n    operation = \"update\"\n    path      = \"sys/policies/acl/mesh-member\"\n    data = {\n      policy = <<EOP\npath \"pki-mesh-{{ \"{{identity.entity.metadata.group}}\" }}-int/sign/{{ \"{{identity.entity.metadata.cluster}}\" }}\" { capabilities = [\"create\", \"update\"] }\nEOP\n    }\n  }\n  request \"ca-read\" {\n    operation = \"update\"\n    path      = \"sys/policies/acl/mesh-ca-read\"\n    data = {\n      policy = <<EOP\npath \"+/cert/ca\" { capabilities = [\"read\"] }\npath \"auth/token/lookup-self\" { capabilities = [\"read\"] }\npath \"auth/token/revoke-self\" { capabilities = [\"update\"] }\nEOP\n    }\n  }\n  request \"config\" {\n    operation = \"update\"\n    path      = \"sys/policies/acl/platform-mesh-config\"\n    data = {\n      policy = <<EOP\npath \"sys/auth\" { capabilities = [\"read\"] }\npath \"sys/auth/mesh-*\" {\n  capabilities       = [\"create\", \"read\", \"update\", \"delete\", \"sudo\"]\n  allowed_parameters = { \"*\" = [], \"type\" = [\"jwt\"] }\n  denied_parameters  = { \"plugin_name\" = [] }\n}\npath \"auth/mesh-*\" {\n  capabilities       = [\"create\", \"read\", \"update\", \"list\"]\n  allowed_parameters = { \"*\" = [], \"token_policies\" = [\"mesh-member\"] }\n  denied_parameters  = { \"policies\" = [] }\n}\npath \"+/roles/+\" {\n  capabilities        = [\"create\", \"read\", \"update\"]\n  required_parameters = [\"allow_any_name\", \"allow_ip_sans\", \"allow_localhost\", \"allow_subdomains\", \"allow_glob_domains\", \"allow_wildcard_certificates\", \"enforce_hostnames\", \"allowed_uri_sans_template\", \"allowed_other_sans\", \"code_signing_flag\", \"email_protection_flag\", \"no_store\", \"generate_lease\", \"issuer_ref\"]\n  allowed_parameters  = { \"*\" = [], \"allow_any_name\" = [\"false\"], \"allow_ip_sans\" = [\"false\"], \"allow_localhost\" = [\"false\"], \"allow_subdomains\" = [\"false\"], \"allow_glob_domains\" = [\"false\"], \"allow_wildcard_certificates\" = [\"false\"], \"enforce_hostnames\" = [\"true\"], \"allowed_uri_sans_template\" = [\"false\"], \"allowed_other_sans\" = [\"\"], \"code_signing_flag\" = [\"false\"], \"email_protection_flag\" = [\"false\"], \"no_store\" = [\"true\"], \"generate_lease\" = [\"false\"], \"issuer_ref\" = [\"default\"] }\n  denied_parameters   = { \"allowed_domains_template\" = [], \"ext_key_usage_oids\" = [], \"basic_constraints_valid_for_non_ca\" = [] }\n}\npath \"identity/entity/name/mesh-*\" {\n  capabilities       = [\"create\", \"read\", \"update\", \"delete\"]\n  allowed_parameters = { \"metadata\" = [] }\n}\npath \"identity/entity-alias\" {\n  capabilities       = [\"create\", \"update\"]\n  allowed_parameters = { \"name\" = [], \"canonical_id\" = [], \"mount_accessor\" = [] }\n}\npath \"+/root/sign-intermediate\" { capabilities = [\"deny\"] }\npath \"sys/mounts/*\" { capabilities = [\"deny\"] }\npath \"sys/policies/*\" { capabilities = [\"deny\"] }\npath \"sys/policy/*\" { capabilities = [\"deny\"] }\npath \"auth/kubernetes/*\" { capabilities = [\"deny\"] }\npath \"+/root/generate/exported\" { capabilities = [\"deny\"] }\npath \"+/intermediate/generate/exported\" { capabilities = [\"deny\"] }\npath \"+/issuers/generate/+/exported\" { capabilities = [\"deny\"] }\npath \"+/keys/*\" { capabilities = [\"deny\"] }\npath \"+/config/ca\" { capabilities = [\"deny\"] }\npath \"+/config/keys\" { capabilities = [\"deny\"] }\npath \"+/config/issuers\" { capabilities = [\"deny\"] }\npath \"+/issuers/import/*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+\" { capabilities = [\"deny\"] }\npath \"+/intermediate/cross-sign\" { capabilities = [\"deny\"] }\npath \"+/root/rotate/*\" { capabilities = [\"deny\"] }\npath \"+/root/replace\" { capabilities = [\"deny\"] }\npath \"+/root/sign-self-issued\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-self-issued\" { capabilities = [\"deny\"] }\npath \"+/sign-verbatim*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-verbatim*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-intermediate\" { capabilities = [\"deny\"] }\nEOP\n    }\n  }\n  request \"bootstrap\" {\n    operation = \"update\"\n    path      = \"sys/policies/acl/platform-mesh-bootstrap\"\n    data = {\n      policy = <<EOP\npath \"sys/mounts/pki-mesh-*\" {\n  capabilities       = [\"create\", \"read\", \"update\"]\n  allowed_parameters = { \"*\" = [], \"type\" = [\"pki\"] }\n  denied_parameters  = { \"plugin_name\" = [] }\n}\npath \"+/root/generate/internal\" { capabilities = [\"create\", \"update\"] }\npath \"+/intermediate/generate/internal\" { capabilities = [\"create\", \"update\"] }\npath \"+/root/sign-intermediate\" {\n  capabilities        = [\"create\", \"update\"]\n  required_parameters = [\"max_path_length\"]\n  allowed_parameters  = { \"*\" = [], \"max_path_length\" = [\"0\"] }\n}\npath \"+/intermediate/set-signed\" { capabilities = [\"create\", \"update\"] }\npath \"sys/policies/*\" { capabilities = [\"deny\"] }\npath \"sys/policy/*\" { capabilities = [\"deny\"] }\npath \"sys/auth/*\" { capabilities = [\"deny\"] }\npath \"auth/kubernetes/*\" { capabilities = [\"deny\"] }\npath \"+/root/generate/exported\" { capabilities = [\"deny\"] }\npath \"+/intermediate/generate/exported\" { capabilities = [\"deny\"] }\npath \"+/issuers/generate/+/exported\" { capabilities = [\"deny\"] }\npath \"+/keys/*\" { capabilities = [\"deny\"] }\npath \"+/config/ca\" { capabilities = [\"deny\"] }\npath \"+/config/keys\" { capabilities = [\"deny\"] }\npath \"+/config/issuers\" { capabilities = [\"deny\"] }\npath \"+/issuers/import/*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+\" { capabilities = [\"deny\"] }\npath \"+/intermediate/cross-sign\" { capabilities = [\"deny\"] }\npath \"+/root/rotate/*\" { capabilities = [\"deny\"] }\npath \"+/root/replace\" { capabilities = [\"deny\"] }\npath \"+/root/sign-self-issued\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-self-issued\" { capabilities = [\"deny\"] }\npath \"+/sign-verbatim*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-verbatim*\" { capabilities = [\"deny\"] }\npath \"+/issuer/+/sign-intermediate\" { capabilities = [\"deny\"] }\nEOP\n    }\n  }\n}\ninitialize \"mesh-roles\" {\n  request \"config\" {\n    operation = \"update\"\n    path      = \"auth/kubernetes/role/platform-mesh-config\"\n    data = {\n      bound_service_account_names      = [\"openbao-mesh-config\", \"openbao-mesh-bootstrap\"]\n      bound_service_account_namespaces = [\"openbao\"]\n      audience                         = \"openbao\"\n      token_policies                   = [\"platform-mesh-config\"]\n      token_no_default_policy          = true\n      token_ttl                        = \"15m\"\n      token_max_ttl                    = \"15m\"\n    }\n  }\n  request \"bootstrap\" {\n    operation = \"update\"\n    path      = \"auth/kubernetes/role/platform-mesh-bootstrap\"\n    data = {\n      bound_service_account_names      = [\"openbao-mesh-bootstrap\"]\n      bound_service_account_namespaces = [\"openbao\"]\n      audience                         = \"openbao\"\n      token_policies                   = [\"platform-mesh-bootstrap\"]\n      token_no_default_policy          = true\n      token_ttl                        = \"15m\"\n      token_max_ttl                    = \"15m\"\n    }\n  }\n  request \"ca-read\" {\n    operation = \"update\"\n    path      = \"auth/kubernetes/role/mesh-ca-read\"\n    data = {\n      bound_service_account_names      = [\"eso-openbao-pki-public\"]\n      bound_service_account_namespaces = [\"openbao\"]\n      audience                         = \"openbao\"\n      token_policies                   = [\"mesh-ca-read\"]\n      token_no_default_policy          = true\n      token_ttl                        = \"10m\"\n      token_max_ttl                    = \"10m\"\n    }\n  }\n}\n# Policy reconciler (docs/multicluster.md \"Policies from git: the policy reconciler\"): the only identity that\n# may write ACL policies after this first start, and only policies named tenant-* (files/policies/, CronJob\n# policy-reconcile) plus the two Kubernetes auth roles of the tenant identities with every parameter pinned\n# (it cannot bind a role to its own ServiceAccount nor attach any other policy). No root, no PKI, no mesh, no\n# secret, no auth method, no identity. Policies of other names (mesh-*, platform-*) stay self-init only:\n# whoever may write those is CA-equivalent or could rewrite this policy. Nothing can mint a root token later\n# (self-initialisation creates no recovery keys; task test:openbao proves root token generation fails).\ninitialize \"policy-reconciler\" {\n  request \"policy\" {\n    operation = \"update\"\n    path      = \"sys/policies/acl/platform-policy-reconciler\"\n    data = {\n      policy = <<EOP\npath \"sys/policies/acl\" { capabilities = [\"list\"] }\npath \"sys/policies/acl/tenant-*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }\npath \"auth/kubernetes/role/tenant-config\" {\n  capabilities        = [\"create\", \"update\"]\n  required_parameters = [\"bound_service_account_names\", \"bound_service_account_namespaces\", \"audience\", \"token_policies\", \"token_no_default_policy\", \"token_ttl\", \"token_max_ttl\"]\n  allowed_parameters  = { \"bound_service_account_names\" = [\"openbao-tenant-config\"], \"bound_service_account_namespaces\" = [\"openbao\"], \"audience\" = [\"openbao\"], \"token_policies\" = [\"tenant-config\"], \"token_no_default_policy\" = [\"true\"], \"token_ttl\" = [\"15m\"], \"token_max_ttl\" = [\"15m\"] }\n}\npath \"auth/kubernetes/role/tenant-writer\" {\n  capabilities        = [\"create\", \"update\"]\n  required_parameters = [\"bound_service_account_names\", \"bound_service_account_namespaces\", \"alias_name_source\", \"audience\", \"token_policies\", \"token_no_default_policy\", \"token_ttl\", \"token_max_ttl\"]\n  allowed_parameters  = { \"bound_service_account_names\" = [\"*\"], \"bound_service_account_namespaces\" = [\"openbao-tenants\"], \"alias_name_source\" = [\"serviceaccount_name\"], \"audience\" = [\"openbao\"], \"token_policies\" = [\"tenant-write\"], \"token_no_default_policy\" = [\"true\"], \"token_ttl\" = [\"15m\"], \"token_max_ttl\" = [\"15m\"] }\n}\npath \"auth/token/revoke-self\" { capabilities = [\"update\"] }\npath \"sys/policies/acl/platform-*\" { capabilities = [\"deny\"] }\npath \"sys/policies/acl/mesh-*\" { capabilities = [\"deny\"] }\npath \"sys/policy/*\" { capabilities = [\"deny\"] }\npath \"sys/mounts/*\" { capabilities = [\"deny\"] }\npath \"sys/auth/*\" { capabilities = [\"deny\"] }\npath \"auth/kubernetes/config\" { capabilities = [\"deny\"] }\npath \"auth/kubernetes/role/platform-*\" { capabilities = [\"deny\"] }\npath \"auth/kubernetes/role/mesh-*\" { capabilities = [\"deny\"] }\npath \"identity/*\" { capabilities = [\"deny\"] }\npath \"kv-tenant-*\" { capabilities = [\"deny\"] }\npath \"pki-*\" { capabilities = [\"deny\"] }\nEOP\n    }\n  }\n  request \"role\" {\n    operation = \"update\"\n    path      = \"auth/kubernetes/role/platform-policy-reconciler\"\n    data = {\n      bound_service_account_names      = [\"openbao-policy-reconciler\"]\n      bound_service_account_namespaces = [\"openbao\"]\n      audience                         = \"openbao\"\n      token_policies                   = [\"platform-policy-reconciler\"]\n      token_no_default_policy          = true\n      token_ttl                        = \"5m\"\n      token_max_ttl                    = \"5m\"\n    }\n  }\n}\n"` |  |
| openbao.server.ha.raft.enabled | bool | `true` |  |
| openbao.server.ha.raft.setNodeId | bool | `true` |  |
| openbao.server.ha.replicas | int | `1` |  |
| openbao.server.image.registry | string | `"quay.io"` |  |
| openbao.server.image.repository | string | `"openbao/openbao"` |  |
| openbao.server.image.tag | string | `"2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f"` |  |
| openbao.server.logLevel | string | `"info"` |  |
| openbao.server.resources.limits.memory | string | `"256Mi"` |  |
| openbao.server.resources.requests.cpu | string | `"50m"` |  |
| openbao.server.resources.requests.memory | string | `"128Mi"` |  |
| openbao.server.standalone.enabled | bool | `false` |  |
| openbao.server.statefulSet.securityContext.container.allowPrivilegeEscalation | bool | `false` |  |
| openbao.server.statefulSet.securityContext.container.capabilities.drop[0] | string | `"ALL"` |  |
| openbao.server.statefulSet.securityContext.container.readOnlyRootFilesystem | bool | `true` |  |
| openbao.server.statefulSet.securityContext.pod.fsGroup | int | `1000` |  |
| openbao.server.statefulSet.securityContext.pod.runAsGroup | int | `1000` |  |
| openbao.server.statefulSet.securityContext.pod.runAsNonRoot | bool | `true` |  |
| openbao.server.statefulSet.securityContext.pod.runAsUser | int | `100` |  |
| openbao.server.statefulSet.securityContext.pod.seccompProfile.type | string | `"RuntimeDefault"` |  |
| openbao.server.updateStrategyType | string | `"RollingUpdate"` |  |
| openbao.server.volumeMounts[0].mountPath | string | `"/openbao/tls"` |  |
| openbao.server.volumeMounts[0].name | string | `"tls"` |  |
| openbao.server.volumeMounts[0].readOnly | bool | `true` |  |
| openbao.server.volumeMounts[1].mountPath | string | `"/openbao/unseal"` |  |
| openbao.server.volumeMounts[1].name | string | `"unseal"` |  |
| openbao.server.volumeMounts[1].readOnly | bool | `true` |  |
| openbao.server.volumeMounts[2].mountPath | string | `"/tmp"` |  |
| openbao.server.volumeMounts[2].name | string | `"tmp"` |  |
| openbao.server.volumes[0].name | string | `"tls"` |  |
| openbao.server.volumes[0].secret.defaultMode | int | `288` |  |
| openbao.server.volumes[0].secret.secretName | string | `"openbao-tls"` |  |
| openbao.server.volumes[1].name | string | `"unseal"` |  |
| openbao.server.volumes[1].secret.defaultMode | int | `288` |  |
| openbao.server.volumes[1].secret.items[0].key | string | `"key"` |  |
| openbao.server.volumes[1].secret.items[0].path | string | `"key"` |  |
| openbao.server.volumes[1].secret.secretName | string | `"openbao-unseal"` |  |
| openbao.server.volumes[2].emptyDir.sizeLimit | string | `"16Mi"` |  |
| openbao.server.volumes[2].name | string | `"tmp"` |  |
| openbao.ui.enabled | bool | `false` |  |
| pki.allowedDomains[0] | string | `"istiod.istio-system.svc"` |  |
| pki.allowedDomains[1] | string | `"cert-manager-istio-csr.istio-system.svc"` |  |
| pki.intermediateKeyBits | int | `256` |  |
| pki.intermediateTTL | string | `"43800h"` |  |
| pki.keyType | string | `"ec"` |  |
| pki.rootKeyBits | int | `384` |  |
| pki.rootTTL | string | `"87600h"` |  |
| pki.trustDomain | string | `"cluster.local"` | X.509 constraints (`pki.{trustDomain,allowedDomains,workloadTTL,rootTTL,intermediateTTL}`: `cluster.local`, `24h` leaf TTL). |
| pki.workloadMaxTTL | string | `"48h"` |  |
| pki.workloadTTL | string | `"24h"` |  |
| policyReconciler.loginRole | string | `"platform-policy-reconciler"` |  |
| policyReconciler.roleTTL | string | `"15m"` |  |
| policyReconciler.serviceAccount | string | `"openbao-policy-reconciler"` | ServiceAccount, `loginRole`, and pinned `roleTTL` of the policy reconciler (must equal the self-init pins). |
| reconcile.audience | string | `"openbao"` |  |
| reconcile.bootstrapLoginRole | string | `"platform-mesh-bootstrap"` |  |
| reconcile.bootstrapServiceAccount | string | `"openbao-mesh-bootstrap"` |  |
| reconcile.loginRole | string | `"platform-mesh-config"` |  |
| reconcile.resources.limits.cpu | string | `"200m"` |  |
| reconcile.resources.limits.memory | string | `"64Mi"` |  |
| reconcile.resources.requests.cpu | string | `"10m"` |  |
| reconcile.resources.requests.memory | string | `"32Mi"` |  |
| reconcile.schedule | string | `"*/5 * * * *"` |  |
| reconcile.serviceAccount | string | `"openbao-mesh-config"` |  |
| secrets.tenantStores.enabled | bool | `false` | Enables per-tenant KV v2 mounts `kv-tenant-<tenant>`, JWT auth `tenants-<cluster>` per mesh member, and CronJobs `tenant-reconcile` (`tenantSecrets.*`) and `policy-reconcile` ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao), [policy reconciler](../../docs/multicluster.md#policies-from-git-the-policy-reconciler)). |
| tenantSecrets.audience | string | `"openbao-tenant-secrets"` |  |
| tenantSecrets.inputsNamespace | string | `"openbao-tenants"` |  |
| tenantSecrets.label | string | `"openbao.platform.koorikla.io/tenant"` |  |
| tenantSecrets.loginRole | string | `"tenant-config"` |  |
| tenantSecrets.readerPolicy | string | `"tenant-read"` |  |
| tenantSecrets.readerServiceAccount | string | `"openbao-tenant"` |  |
| tenantSecrets.schedule | string | `"*/5 * * * *"` |  |
| tenantSecrets.secretName | string | `"tenant-clients"` |  |
| tenantSecrets.serviceAccount | string | `"openbao-tenant-config"` |  |
| tenantSecrets.tokenTTL | string | `"10m"` |  |
| tls.caDuration | string | `"87600h"` |  |
| tls.caIssuer | string | `"openbao-ca"` |  |
| tls.duration | string | `"2160h"` |  |
| tls.renewBefore | string | `"720h"` |  |
| tls.secretName | string | `"openbao-tls"` |  |
| unseal.property | string | `"key"` |  |
| unseal.remoteKey | string | `"openbao-unseal"` |  |
| unseal.secretName | string | `"openbao-unseal"` |  |
| unseal.store | string | `"platform"` | Pulls `openbao-unseal` (`unseal.{store,remoteKey,secretName}`) from `ClusterSecretStore/platform` for static auto-unseal. |

## Day-2 notes

- Raft backup/restore, sealed recovery, and local re-init: [backup and restore](../../docs/runbooks/backup-restore.md#3-openbao-raft-storage-and-unseal-key), [incidents](../../docs/runbooks/incidents.md#openbao-sealed), and [break-glass](../../docs/runbooks/break-glass.md#openbao-local-re-initialization).
- Mesh CA rotation: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#2-openbao-mesh-ca-openbao--mesh).

## Links

- [Multicluster: Mesh CA (OpenBao)](../../docs/multicluster.md#mesh-ca-openbao)