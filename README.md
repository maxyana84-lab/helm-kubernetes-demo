# helm-kubernetes-demo

A personal learning project: a small web application packaged as a **Helm chart** and deployed to **Kubernetes**, with a CI pipeline that lints the chart and installs it on a throwaway `kind` cluster.

## What is in the chart (`charts/webapp`)

| Resource | Purpose |
|---|---|
| Deployment | nginx (unprivileged) serving a page from a ConfigMap, with liveness/readiness probes, resource requests/limits and a hardened security context (non-root, read-only root filesystem, dropped capabilities, seccomp `RuntimeDefault`) |
| Service | ClusterIP exposing the app on port 80 |
| ConfigMap | the HTML page, rendered from values; a checksum annotation rolls the pods when it changes |
| ServiceAccount | dedicated account with token automount disabled |
| Ingress | optional (`ingress.enabled`) |
| HorizontalPodAutoscaler | optional (`autoscaling.enabled`), CPU based |

Environment-specific settings live in values files: `values.yaml` (defaults), `values-dev.yaml`, `values-prod.yaml` (3+ replicas, ingress and HPA on, bigger limits).

## Usage

```bash
# render manifests without a cluster
helm template demo charts/webapp -f charts/webapp/values-dev.yaml

# lint
helm lint charts/webapp -f charts/webapp/values-prod.yaml

# install on a local cluster (kind / minikube / Docker Desktop)
helm install demo charts/webapp -f charts/webapp/values-dev.yaml --wait
kubectl port-forward svc/demo-webapp 8080:80   # open http://localhost:8080

# upgrade, inspect history, roll back
helm upgrade demo charts/webapp --set config.message="v2" --wait
helm history demo
helm rollback demo 1 --wait

helm uninstall demo
```

## CI (`.github/workflows/ci.yml`)

| Job | What it checks |
|---|---|
| `lint-and-template` | `helm lint` of `charts/webapp` with the default, dev and prod values, then `helm template` |
| `install-on-kind` | creates a `kind` cluster, `helm install --wait` with dev values, smoke-tests the page through a port-forward, then `helm upgrade` and `helm rollback` (`charts/webapp`) |
| `myapp-multi-env` | lint and render of `charts/myapp` for dev, staging and prod: resource sets per environment, `required` failure without `targetCPU` |
| `exercise-2-library-umbrella` | builds the library and the sub-charts, lints `platform`, checks 4/4/4/1 resources and 3/3/3/1 with `notification-service` disabled |
| `exercise-3-bluegreen` | lint and render of the blue-green chart: resource counts, hook weights, canary annotation, weight validation, rollback render, replicas that follow the hooks |
| `exercise-4-cluster-autoscaler` | validates the IAM policy, the eksctl ClusterConfig, the stress Deployment and the Helm values |

Everything except `install-on-kind` only renders and validates files: nothing in CI runs the blue-green hooks or touches AWS.

## Notes

This is a hands-on practice project, not a production deployment. The image is a public nginx image used only to have something to run; the point of the project is the chart structure, values per environment, health probes, security context, and the install/upgrade/rollback workflow.

## Multi-environment chart (`charts/myapp`)

A three-tier app (Node.js frontend, FastAPI backend, PostgreSQL) in a single chart. Everything environment-specific lives in `values-dev.yaml`, `values-staging.yaml` and `values-prod.yaml` (no `--set`); `values.yaml` holds dev-friendly defaults.

| | dev | staging | prod |
|---|---|---|---|
| Replicas (frontend / backend) | 1 / 1 | 2 / 2 | 3 + PDB / HPA (min 4) |
| Database | StatefulSet | StatefulSet + backup CronJob | external RDS, ConfigMap only |
| Exposure | NodePort | NGINX Ingress, self-signed TLS | NGINX Ingress, cert-manager TLS |
| Secrets | ConfigMap | SealedSecret | ExternalSecret (AWS) |
| Monitoring | - | ServiceMonitor | ServiceMonitor + PrometheusRule |

```bash
helm template myapp charts/myapp -f charts/myapp/values-prod.yaml
helm lint charts/myapp -f charts/myapp/values-staging.yaml
```

The HPA template requires `autoscaling.minReplicas`, `maxReplicas` and `targetCPU`; if any is missing while `autoscaling.enabled: true`, rendering fails with a `required` error.

### Images
The frontend and backend use public stand-in images so the pods really start: `nginxinc/nginx-unprivileged:1.27-alpine` and `mccutchen/go-httpbin:v2.15.0` (health endpoint `/status/200`). Swap in your own Node.js and FastAPI images via `frontend.image`, `backend.image`, `*.port` and `*.healthPath` in the values files. The database uses `postgres:16-alpine`.

### Staging SealedSecret
`values-staging.yaml` contains `REPLACE_WITH_KUBESEAL_OUTPUT` placeholders: real ciphertext can only be produced with the public certificate of your own cluster's sealed-secrets controller.

```bash
kubectl create secret generic myapp-secrets --dry-run=client \
  --from-literal=POSTGRES_USER=app --from-literal=POSTGRES_PASSWORD='<strong-password>' -o json \
| kubeseal --controller-namespace kube-system --scope cluster-wide -o json \
| jq '.spec.encryptedData'
```
Paste the two values into `secrets.sealed.encryptedData` in `values-staging.yaml`. The `--scope cluster-wide` flag is needed because the chart names the secret `<release>-myapp-secrets`.

## Exercise 2: library chart + umbrella chart (`exercise-2/`)

- `trtech-lib/`: library chart (`type: library`) with named templates: `trtech-lib.labels`, `.deployment` (probes with configurable paths, resources, anti-affinity, `topologySpreadConstraints`), `.service`, `.networkpolicy` (ingress only from namespaces labelled `role: frontend`), `.podantiaffinity`, `.pdb`.
- `services/{auth,user,payment,notification}-service`: sub-charts whose templates are one-liners like `{{ include "trtech-lib.deployment" . }}`. `payment-service` also renders a PodDisruptionBudget (`minAvailable: 2`).
- `platform/`: umbrella chart that configures all four services; `notification-service` can be switched off with `notification-service.enabled=false` (dependency `condition`).

```bash
cd exercise-2
./build.sh                      # package lib, helm dependency update/build, tgz files land in platform/charts/
helm lint ./platform
helm template platform ./platform                                        # 4 Deployments, 4 Services, 4 NetworkPolicies, 1 PDB
helm template platform ./platform --set notification-service.enabled=false   # 3 of each, 1 PDB
```
Generated `*.tgz` files are git-ignored; CI runs `build.sh` first.

## Exercise 3: blue-green deployment with traffic splitting (`exercise-3/bluegreen/`)

Two Deployments (`<release>-blue` stable, `<release>-green` candidate) are rendered on every install. Only native Kubernetes resources are used: Service selectors and NGINX Ingress canary annotations, no service mesh.

| Piece | How it works |
|---|---|
| Primary Service | selector `slot: {{ .Values.activeSlot }}`, decides which Deployment gets traffic |
| Green Service | always selects `slot: green`; target of the canary Ingress and of the smoke test |
| Ingresses | primary Ingress -> primary Service; canary Ingress (`canary: "true"`, `canary-weight`) -> green Service. Allowed weights: 0, 10, 50, 100 |
| pre-upgrade hook (weight -5) | scales green to blue's replica count and waits until all pods are Ready |
| post-upgrade hook (weight 0) | smoke test against the green Service: expected status code and response time below `canary.tests.maxResponseTimeMs`; the verdict is stored in the annotation `bluegreen-smoke-result` on the green Deployment |
| post-upgrade hook (weight 5) | verdict `pass`: primary Service -> green, blue scaled to 0. Otherwise green is scaled to 0 and the Job fails |
| rollback (`rollback.enabled=true`) | renders only a post-upgrade rollback Job: blue is scaled back up if needed, Service -> blue, green -> 0. Pre-upgrade, smoke test and cutover hooks are skipped |
| RBAC | one ServiceAccount, Role and RoleBinding for the hooks: only `get` and `patch` on Deployments and Services of the release namespace |
| Monitoring | `prometheus.io/*` annotations on both Deployments and a PrometheusRule `CanaryErrorRateHigh` (green 5xx ratio above 5% over 2 minutes). The stand-in image `go-httpbin` does not expose `/metrics`: the rule assumes an application that exports `http_requests_total{code=...}` (configurable in `monitoring.prometheusRule`) |

```bash
cd exercise-3/bluegreen
helm lint .
helm template bg .                                  # 2 Deployments, 2 Services, 2 Ingresses, SA, Role, RoleBinding, 3 hook Jobs
helm template bg . --set canary.weight=10 | grep canary-weight
helm template bg . --set rollback.enabled=true      # rollback Job only
```

Notes:
- The hooks wait for readiness by polling `kubectl get` and scale with `kubectl patch`, so the Role needs no `watch`/`list` and no `deployments/scale` access.
- The smoke test Job never fails by itself: it records `pass`/`fail` on the green Deployment and the cutover hook decides. A failing hook would make Helm abort before the cutover hook could scale green down.
- Helm 3 reverts live changes to every field that is present in the manifest, so the Deployments' `replicas` must agree with what the hooks do. On `helm upgrade` the green Deployment is therefore rendered with blue's replica count (on install green stays at 0), and with `rollback.enabled=true` green is rendered with 0 replicas. The primary Service selector is also reset to `activeSlot` by every upgrade and flipped to green again by the cutover hook: after a successful cutover record the new state in your values (`activeSlot: green`) before the next release.
- `bitnami/kubectl` no longer publishes pinned tags, so the default is `bitnamilegacy/kubectl:1.31` (`hooks.kubectlImage`).
- **What was run on a real cluster** (kind, outside CI, Helm 3): `helm install` (blue 2/2, green 0/0, Service on blue), `helm upgrade` (green scaled up by the pre-upgrade hook, smoke test `pass`, cutover: Service on green, blue scaled to 0), `rollback.enabled=true` (blue back to 2/2, Service on blue, green 0) and a failing smoke test (`canary.tests.expectedStatus=418`: the upgrade fails in the cutover Job, green goes back to 0, the Service stays on blue). The first run found the replicas problem described above.
- **What was not run:** real traffic through the NGINX canary Ingress (the weights are only checked as annotations), the PrometheusRule (the kind cluster has no Prometheus CRDs) and **a second normal upgrade after a cutover**. Helm reverts the live changes of the hooks (blue scaled to 0, Service on green), so such an upgrade scales blue up again and points the Service at it until the hooks switch back to green: expect a short window in which the Service selects blue pods that are still starting. A cleaner release cycle is to swap the roles in the values first (`blue.image.tag` = the version that is live now, `green.image.tag` = the new candidate, `activeSlot: blue`). Making the chart read the live state with `lookup` would remove the problem; it needs a cluster to test.

## Exercise: Cluster Autoscaler on EKS (`exercise-4-cluster-autoscaler/`)

Written deliverables for deploying and testing Cluster Autoscaler on an EKS cluster: eksctl `ClusterConfig` (managed node group 2-6 x `t3.medium`, OIDC), the least-privilege IAM policy, the IRSA and Helm commands, the `batch-processor` stress Deployment, the clean-up commands and the answers to the scale-up, scale-down and conceptual questions. See the README in that folder. CI validates the policy and the YAML files; nothing in this repository creates AWS resources.
