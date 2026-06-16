# SIE AKS Cluster — Development Example (NV6ads A10 Spot)
#
# Creates an AKS cluster with one Standard_NV6ads_A10_v5 spot GPU pool
# (NVIDIA A10), scale-to-zero (min=0), and up to 5 GPU nodes. A10 doubles
# the VRAM of T4 (24 GiB vs 16 GiB) at ~2x the cost — pick this over the
# dev-nc4ast4-spot example when running models that don't fit on T4
# (e.g. larger embedding bundles, bge-multilingual-gemma2).
#
# Terraform = cloud infra only. K8s resources deployed via Helm:
#
#   $(terraform output -raw kubectl_config_command)
#   # Populate the model cache (only if create_model_cache=true):
#   sie-admin cache populate --bundle default \
#     --target $(terraform output -raw model_cache_bucket_url)/
#   helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster \
#     -f https://raw.githubusercontent.com/superlinked/sie/main/values-aks.yaml \
#     --namespace sie --create-namespace \
#     --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$(terraform output -raw sie_workload_identity_client_id)" \
#     $(terraform output -raw model_cache_helm_args)
#
# Prerequisites:
#   1. az login + az account set --subscription <id>
#   2. Standard NVADSA10v5 family vCPU quota in the target region
#   3. SIE Docker images present in ACR — push your own with `docker push <acr>.azurecr.io/<project>/sie-server:<tag>` after `az acr login`, or use the official images from `ghcr.io/superlinked/sie-server`.
#
# Usage:
#   cd deploy/terraform/azure/examples/dev-nv6adsa10-spot
#   terraform init
#   terraform plan
#   terraform apply
#
# Cleanup:
#   terraform destroy

terraform {
  required_version = ">= 1.14"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }

  # Optional remote-state backend. Provide your own Storage Account +
  # container, then copy backend.hcl.example to backend.hcl and init with:
  #   terraform init -backend-config=backend.hcl
  # backend "azurerm" {}
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "sie-dev"
}

variable "owner" {
  description = "UPN of the human accountable for this cluster (CAF Owner tag — see the module README for the CAF tag-baseline context)."
  type        = string
}

provider "azurerm" {
  features {}

  # Required when the module's model-cache Storage Account is created
  # (`create_model_cache = true`). The module disables shared-access-key
  # auth on that account; the provider's post-create blob probe needs an
  # AAD token instead of a SAS key. Safe to leave on regardless.
  storage_use_azuread = true
}

module "sie_aks" {
  source  = "superlinked/sie/azure"
  version = "0.6.7"

  location     = var.location
  project_name = var.project_name
  owner        = var.owner
  environment  = "nonprod"

  gpu_node_pools = [
    {
      name       = "a10spot"
      gpu_class  = "a10"
      node_count = 0 # scale-to-zero when idle
      max_count  = 5
      spot       = true
      labels = {
        "sie.superlinked.com/gpu-type" = "a10"
      }
    },
  ]

  # Dev cluster — public API server is acceptable. Set
  # `api_server_authorized_ip_ranges` or `enable_private_cluster` for
  # production.
  allow_public_api_server = true

  # Dev/single-user flow: give the caller AAD-RBAC Cluster Admin so kubectl
  # works immediately after `mise run cluster create`. Production examples
  # should leave this off and bind a dedicated AAD group instead.
  grant_admin_to_creator = true

  # Allow terraform destroy to remove the cluster without unlocking first.
  deletion_protection = false

  # creates a managed Storage Account + container; remove or set false to skip.
  # The account is locked to the cluster's VNet by default — set
  # `storage_allowed_ip_ranges = ["<your-egress>/32"]` to populate the cache
  # from a laptop or CI runner outside the cluster.
  create_model_cache = true

  # creates a Premium ACR; remove or set false to skip
  create_acr = true
}

# =============================================================================
# Outputs
# =============================================================================

output "cluster_name" {
  description = "AKS cluster name"
  value       = module.sie_aks.cluster_name
}

output "kubectl_config_command" {
  description = "Run this to configure kubectl"
  value       = module.sie_aks.kubectl_config_command
}

output "sie_workload_identity_client_id" {
  description = "Client ID of the workload UAMI — pass as the azure.workload.identity/client-id SA annotation"
  value       = module.sie_aks.sie_workload_identity_client_id
}

output "workload_identity_annotation" {
  description = "Pre-composed `<annotation-key>=<client-id>` string. NOT a Helm --set RHS — see the module's infra/outputs.tf description for the full contract; for manual helm install pass `sie_workload_identity_client_id` instead."
  value       = module.sie_aks.workload_identity_annotation
}

output "acr_login_server" {
  description = "ACR login server (use with docker login or az acr login)"
  value       = module.sie_aks.acr_login_server
}

output "acr_server_repository_url" {
  description = "ACR repository URL for sie-server images"
  value       = module.sie_aks.acr_server_repository_url
}

output "acr_gateway_repository_url" {
  description = "ACR repository URL for sie-gateway images"
  value       = module.sie_aks.acr_gateway_repository_url
}

output "acr_config_repository_url" {
  description = "ACR repository URL for sie-config images"
  value       = module.sie_aks.acr_config_repository_url
}

output "model_cache_bucket_url" {
  description = "Model cache URL — pass to Helm as workers.common.clusterCache.url"
  value       = module.sie_aks.model_cache_bucket_url
}

output "model_cache_helm_args" {
  description = "Helm --set arguments to enable the cluster cache"
  value       = module.sie_aks.model_cache_helm_args
}
