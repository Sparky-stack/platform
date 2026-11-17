# Writers (Kubernetes auth role tenant-writer: ServiceAccounts openbao-tenants/<tenant>-writer on mgmt): write
# kv-tenant-<tenant> of the caller's own entity only.
path "kv-tenant-{{identity.entity.metadata.tenant}}/data/*" { capabilities = ["create", "update", "patch", "read", "delete"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/metadata/*" { capabilities = ["read", "list", "delete"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/delete/*" { capabilities = ["update"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/undelete/*" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
