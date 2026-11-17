# CronJob tenant-reconcile (Kubernetes auth role tenant-config, ServiceAccount openbao/openbao-tenant-config): kv
# mounts kv-tenant-* (type kv only, never deleted), jwt auth tenants-* whose roles may carry only tenant-read, identity
# entities tenant-* (metadata only) and their aliases. It reads no secret, writes no policy and touches neither the
# mesh nor the Kubernetes auth roles.
path "sys/auth" { capabilities = ["read"] }
path "sys/auth/tenants-*" {
  capabilities       = ["create", "read", "update", "delete", "sudo"]
  allowed_parameters = { "*" = [], "type" = ["jwt"] }
  denied_parameters  = { "plugin_name" = [] }
}
path "auth/tenants-*" {
  capabilities       = ["create", "read", "update", "delete", "list"]
  allowed_parameters = { "*" = [], "token_policies" = ["tenant-read"] }
  denied_parameters  = { "policies" = [] }
}
path "sys/mounts/kv-tenant-*" {
  capabilities       = ["create", "read", "update"]
  allowed_parameters = { "*" = [], "type" = ["kv"] }
  denied_parameters  = { "plugin_name" = [] }
}
path "identity/entity/name/tenant-*" {
  capabilities       = ["create", "read", "update", "delete"]
  allowed_parameters = { "metadata" = [] }
}
# list: prune of namespace entities tenant-<t>.<c>.<ns> that are no longer bound (names only)
path "identity/entity/name" { capabilities = ["list"] }
path "identity/entity-alias" {
  capabilities       = ["create", "update"]
  allowed_parameters = { "name" = [], "canonical_id" = [], "mount_accessor" = [] }
}
path "kv-tenant-*" { capabilities = ["deny"] }
path "sys/policies/*" { capabilities = ["deny"] }
path "sys/policy/*" { capabilities = ["deny"] }
path "auth/kubernetes/*" { capabilities = ["deny"] }
path "sys/auth/mesh-*" { capabilities = ["deny"] }
path "auth/mesh-*" { capabilities = ["deny"] }
path "sys/mounts/pki-*" { capabilities = ["deny"] }
path "pki-*" { capabilities = ["deny"] }
