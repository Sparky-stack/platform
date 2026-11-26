# Shared fake `bao` CLI and helpers for OpenBao reconcile contract tests.
# shellcheck shell=bash

# fake_bin_bao <bin-dir>: install a stateful fake `bao` CLI backed by $FAKE_STATE.
fake_bin_bao() {
  mkdir -p "$1"
  cat > "$1/bao" <<'FAKE'
#!/usr/bin/env bash
set -u
S=$FAKE_STATE
printf '%s %s\n' "${BAO_TOKEN:-none}" "$*" >> "$S/calls"
enc() { printf '%s' "$1" | tr '/' '_'; }
field=""
args=("$@")
cmd=${args[0]}; args=("${args[@]:1}")
if [[ "$cmd" =~ ^(read|write)$ && "${args[0]:-}" == -field=* ]]; then
  field=${args[0]#-field=}; args=("${args[@]:1}")
fi
prefix=${FAKE_AUTH_ACC_PREFIX:-auth_jwt_}
case "$cmd" in
  read)
    p=${args[0]}
    case "$p" in
      sys/mounts/*) [[ -e "$S/mounts/$(enc "${p#sys/mounts/}")" ]] ;;
      sys/auth/*) [[ -e "$S/auth/$(enc "${p#sys/auth/}")" ]] && { [[ -z "$field" ]] || echo "${prefix}${p#sys/auth/}"; } ;;
      identity/entity/name/*) [[ -e "$S/entities/${p##*/}" ]] && echo "id-${p##*/}" ;;
      sys/policies/acl/*) [[ -e "$S/policies/${p##*/}" ]] || exit 2; cat "$S/policies/${p##*/}" ;;
      */cert/ca) m=${p%/cert/ca}; [[ -e "$S/certs/$(enc "$m")" ]] && echo "-----BEGIN CERTIFICATE----- $m" ;;
      *) exit 2 ;;
    esac ;;
  write)
    p=${args[0]}; rest=("${args[@]:1}")
    if [[ "$p" == auth/kubernetes/login && -e "$S/login-fails" ]]; then
      echo "Code: 400. * invalid role name" >&2; exit 2
    fi
    if [[ "$p" == auth/*/config && "${rest[*]}" == *unreachable* ]]; then
      echo "Error writing data to $p: Code: 400. * error checking jwks URL: 403 system:anonymous" >&2; exit 2
    fi
    if [[ "${rest[*]:-}" == "-" ]]; then cat > "$S/writes/$(enc "$p")"; else printf '%s\n' "${rest[@]}" > "$S/writes/$(enc "$p")"; fi
    case "$p" in
      auth/kubernetes/login) for a in "${rest[@]}"; do [[ "$a" == role=* ]] && echo "tok-${a#role=}"; done; true ;;
      identity/entity/name/*) touch "$S/entities/${p##*/}" ;;
      identity/entity-alias)
        an=""; ac=""; aa=""
        for a in "${rest[@]}"; do case "$a" in name=*) an=${a#name=} ;; canonical_id=*) ac=${a#canonical_id=} ;; mount_accessor=*) aa=${a#mount_accessor=} ;; esac; done
        if awk -v n="$an" -v c="$ac" -v a="$aa" '$2 == a && $3 == c && $1 != n {f=1} END {exit !f}' "$S/aliasmap" 2>/dev/null; then
          echo "Error writing data to identity/entity-alias: Code: 400. * Alias already exists for requested entity and mount accessor" >&2; exit 2
        fi
        { awk -v n="$an" -v a="$aa" '!($1 == n && $2 == a)' "$S/aliasmap" 2>/dev/null; printf '%s %s %s\n' "$an" "$aa" "$ac"; } > "$S/aliasmap.new"
        mv "$S/aliasmap.new" "$S/aliasmap"
        cat "$S/writes/identity_entity-alias" >> "$S/aliases"; echo >> "$S/aliases" ;;
      */root/generate/internal) touch "$S/certs/$(enc "${p%/root/generate/internal}")" ;;
      */intermediate/generate/internal) echo "-----BEGIN CERTIFICATE REQUEST-----" ;;
      */root/sign-intermediate) echo "-----BEGIN CERTIFICATE----- int" ;;
      */intermediate/set-signed) touch "$S/certs/$(enc "${p%/intermediate/set-signed}")" ;;
      auth/kubernetes/role/*) cp "$S/writes/$(enc "$p")" "$S/roles/${p##*/}" ;;
      auth/*/role/*|*/roles/*) cp "$S/writes/$(enc "$p")" "$S/roles/$(enc "$p")" ;;
    esac ;;
  delete)
    p=${args[0]}
    case "$p" in
      identity/entity/name/*)
        rm -f "$S/entities/${p##*/}"
        if [[ -f "$S/aliasmap" ]]; then
          awk -v c="id-${p##*/}" '$3 != c' "$S/aliasmap" > "$S/aliasmap.new" 2>/dev/null && mv "$S/aliasmap.new" "$S/aliasmap"
        fi ;;
      auth/*/role/*) rm -f "$S/roles/$(enc "$p")" ;;
      *) exit 2 ;;
    esac ;;
  list)
    p=${args[0]}
    case "$p" in
      identity/entity/name)
        found=$(cd "$S/entities" && ls 2>/dev/null)
        [[ -n "$found" ]] || { echo "No value found at $p" >&2; exit 2; }
        printf 'Keys\n----\n%s\n' "$found" ;;
      sys/policies/acl)
        printf 'Keys\n----\n'; ls "$S/policies" ;;
      auth/*/role)
        m=${p#auth/}; m=${m%/role}
        found=$(cd "$S/roles" && ls "auth_${m}_role_"* 2>/dev/null | sed "s/^auth_${m}_role_//")
        [[ -n "$found" ]] || { echo "No value found at $p" >&2; exit 2; }
        printf 'Keys\n----\n%s\n' "$found" ;;
      *) exit 2 ;;
    esac ;;
  secrets)
    [[ "${args[0]}" == enable ]] && for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/mounts/$(enc "${a#-path=}")"; done
    exit 0 ;;
  auth)
    case "${args[0]}" in
      enable) for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/auth/$(enc "${a#-path=}")"; done; exit 0 ;;
      disable) rm -f "$S/auth/$(enc "${args[1]}")" ;;
      list)
        printf 'Path Type Accessor Description\n---- ---- -------- -----------\nkubernetes/ kubernetes auth_kubernetes_a1 n/a\ntoken/ token auth_token_a2 n/a\n'
        for f in "$S"/auth/*; do [[ -e "$f" ]] && printf '%s/ jwt %s%s n/a\n' "$(basename "$f")" "$prefix" "$(basename "$f")"; done; true ;;
    esac ;;
  policy)
    case "${args[0]}" in
      write) cp "${args[2]}" "$S/policies/${args[1]}" ;;
      delete) rm -f "$S/policies/${args[1]}" ;;
      list) printf 'default\nroot\nplatform-mesh-config\n'; ls "$S/policies" ;;
      *) echo "fake bao: policy ${args[0]}" >&2; exit 3 ;;
    esac ;;
  token) [[ "${args[0]:-}" == revoke ]] || { echo "fake bao: token $*" >&2; exit 3; } ;;
  *) echo "fake bao: unhandled $*" >&2; exit 3 ;;
esac
FAKE
  chmod +x "$1/bao"
}

openbao_wr() { cat "$S/writes/$(printf '%s' "$1" | tr '/' '_')" 2>/dev/null; }

# openbao_role_field <hcl> <role> <field>: read a field from the self-init Kubernetes auth role block.
openbao_role_field() {
  printf '%s\n' "$1" | awk -v p="auth/kubernetes/role/$2" -v k="$3" '$0 ~ "path *= \"" p "\"" {f=1} f && $1 == k && !n++ {sub(/.*= /, ""); print}'
}
