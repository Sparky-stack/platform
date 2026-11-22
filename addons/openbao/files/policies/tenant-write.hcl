# Writers (Kubernetes auth role tenant-writer: ServiceAccounts openbao-tenants/<tenant>-writer on mgmt): write
# kv-tenant-<tenant> of the caller's own entity only. Metadata create/update: ESO's PushSecret marks the keys it writes
# with custom_metadata managed-by=external-secrets (charts/tenant demo-secrets.yaml); no more than delete already allows.
path "kv-tenant-{{identity.entity.metadata.tenant}}/data/*" { capabilities = ["create", "update", "patch", "read", "delete"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/metadata/*" { capabilities = ["create", "update", "read", "list", "delete"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/delete/*" { capabilities = ["update"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/undelete/*" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
