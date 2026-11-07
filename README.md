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

1. `helm lint` with the default, dev and prod values, then `helm template`.
2. Create a `kind` cluster, `helm install --wait` with dev values, smoke-test the page through a port-forward, then `helm upgrade` and `helm rollback`.

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

The HPA template requires `autoscaling.minReplicas`, `maxReplicas` and `targetCPU`; if any is missing while `autoscaling.enabled: true`, rendering fails with a `required` error. Image names (`myorg/frontend`, `myorg/backend`) and the sealed-secret ciphertext in `values-staging.yaml` are placeholders.
