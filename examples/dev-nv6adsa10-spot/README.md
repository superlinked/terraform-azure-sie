# Development Cluster with NV6ads A10 Spot GPUs

Creates a minimal AKS cluster with a single `Standard_NV6ads_A10_v5` spot GPU pool (NVIDIA A10, 24 GiB VRAM). Pick this over [`dev-nc4ast4-spot`](../dev-nc4ast4-spot/) when running models that need more than the 16 GiB of VRAM a T4 ships with.

## What this example creates

| Resource | Configuration |
|----------|---------------|
| AKS cluster | Public API endpoint, AAD-RBAC, Workload Identity + OIDC issuer, Kubernetes default version |
| GPU node pool | 1x NVIDIA A10 per node (Standard_NV6ads_A10_v5), spot, scale 0-5 |
| System node pool | Standard_B4ms (system workloads - burstable 4 vCPU / 16 GiB), scale 1-5 across zones 1/2/3 |
| VNet | Single VNet, three subnets (system, GPU, private-endpoint), Cilium network policy |
| NAT gateway | One NAT gateway with a /28 public IP prefix concentrating worker egress |
| ACR | One Premium-SKU ACR; image paths: `<acr>.azurecr.io/<project>/{sie-server,sie-gateway,sie-config}` |
| Storage cache | One StorageV2 account + blob container `sie-cache` with `models/` + `payloads/` prefixes |
| Workload Identity | Workload UAMI + federated credential bound to `sie/sie-server` SA |
| NVIDIA device plugin | Helm release in `kube-system` so GPU pods schedule |

**Estimated cost**: ~$0.35/hr (approx. West Europe spot list price at the time of writing) while a GPU node is running. Near $0/hr when scaled to zero (AKS Standard tier control-plane fee only). Verify the current rate in the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

## When to pick A10 over T4

| | T4 (`dev-nc4ast4-spot`) | A10 (this example) |
|---|---|---|
| VRAM | 16 GiB | 24 GiB |
| Spot price (West Europe, approx.) | ~$0.15/hr | ~$0.35/hr |
| Best for | Small embedding bundles (bge-m3, e5-base) | Larger embedding bundles, bge-multilingual-gemma2, longer context |

If your bundle fits on T4, prefer `dev-nc4ast4-spot` - it's noticeably cheaper. Verify current rates in the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

## Usage

```bash
az login
az account set --subscription "<subscription_id>"
terraform init
terraform plan
terraform apply
```

After apply, deploy SIE via Helm:

```bash
# Configure kubectl
$(terraform output -raw kubectl_config_command)

# Install SIE (gateway, sie-config, workers, KEDA, Prometheus, Grafana). The
# -f flag pulls the AKS overlay (values-aks.yaml) directly from the chart's
# source repo - it wires up KEDA, the a10 machine profile, and the
# azure.workload.identity/use=true pod label the AKS Workload Identity webhook
# keys off of. Pin to a release tag instead of `main` for reproducible installs.
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster --version 0.6.10 \
  -f https://raw.githubusercontent.com/superlinked/sie/main/deploy/helm/sie-cluster/values-aks.yaml \
  --namespace sie --create-namespace \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$(terraform output -raw sie_workload_identity_client_id)" \
  $(terraform output -raw model_cache_helm_args)
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `westeurope` | Azure region |
| `project_name` | `sie-dev` | Name prefix for all resources |

## Outputs

| Output | Description |
|--------|-------------|
| `cluster_name` | AKS cluster name |
| `kubectl_config_command` | Run this to configure kubectl |
| `sie_workload_identity_client_id` | Pass to Helm for workload identity |
| `workload_identity_annotation` | `<annotation-key>=<client-id>` string consumed by tools that split on `=`. For manual `helm install --set`, pass `sie_workload_identity_client_id` instead. |
| `acr_login_server` | Used with `az acr login` |
| `acr_server_repository_url` | Push target for `sie-server` images |
| `acr_gateway_repository_url` | Push target for `sie-gateway` images |
| `acr_config_repository_url` | Push target for `sie-config` images |
| `model_cache_bucket_url` | Pass to Helm as `workers.common.clusterCache.url` |
| `model_cache_helm_args` | Pre-composed Helm `--set` flags for the cache |

## Customizing

**Change region:**

```hcl
variable "location" {
  default = "swedencentral"
}
```

**Use on-demand instead of spot (more reliable, higher cost):**

```hcl
gpu_node_pools = [
  {
    name      = "a10"
    gpu_class = "a10"
    spot      = false
    # ...
  }
]
```

**Add A100 or H100 once quota is granted** (values-only change, no resource block additions):

```hcl
gpu_node_pools = [
  {
    name       = "a10spot"
    gpu_class  = "a10"
    spot       = true
    node_count = 0
    max_count  = 5
  },
  {
    name      = "a100"
    gpu_class = "a100"  # resolves to Standard_NC24ads_A100_v4
    node_count = 0
    max_count  = 2
  },
]
```

## Prerequisites

1. `az login` and an active subscription with billing enabled
2. Standard NVADSA10v5 family vCPU quota in the target region (request from the Azure portal Quotas blade)
3. Terraform >= 1.14

## Cleanup

```bash
terraform destroy
```
