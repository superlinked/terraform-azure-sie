# SIE AKS Terraform Module

One command to get a GPU-ready AKS cluster for [SIE](https://github.com/superlinked/sie) (Search Inference Engine). The module creates everything you need - VNet, AKS, GPU pools, container registry, autoscaling - so you can focus on running inference, not managing infrastructure.

## What you get

- **AKS cluster** with Workload Identity + OIDC issuer + AAD-RBAC
- **GPU node pool** - pick your GPU via `gpu_class`: `t4` (NC4as_T4_v3), `a10` (NV6ads_A10_v5), `a100` (NC24ads_A100_v4), or `h100` (NC40ads_H100_v5)
- **Scale-to-zero** - GPU pools scale down to zero when idle, so you only pay when running inference
- **Built-in cluster autoscaler** - per-pool, configured directly on the AKS node pools (no separate Helm chart to deploy or upgrade)
- **NVIDIA device plugin** - installed via Helm so GPU pods schedule immediately
- **ACR repository** (opt-in) - private Premium-SKU container registry; image paths `<acr>.azurecr.io/<project>/{sie-server,sie-gateway,sie-config}`
- **Workload Identity** - pods authenticate to Azure without stored credentials
- **Private endpoints** (opt-in) - private connectivity to ACR + Storage via `privatelink.*` DNS zones
- **Managed CSI** - persistent volumes work out of the box

## Quick start

```bash
cd examples/dev-nc4ast4-spot
az login
az account set --subscription "<subscription_id>"
terraform init
terraform plan
terraform apply
```

That's it. After apply, configure kubectl and deploy SIE via Helm:

```bash
# Point kubectl at the new cluster
$(terraform output -raw kubectl_config_command)

# Deploy SIE (gateway, workers, KEDA, Prometheus, Grafana). The -f flag pulls
# the AKS overlay (values-aks.yaml) directly from the chart's source repo -
# it wires up KEDA, the t4 + a10 machine profiles, and the
# azure.workload.identity/use=true pod label the AKS Workload Identity webhook
# keys off of. Pin to a release tag instead of `main` for reproducible installs.
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster --version 0.6.7 \
  -f https://raw.githubusercontent.com/superlinked/sie/main/deploy/helm/sie-cluster/values-aks.yaml \
  --namespace sie --create-namespace \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$(terraform output -raw sie_workload_identity_client_id)" \
  $(terraform output -raw model_cache_helm_args)
```

## Examples

Costs shown are approximate West Europe spot list prices at the time of writing - check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for the current rate in your region.

| Example | GPU | Cost | Description |
|---------|-----|------|-------------|
| [`dev-nc4ast4-spot`](examples/dev-nc4ast4-spot/) | T4 (NC4as_T4_v3) | ~$0.15/hr | Spot VMs, scale 0-5 nodes, minimal cost for development |
| [`dev-nv6adsa10-spot`](examples/dev-nv6adsa10-spot/) | A10 (NV6ads_A10_v5) | ~$0.35/hr | Spot VMs, scale 0-5 nodes, 24 GiB VRAM for larger embedding bundles |

## Prerequisites

This is a **per-cluster product module**. It does **not** ship its own state-backend or CI-identity bootstrap - those are subscription-wide / landing-zone concerns that you (or your platform team) own once and reuse across every cluster.

1. **Azure subscription + credentials.** `az login` locally (an account with `Contributor` on the target subscription is sufficient), or a federated service principal via the GitHub Actions Azure OIDC flow for CI.
2. **GPU quota in your target region.** Request from the Azure portal Quotas blade - e.g. *Standard NCASv3_T4 Family vCPUs* for T4, *Standard NVADSA10v5 Family vCPUs* for A10, *Standard NCadsH100v5 Family vCPUs* for H100. H100 quota is the slowest to approve; file the request before the first apply.
3. **Terraform** >= 1.14.

### CI authentication (GitHub Actions)

If you're running this from CI, the recommended path is the federated Azure OIDC flow - no long-lived secrets. Create a service principal with `Contributor` (and `User Access Administrator` if you use `create_acr=true` or `create_model_cache=true`, which provision role assignments), then set three repo variables (not secrets):

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: azure/login@v3
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

For tightening the SP's RBAC to the minimum set this module actually needs (Network Contributor, AKS Contributor, AKS RBAC Cluster Admin, AcrPush, Monitoring Contributor, Key Vault Contributor, RBAC Admin), see the Azure docs on [scoped role assignments](https://learn.microsoft.com/azure/role-based-access-control/best-practices).

### Remote state

Each example ships a commented `backend "azurerm" {}` stub and a `backend.hcl.example` template. Provision a Storage Account + blob container once per subscription (any standard Azure remote-state pattern works), fill the placeholders in `backend.hcl.example`, then init with:

```bash
terraform init -backend-config=backend.hcl
```

Per-cluster only the `key` field changes.

## Variables

### Required

No variables are strictly required - all have sensible defaults. Override these for your environment:

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `westeurope` | Azure region to deploy in |
| `project_name` | `sie` | Name prefix for all resources |
| `owner` | _(required)_ | UPN of the human accountable for this cluster. Populates the CAF `Owner` tag - useful for cost attribution and required if your subscription has a CAF tag-baseline policy. Example: `alice@example.com`. |

### Provider configuration

Callers MUST set `storage_use_azuread = true` on their `azurerm` provider block when `create_model_cache = true` (the default in every shipped example). The module disables shared-access-key auth on the model-cache Storage Account, so the provider's post-create blob-service probe needs an AAD token instead of a SAS key. Without this, apply fails with `403 KeyBasedAuthenticationNotPermitted` immediately after the storage account is created.

```hcl
provider "azurerm" {
  features {}
  storage_use_azuread = true
}
```

Every example in this module already sets this.

### Region zone constraints

A handful of Azure regions don't expose availability zone 1 (`francecentral`, `southafricawest`, `brazilsoutheast`, `swedensouth`, `norwaywest`, `switzerlandwest`, `westcentralus`). The module catches the combination of "restricted region + zone 1 in pool zones" at plan time with a clear error. If you deploy to one of these regions, override `system_node_pool.zones` and every `gpu_node_pools[*].zones` to a subset of the supported zones (typically `["2", "3"]`).

### CAF baseline tags

Azure landing zones aligned with Microsoft's Cloud Adoption Framework typically enforce four taxonomy tags (`Environment`, `Owner`, `CostCenter`, `Workload`) via subscription-level Audit/Deny policy. This module populates all four automatically from input variables so the cluster doesn't get flagged at apply time:

| Variable | Default | CAF tag | Allowed values |
|----------|---------|---------|----------------|
| `environment` | `nonprod` | `Environment` | `prod`, `nonprod`, `sandbox`, `shared` |
| `owner` | _(required)_ | `Owner` | UPN, e.g. `alice@example.com` |
| `cost_center` | `sie-platform` | `CostCenter` | free-form string |
| `workload` | `sie` | `Workload` | free-form string |

If your subscription has no such policy, the tags are still applied (and are useful for cost attribution) but cause no apply failures.

### GPU configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `gpu_node_pools` | `[]` | List of GPU pool definitions. Each entry needs `name`, `gpu_class` (`t4` / `a10` / `a100` / `h100`), optional `spot`, `node_count`, `max_count` |

Adding A100 or H100 once Azure quota is granted is a **values-only change** - append a new entry to `gpu_node_pools`:

```hcl
gpu_node_pools = [
  { name = "t4spot", gpu_class = "t4",  spot = true, node_count = 0, max_count = 5 },
  { name = "a100",   gpu_class = "a100",              node_count = 0, max_count = 2 },
]
```

**GPU SKU cheat sheet:**

Hourly prices are approximate West Europe on-demand list prices at the time of writing - region, term, and Reserved/Savings Plan commitments all materially change them. Check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for the current rate.

| `gpu_class` | VM size | GPU | VRAM | Approx. on-demand/hr | Best for |
|-------------|---------|-----|------|----------------------|----------|
| `t4` | Standard_NC4as_T4_v3 | 1x T4 | 16 GB | ~$0.55 | Development, small models |
| `a10` | Standard_NV6ads_A10_v5 | 1x A10 | 24 GB | ~$1.10 | Development, medium models |
| `a100` | Standard_NC24ads_A100_v4 | 1x A100 | 80 GB | ~$3.50 | Large models, production |
| `h100` | Standard_NC40ads_H100_v5 | 1x H100 | 80 GB | ~$7.00 | Maximum throughput |

### Networking

| Variable | Default | Description |
|----------|---------|-------------|
| `vnet_cidr` | `10.0.0.0/16` | CIDR block for the cluster VNet |
| `system_subnet_cidr` | `10.0.0.0/22` | System pool subnet |
| `gpu_subnet_cidr` | `10.0.4.0/22` | GPU pool subnet |
| `private_endpoint_subnet_cidr` | `10.0.8.0/24` | Private-endpoint subnet |
| `enable_private_cluster` | `false` | Toggle a private API endpoint |
| `api_server_authorized_ip_ranges` | `[]` | CIDRs allowed to reach the API server |
| `create_ingress_public_ip` | `false` | Provision a static public IP for the ingress controller in the cluster RG so DNS survives a cluster destroy/recreate |
| `deletion_protection` | `true` | Place a CanNotDelete management lock on the AKS cluster (set false for dev) |
| `automatic_upgrade_channel` | `stable` | AKS auto-upgrade channel (`patch` / `rapid` / `stable` / `node-image` / `none`) |

### Container registry

| Variable | Default | Description |
|----------|---------|-------------|
| `server_acr_repository_name` | `sie-server` | Repository path within the ACR |
| `gateway_acr_repository_name` | `sie-gateway` | |
| `config_acr_repository_name` | `sie-config` | |
| `create_acr` | `false` | Whether this module manages the ACR. Default `false` matches the chart's GHCR-by-default behaviour. Set `true` to opt in. `acr_*_repository_url` outputs are emitted regardless. |
| `acr_repository_prefix` | `null` -> `<project_name>` | Namespace prefix for ACR repos. Set to `""` to disable prefixing. |

### Workload Identity

| Variable | Default | Description |
|----------|---------|-------------|
| `sie_namespace` | `sie` | Kubernetes namespace for SIE workloads |
| `sie_service_account_name` | `sie-server` | K8s SA federated to the workload UAMI |

## Outputs

After `terraform apply`, use these outputs to connect and deploy:

| Output | Description |
|--------|-------------|
| `kubectl_config_command` | Run this to configure kubectl |
| `cluster_name` | AKS cluster name |
| `cluster_endpoint` | AKS API FQDN (sensitive) |
| `sie_workload_identity_client_id` | Pass to Helm for workload identity |
| `acr_login_server` | ACR login server |
| `acr_server_repository_url` | Where to push `sie-server` images |
| `acr_gateway_repository_url` | Where to push `sie-gateway` images |
| `acr_config_repository_url` | Where to push `sie-config` images |
| `model_cache_bucket_url` | `abfs(s)://`-style URL - pass to Helm as `workers.common.clusterCache.url` |
| `model_cache_helm_args` | Pre-composed Helm `--set` flags for the cache |
| `ingress_public_ip` | Static ingress IP address (when `create_ingress_public_ip = true`) |
| `ingress_helm_args` | Pre-composed Helm `--set` flags for ingress-nginx (loadBalancerIP + LB-RG annotation) |
| `gpu_node_pool_vm_sizes` | Effective VM SKU per pool (resolved from `gpu_class`) |

## Architecture

```text
                         ┌────────────────────────────────────────────────────┐
                         │                  Azure subscription                │
                         │                                                    │
┌──────────┐             │  ┌──────────────────────────────────────────────┐  │
│          │   HTTPS     │  │              VNet (10.0.0.0/16)              │  │
│  Client  │────────────▶│  │                                              │  │
│          │             │  │  ┌─────────────────────────────────────────┐ │  │
└──────────┘             │  │  │   AKS Cluster (AAD-RBAC + Workload ID)  │ │  │
                         │  │  │                                         │ │  │
                         │  │  │  ┌────────────┐    ┌─────────────────┐  │ │  │
                         │  │  │  │   Gateway  │───▶│  GPU Workers    │  │ │  │
                         │  │  │  │            │    │ (T4/A10/A100/H) │  │ │  │
                         │  │  │  └─────┬──────┘    └─────────────────┘  │ │  │
                         │  │  │        │                    │           │ │  │
                         │  │  │  ┌─────┴──────┐              │           │ │  │
                         │  │  │  │ sie-config │ (config control plane)  │ │  │
                         │  │  │  └────────────┘              │           │ │  │
                         │  │  │  ┌─────────────────────────────────────┐ │ │  │
                         │  │  │  │  KEDA · Prometheus · Grafana        │ │ │  │
                         │  │  │  └─────────────────────────────────────┘ │ │  │
                         │  │  │  ┌──────────────┐   ┌─────────────────┐  │ │  │
                         │  │  │  │ System pool  │   │  GPU pools      │  │ │  │
                         │  │  │  │ (B4ms)       │   │ (NC*/NV*)       │  │ │  │
                         │  │  │  └──────────────┘   └─────────────────┘  │ │  │
                         │  │  └─────────────────────────────────────────┘ │  │
                         │  │                                              │  │
                         │  │  ┌───────────┐  ┌───────────┐  ┌──────────┐  │  │
                         │  │  │    ACR    │  │  Storage  │  │   NAT    │  │  │
                         │  │  │ (images)  │  │  (cache)  │  │  GW      │  │  │
                         │  │  └───────────┘  └───────────┘  └──────────┘  │  │
                         │  └──────────────────────────────────────────────┘  │
                         └────────────────────────────────────────────────────┘
```

## Pushing images to ACR
> This is optional, because the official images are available under `ghcr.io/superlinked/`.

Requires `create_acr = true` (or an ACR managed by another stack - see `acr_repository_prefix`).

After `terraform apply`, push your SIE Docker images:

```bash
# Authenticate Docker to ACR
az acr login --name $(terraform output -raw acr_name)

# Push server image
docker tag sie-server:latest $(terraform output -raw acr_server_repository_url):latest
docker push $(terraform output -raw acr_server_repository_url):latest

# Push gateway image
docker tag sie-gateway:latest $(terraform output -raw acr_gateway_repository_url):latest
docker push $(terraform output -raw acr_gateway_repository_url):latest

# Push sie-config image
docker tag sie-config:latest $(terraform output -raw acr_config_repository_url):latest
docker push $(terraform output -raw acr_config_repository_url):latest
```

## Model cache and payload store

SIE clusters benefit from two object-store-backed features that share a single blob container:

- **Model cache**: pre-staged model weights at `abfs://sie-cache@.../models/`, so workers cold-start from blob storage rather than re-downloading from Hugging Face on every pod spin-up.
- **Payload store**: large work-item payloads (images, long documents that exceed the 1 MiB NATS in-band budget) at `abfs://sie-cache@.../payloads/`, written by the gateway and read once by the worker. Garbage-collected by a runtime TTL plus a blob lifecycle rule.

Set `create_model_cache = true` and the module:

1. Provisions a managed StorageV2 account with versioning, soft delete, and a lifecycle rule that deletes blobs under `sie-cache/payloads/` after one day.
2. Attaches two ABAC-scoped role assignments to the SIE workload UAMI: `Storage Blob Data Reader` constrained to `models/` and `Storage Blob Data Contributor` constrained to `payloads/`.
3. Optional CMEK via `model_cache_kms_key_id` (Key Vault key resource ID).
4. Locks the storage account's network ACL to `Deny` by default and allows only the cluster's system + GPU subnets (via the `Microsoft.Storage` service endpoint). Operators populating the cache from outside the VNet (e.g. running `sie-admin cache populate` from a laptop or CI runner) must add their egress IP to `storage_allowed_ip_ranges`. To allow additional subnets (e.g. a bastion), set `storage_allowed_subnet_ids` to an explicit list. Both knobs are ignored when `enable_private_endpoints = true` (private link disables the public path entirely).

After apply, pass the cache URL into Helm with one terraform output:

```bash
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster --version 0.6.7 \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$(terraform output -raw sie_workload_identity_client_id)" \
  $(terraform output -raw model_cache_helm_args)
```

The chart auto-derives `payloadStore.url` from `workers.common.clusterCache.url`, so a single `--set` for the cache covers both features. Operators who do not opt in (`create_model_cache = false`, default) skip the storage account and identity additions entirely.

See `infra/storage.tf` and `infra/identity.tf` for the resource definitions.

## Security features

This module follows Azure security best practices out of the box:

- **AAD-RBAC** - no local admin users; cluster authn/authz through Azure AD
- **Workload Identity** - pods exchange projected SA tokens for AAD tokens; no static credentials
- **TLS 1.2 minimum** - enforced on Storage + ACR
- **NAT gateway egress** - predictable outbound IPs for allowlisting
- **AcrPull on kubelet UAMI** - image pulls without registry passwords
- **NVIDIA GPU taints** - GPU nodes are tainted so only GPU workloads schedule on them
- **Container Insights** - control-plane and node logs to Log Analytics (opt-in via `enable_cloud_logging`)
- **Model-cache storage on-VNet by default** - when `create_model_cache = true`, the storage account's network ACL defaults to `Deny`, allowing only the cluster's system + GPU subnets (via `Microsoft.Storage` service endpoint). Add caller IPs through `storage_allowed_ip_ranges` or override the subnet allowlist via `storage_allowed_subnet_ids`.
- **Optional private endpoints** - ACR + Storage on Private Link (when `enable_private_endpoints = true`, the network ACL is omitted because public access is already disabled).

## Bring-your-own components

Some pieces of a production deployment are intentionally not turnkey:

- **Container registry** - optional. Default `create_acr = false` matches the chart's GHCR default. Set `true` to opt in. To use an external registry, point the Helm chart at it via `gateway.image.repository`, `workers.common.image.repository`, and `config.image.repository`.
- **TLS certificate** - BYO by default. Set `ingress.tlsConfig.mode` to one of: `byo` (supply your own `kubernetes.io/tls` Secret), `cert-manager` (annotates Ingress for Let's Encrypt HTTP-01; requires cert-manager in the cluster), `self-signed` (chart bootstraps a self-signed root CA - for air-gapped / on-prem), or `disabled` (no TLS resources; TLS terminated upstream of the Ingress).
- **DNS / domain** - always BYO. The module does not provision Azure DNS zones or records. After `terraform apply`, take the ingress controller's LoadBalancer IP and create an A/AAAA record under a domain you control.
- **OIDC provider** - BYO. When `auth.enabled: true` in the chart, set `auth.oauth2Proxy.oidcIssuerUrl` and the corresponding client ID / secret to your existing identity provider (Okta, Auth0, Google Workspace, Azure AD, ...).

## Cleanup

```bash
terraform destroy
```

**Important**: GPU VMs can be expensive. Always destroy dev/test clusters when not in use. Spot pools (`spot = true`) can reduce cost significantly but can be evicted with no warning (`eviction_policy = "Delete"` - Azure Spot does not have an EC2-style 2-minute interruption notice).
