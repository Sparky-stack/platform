# Workload-cluster SecretStores (auth/tenants-<cluster>, JWT; role <tenant> carries only this policy): read and list
# kv-tenant-<tenant>, <tenant> = metadata of the caller's identity entity tenant-<tenant>.<cluster>.<namespace> (one
# per bound namespace, written by tenant-reconcile).
# An entity without metadata.tenant (a login whose alias the reconcile never bound) resolves to nothing.
path "kv-tenant-{{identity.entity.metadata.tenant}}/data/*" { capabilities = ["read"] }
path "kv-tenant-{{identity.entity.metadata.tenant}}/metadata/*" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
