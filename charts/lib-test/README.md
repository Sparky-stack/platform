# lib-test

## Purpose

Test harness for the library chart [`charts/lib`](../lib/README.md): a library chart renders nothing by itself, so this
application chart depends on it and each file in `templates/` renders one helper; `tests/` holds the helm-unittest
suites (`task test`).

## Where it runs

- **Target:** never deployed; rendered only by `helm unittest` (`hack/test.sh`).
- **Selection:** not in any catalog or ApplicationSet.

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agentServerCA | object | `{"configMapName":"cluster-gateway-ca","enabled":true,"sourceSecret":"cluster-gateway-ca","store":"mgmt-openchoreo"}` | Input of `koorikla-lib.agentServerCA` (fixture templates/agent-server-ca.yaml). |
| esoKubernetesProvider | object | `{"clusterStore":false,"namespace":"x","remoteNamespace":"x","serviceAccount":"eso-mgmt-x"}` | Arguments of `koorikla-lib.esoKubernetesProvider` (fixture templates/eso-kubernetes-provider.yaml). |
| esoSecretReader | object | `{"name":"mgmt-x","namespace":"x","secret":"x-ca-bundle"}` | Arguments of `koorikla-lib.esoSecretReader` (fixture templates/eso-secret-reader.yaml). |
| namespace | object | `{"ambient":false,"podSecurity":"restricted"}` | Input of `koorikla-lib.operatorNamespace` (fixture templates/operator-namespace.yaml). |
| org | string | `"example-org"` | Organisation the sourceIntegrity repo pattern templates in (stands in for installation.githubOrg). |
| sourceIntegrity | object | `{"enabled":false,"keys":["B5690EEEBB952194"],"mode":"head","repos":["{{ .Values.org }}/*"]}` | Input of `koorikla-lib.sourceIntegrity` (fixture templates/source-integrity.yaml); repos go through tpl. |

## Day-2 notes

- A new helper in `charts/lib` gets a fixture template here and a suite in `tests/`.

## Links

- [helm-unittest](https://github.com/helm-unittest/helm-unittest)