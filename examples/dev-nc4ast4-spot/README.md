# Development Cluster with NC4as T4 Spot GPUs

Creates a minimal AKS cluster with a single `Standard_NC4as_T4_v3` spot GPU pool (NVIDIA T4). The cheapest single-GPU SKU on Azure - well-suited for development and testing SIE (Search Inference Engine) workloads at low cost.

## What this example creates

| Resource | Configuration |
|----------|---------------|
| AKS cluster | Public API endpoint, AAD-RBAC, Workload Identity + OIDC issuer, Kubernetes default version |
| GPU node pool | 1x NVIDIA T4 per node (Standard_NC4as_T4_v3), spot, scale 0-5 |
| System node pool | Standard_B4ms (system workloads - burstable 4 vCPU / 16 GiB), scale 1-5 across zones 1/2/3 |
| VNet | Single VNet, three subnets (system, GPU, private-endpoint), Cilium network policy |
| NAT gateway | One NAT gateway with a /28 public IP prefix concentrating worker egress |
| ACR | One Premium-SKU ACR; image paths: `<acr>.azurecr.io/<project>/{sie-server,sie-gateway,sie-config}` |
| Storage cache | One StorageV2 account + blob container `sie-cache` with `models/` + `payloads/` prefixes |
| Workload Identity | Workload UAMI + federated credential bound to `sie/sie-server` SA |
| NVIDIA device plugin | Helm release in `kube-system` so GPU pods schedule |

**Estimated cost**: ~$0.15/hr (approx. West Europe spot list price at the time of writing) while a GPU node is running. Near $0/hr when scaled to zero (AKS Standard tier control-plane fee only). Verify the current rate in the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

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
# source repo - it wires up KEDA, the t4 machine profile, and the
# azure.workload.identity/use=true pod label the AKS Workload Identity webhook
# keys off of. Pin to a release tag instead of `main` for reproducible installs.
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster --version 0.6.13 \
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
    name      = "t4"
    gpu_class = "t4"
    spot      = false
    # ...
  }
]
```

**Use A10 instead of T4:**

```hcl
gpu_node_pools = [
  {
    name      = "a10spot"
    gpu_class = "a10"   # resolves to Standard_NV6ads_A10_v5
    spot      = true
    node_count = 0
    max_count  = 5
  }
]
```

**Add A100 or H100 once quota is granted** (values-only change, no resource block additions):

```hcl
gpu_node_pools = [
  {
    name       = "t4spot"
    gpu_class  = "t4"
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
2. Standard NCASv3_T4 family vCPU quota in the target region (request from the Azure portal Quotas blade)
3. Terraform >= 1.14

## Cleanup

```bash
terraform destroy
```
