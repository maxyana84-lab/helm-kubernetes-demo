# Exercise: Deploy & test Cluster Autoscaler on EKS

Cluster `devops-lab-ca`, region `us-east-1`, one managed node group of 2-6 `t3.medium` nodes.

| File | Task |
|---|---|
| `cluster.yaml` | A.1 eksctl ClusterConfig (managed node group, OIDC) |
| `iam/cluster-autoscaler-policy.json` | A.2 IAM policy |
| `helm/values-cluster-autoscaler.yaml` | A.4 Helm values |
| `batch-processor.yaml` | B.1 stress workload |

> **Cost and safety.** This creates real AWS resources (EKS control plane, 2-3 `t3.medium` nodes, a NAT gateway): roughly a few tenths of a dollar per hour, so do the exercise in one sitting and clean up (C.1).
> `eksctl create cluster` adds a new kubectl context and makes it current. If your kubeconfig already contains other clusters, use a dedicated file so commands cannot reach them by accident:
> `export KUBECONFIG=$HOME/.kube/devops-lab-ca.yaml`

## Part A: cluster and autoscaler setup

### A.1 Create the EKS cluster
```bash
eksctl create cluster -f cluster.yaml
kubectl get nodes          # 2 nodes Ready
```
Equivalent one-liner:
```bash
eksctl create cluster --name devops-lab-ca --region us-east-1 --version 1.34 \
  --nodegroup-name ng-main --node-type t3.medium --nodes 2 --nodes-min 2 --nodes-max 6 \
  --managed --with-oidc --asg-access
```
The ASG tags `k8s.io/cluster-autoscaler/enabled` and `k8s.io/cluster-autoscaler/devops-lab-ca` are what auto-discovery looks for, so keep them in the ClusterConfig.

### A.2 IAM policy (`iam/cluster-autoscaler-policy.json`)
Two statements:
- **Read-only discovery** (`Describe*` on ASGs, launch templates and instance types, `eks:DescribeNodegroup`): these actions do not support resource-level restrictions, so `Resource` is `*`.
- **Mutating actions** `autoscaling:SetDesiredCapacity` and `autoscaling:TerminateInstanceInAutoScalingGroup`, allowed only on Auto Scaling groups tagged for this cluster (`aws:ResourceTag/...` condition). The autoscaler can therefore not touch any other ASG in the account.

```bash
aws iam create-policy --policy-name ClusterAutoscalerPolicy-devops-lab-ca \
  --policy-document file://iam/cluster-autoscaler-policy.json
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### A.3 IRSA service account
```bash
eksctl create iamserviceaccount \
  --cluster devops-lab-ca --region us-east-1 \
  --namespace kube-system --name cluster-autoscaler \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ClusterAutoscalerPolicy-devops-lab-ca \
  --role-name devops-lab-ca-cluster-autoscaler \
  --override-existing-serviceaccounts --approve
kubectl -n kube-system get sa cluster-autoscaler -o yaml | grep role-arn
```

### A.4 Install Cluster Autoscaler with Helm
```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system -f helm/values-cluster-autoscaler.yaml
kubectl -n kube-system rollout status deployment -l app.kubernetes.io/name=aws-cluster-autoscaler
```
`autoDiscovery.clusterName=devops-lab-ca` turns on ASG auto-discovery; `rbac.serviceAccount.create=false` with `name: cluster-autoscaler` makes the chart use the IRSA service account instead of creating its own.

## Part B: trigger scaling and observe

### B.1 Stress workload
```bash
kubectl apply -f batch-processor.yaml
kubectl get pods -l app=batch-processor -o wide
```
`batch-processor.yaml`: 8 replicas of `public.ecr.aws/eks-distro/kubernetes/pause:3.7`, each requesting `500m` CPU and `512Mi` memory.

### B.2 Scale-up
**Q1. Which kubectl command shows pods stuck in Pending?**
```bash
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <pod>      # Events: "FailedScheduling ... Insufficient cpu", later "TriggeredScaleUp"
```

**Q2. Which command shows Cluster Autoscaler logs in real time?**
```bash
kubectl -n kube-system logs -f -l app.kubernetes.io/name=aws-cluster-autoscaler
# or: kubectl -n kube-system logs -f deployment/<release-fullname>
```
Look for `Scale-up: setting group ... size to 3` and `Pod ... is unschedulable`.

**Q3. How many additional nodes?** Show the math.

- Requested by the workload: 8 pods x 500m = **4000m CPU** (8 x 512Mi = 4 GiB memory).
- A `t3.medium` has 2 vCPU / 4 GiB, but the allocatable amount is lower (about 1930m CPU and ~3.2 GiB) and every node already runs DaemonSet and system pods (`aws-node`, `kube-proxy`, plus CoreDNS on two of them), roughly 250-350m CPU per node.
- Free per node: about 1930m - 300m = **~1600m**, so each node fits **3** pods of 500m (3 x 500 = 1500m <= 1600m); memory is not the limit (3 x 512Mi = 1.5 GiB).
- Capacity of the 2 existing nodes: 2 x 3 = **6 pods**. Pending: 8 - 6 = **2 pods** (1000m CPU).
- One new node holds 3 pods, so the autoscaler adds **1 node** (cluster grows 2 -> 3). Within the 6-node maximum.

If the two nodes carried no system pods at all, 4 vCPU would exactly equal their raw 4 vCPU and nothing would be added; in practice the system pods and the allocatable limit make it 1 extra node. (Verify with `kubectl describe nodes | grep -A8 "Allocated resources"`.)

### B.3 Scale-down
```bash
kubectl scale deployment batch-processor --replicas=1
kubectl -n kube-system logs -f -l app.kubernetes.io/name=aws-cluster-autoscaler   # "is unneeded since ...", then "Scale-down: removing node"
kubectl get nodes -w
```
**Q4. How long does CA wait before removing an underutilized node?** By default a node must be unneeded for **10 minutes** (`--scale-down-unneeded-time=10m`). In addition, scale-down evaluation is suspended for 10 minutes after a scale-up (`--scale-down-delay-after-add=10m`), so in this exercise the extra node disappears roughly 10-20 minutes after you scale the deployment down. The group never goes below its minimum of 2 nodes.

**Q5. When is a node eligible for scale-down?**
- Its utilization (sum of pod **requests** / allocatable) is below `--scale-down-utilization-threshold` (default **0.5**, i.e. 50%), for CPU and memory, for the whole unneeded period.
- All pods on it can be evicted and rescheduled on other nodes (enough free capacity, nodeSelectors/affinity/taints still satisfiable).
- Nothing blocks eviction: no pods that are not managed by a controller (bare pods), no pods with local storage (unless annotated `safe-to-evict: "true"`), no pod annotated `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, no PodDisruptionBudget that would be violated, no kube-system pods without a PDB (`--skip-nodes-with-system-pods=true`).
- The node is not annotated `cluster-autoscaler.kubernetes.io/scale-down-disabled: "true"`, was not added recently (cool-down after scale-up), and its node group is above `minSize`.

## Part C: conceptual questions

**Q6. Default scan interval and the main disadvantage of polling?**
Cluster Autoscaler re-evaluates the cluster every **10 seconds** (`--scan-interval=10s`). Because it polls instead of reacting to events, decisions lag behind reality: pending pods wait up to one scan interval, and capacity is then added indirectly (CA changes the ASG's desired size, the ASG launches an instance, the node joins and becomes Ready), which typically takes 2-5 minutes in total. It also keeps calling the Kubernetes and AWS APIs on every cycle and can hit rate limits in large clusters. Event-driven systems such as Karpenter watch for unschedulable pods and call the EC2 API directly, so they provision faster and with less overhead.

**Q7. A mix of CPU-intensive and memory-intensive workloads with Cluster Autoscaler?**
Cluster Autoscaler works with **node groups** whose nodes are assumed to have identical capacity, so a single group cannot be optimal for both. Create separate node groups, for example compute-optimized (`c5`/`c6i`) and memory-optimized (`r5`/`r6i`), label and optionally taint them, and steer workloads with `nodeSelector`/`affinity` and `tolerations`. Use the `least-waste` (or `priority`) expander so the autoscaler picks the group that fits a pending pod best. Operational overhead: every workload class needs its own node group (ASG, launch template, min/max, tags, upgrades, IAM), over-provisioning and fragmentation are likely (fixed instance shapes waste capacity), and the number of groups grows with the number of workload types. This is the main motivation for Karpenter, which chooses the instance type per pending pod.

**Q8. Spot instances with Cluster Autoscaler: setup and risks.**
Setup:
- Add one or more separate **Spot node groups** (`capacityType: SPOT` for managed node groups) and keep an on-demand group as a fallback.
- Use **several instance types with the same vCPU/memory** in each Spot group (for example `t3.medium`, `t3a.medium`, `t2.medium`), because CA assumes all instance types in a group have the same capacity; diversification reduces the chance of capacity shortages and interruptions.
- Taint/label the Spot nodes (for example `lifecycle=spot:PreferNoSchedule`) and give interruption-tolerant workloads the toleration; run critical pods on on-demand nodes.
- Use `--expander=priority` with the `cluster-autoscaler-priority-expander` ConfigMap to prefer Spot and fall back to on-demand, and use PodDisruptionBudgets so evictions do not take down a service.

Risks:
1. **Interruptions**: AWS can reclaim Spot instances with a 2-minute warning, so pods are evicted abruptly; workloads must be stateless or checkpoint their work, and long-running batch jobs may restart.
2. **Capacity unavailability**: a Spot request may not be fulfilled, so pending pods stay Pending until CA gives up (`--max-node-provision-time`, default 15 minutes) and backs off to another group.
3. **Limited instance diversification** because CA needs identical instance sizes per group, which makes Spot shortages more likely than with Karpenter.
4. Price changes and possible mass interruption of one instance type in one zone at the same time.

### C.1 Clean up
```bash
kubectl delete -f batch-processor.yaml
helm uninstall cluster-autoscaler -n kube-system
eksctl delete iamserviceaccount --cluster devops-lab-ca --region us-east-1 \
  --namespace kube-system --name cluster-autoscaler
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ClusterAutoscalerPolicy-devops-lab-ca
eksctl delete cluster --name devops-lab-ca --region us-east-1 --wait
```
Check that nothing is left (and nothing is still billed):
```bash
aws eks list-clusters --region us-east-1
aws cloudformation list-stacks --region us-east-1 --query "StackSummaries[?contains(StackName,'devops-lab-ca') && StackStatus!='DELETE_COMPLETE'].StackName"
aws ec2 describe-instances --region us-east-1 --filters "Name=tag-key,Values=k8s.io/cluster-autoscaler/devops-lab-ca" "Name=instance-state-name,Values=running,pending"
aws ec2 describe-nat-gateways --region us-east-1 --filter "Name=state,Values=available"
aws iam list-open-id-connect-providers          # the cluster's OIDC provider should be gone
```
