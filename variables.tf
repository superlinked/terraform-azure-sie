# SIE AKS Cluster — Infrastructure Variables
#
# Variables for Azure-only resources (no K8s/Helm configuration except for
# the NVIDIA device plugin Helm release).

# =============================================================================
# Required Variables
# =============================================================================

variable "location" {
  description = "Azure region for all resources (e.g., westeurope, eastus, swedencentral)."
  type        = string
  default     = "westeurope"
}

variable "project_name" {
  description = "Project name used as prefix for all resource names. Final names follow the {project_name}{suffix} pattern defined in naming.tf."
  type        = string
  default     = "sie"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-24 lowercase alphanumeric characters or hyphens (Azure resource name limits)."
  }
}

variable "tags" {
  description = "Additional tags applied to every tag-supporting resource on top of the CAF baseline (Environment, Owner, CostCenter, Workload) and the SIE-specific identifiers (project, sie-cluster)."
  type        = map(string)
  default = {
    "managed-by" = "terraform"
    "app"        = "sie"
  }
}

# =============================================================================
# CAF baseline tags
# =============================================================================
# Azure CAF landing zones typically enforce four taxonomy tags (Environment,
# Owner, CostCenter, Workload) via subscription-scope Audit/Deny policy. The
# variables below populate all four automatically so the module's resources
# don't get flagged where such a policy is in effect — and they remain useful
# for cost attribution regardless. Every tag-supporting resource and resource
# group below must carry all four.

variable "environment" {
  description = "CAF Environment tag. Lifecycle stage. One of: prod, nonprod, sandbox, shared."
  type        = string
  default     = "nonprod"

  validation {
    condition     = contains(["prod", "nonprod", "sandbox", "shared"], var.environment)
    error_message = "environment must be one of: prod, nonprod, sandbox, shared (CAF taxonomy)."
  }
}

variable "owner" {
  description = "CAF Owner tag. UPN of the human accountable for these resources — not a team. Example: alice@example.com."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner))
    error_message = "owner must be a UPN such as alice@example.com."
  }
}

variable "cost_center" {
  description = "CAF CostCenter tag. Internal cost attribution string. Example: sie-platform, sie-research, infra."
  type        = string
  default     = "sie-platform"
}

variable "workload" {
  description = "CAF Workload tag. Logical workload identifier. Example: sie."
  type        = string
  default     = "sie"
}

# =============================================================================
# Network Configuration
# =============================================================================

variable "vnet_cidr" {
  description = "CIDR block for the VNet."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "system_subnet_cidr" {
  description = "CIDR block for the AKS system node-pool subnet."
  type        = string
  default     = "10.0.0.0/22"
}

variable "gpu_subnet_cidr" {
  description = "CIDR block for the AKS GPU node-pool subnet."
  type        = string
  default     = "10.0.4.0/22"
}

variable "private_endpoint_subnet_cidr" {
  description = "CIDR block for the subnet holding private endpoints (ACR, Storage, Key Vault)."
  type        = string
  default     = "10.0.8.0/24"
}

# =============================================================================
# AKS Configuration
# =============================================================================

variable "kubernetes_version" {
  description = "Kubernetes version (null = use AKS default for the chosen region)."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Place a CanNotDelete management lock on the AKS cluster so accidental `terraform destroy` (or portal click) is blocked. Default true so production clusters get the safety net. Set false for dev/test clusters that should be destroyable."
  type        = bool
  default     = true
}

variable "automatic_upgrade_channel" {
  description = "AKS automatic upgrade channel — controls how the control plane and node images receive minor/patch updates. One of: patch, rapid, stable, node-image, none. Default stable follows the AKS recommended posture."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["patch", "rapid", "stable", "node-image", "none"], var.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be one of: patch, rapid, stable, node-image, none."
  }
}

variable "enable_private_cluster" {
  description = "Enable AKS private cluster (API server reachable only via private endpoint)."
  type        = bool
  default     = false
}

variable "local_account_disabled" {
  description = <<-EOT
    Disable AKS local (static certificate) accounts. Default false because the
    in-module Kubernetes and Helm providers authenticate via the cluster's
    kube_config certificates to install the NVIDIA device plugin. Set true in
    production after binding an Azure AD group to cluster-admin RBAC and
    reconfiguring the providers to use an exec/kubelogin flow; otherwise the
    NVIDIA device plugin install will fail with an empty kube_config.
  EOT
  type        = bool
  default     = false
}

variable "grant_admin_to_creator" {
  description = <<-EOT
    Grant the calling identity (terraform's `azurerm_client_config.current`)
    the "Azure Kubernetes Service RBAC Cluster Admin" role on this cluster.
    Set true in single-developer / dev-cluster examples so the operator who
    just ran `terraform apply` can immediately
    `kubectl ...` against AAD-enabled AKS without a separate out-of-band role
    assignment. Leave false in shared/production clusters that bind admin
    via a dedicated AAD group instead.
  EOT
  type        = bool
  default     = false
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDR blocks authorized to reach the AKS API server. Empty list means no IP allowlist (AKS treats this as open). Combine with enable_private_cluster or allow_public_api_server."
  type        = list(string)
  default     = []
}

variable "allow_public_api_server" {
  description = "Escape hatch to allow a publicly reachable AKS API server (no IP allowlist, no private cluster). Default false so the module fails the plan if neither enable_private_cluster nor api_server_authorized_ip_ranges is set. Flip to true only for short-lived dev clusters."
  type        = bool
  default     = false
}

variable "public_load_balancer_ports" {
  description = "Inbound TCP ports allowed from the Internet to the system node subnet for Kubernetes LoadBalancer / ingress Services. The module's subnet NSG must allow these or its default DenyAllInBound drops the traffic: AKS programs LoadBalancer rules only on its own NIC-level NSG, not a user-managed subnet NSG. Defaults cover ingress-nginx (80/443) and a directly-exposed gateway LoadBalancer on 8080. Set to [] for private clusters that take no public inbound."
  type        = list(string)
  default     = ["80", "443", "8080"]
}

variable "system_node_pool" {
  description = <<-EOT
    System node pool configuration (kube-system, monitoring, ingress controllers).

    `zones` default `["1","2","3"]` covers most Azure regions, but a handful
    of regions do not expose zone 1 (francecentral, southafricawest,
    brazilsoutheast, swedensouth, others). The location_zone_constraint
    precondition on azurerm_kubernetes_cluster.main catches this at plan
    time and tells you which zones to pass for the chosen location.

    `vm_size` default `Standard_D4s_v3` is 4 vCPU / 16 GiB and zoned
    across every Azure region we've checked. `standardDSv3Family` quota
    is granted by default on fresh subscriptions, so this default also
    plans cleanly without filing a quota request. A previous default
    `Standard_B4ms` (the AWS t3.xlarge analog) was reverted on 2026-06-11
    because the B-series is non-zonal on Azure: every region we sampled
    (westeurope, northeurope, eastus, swedencentral, francecentral,
    germanywestcentral, switzerlandnorth, uksouth) returns an empty
    `zones` list for `Standard_B4ms`, and AKS rejects zoned
    default_node_pools with non-zoned SKUs at apply time with
    `AvailabilityZoneNotSupported`. Pass `Standard_B4ms` only with
    `zones = []` (single-zone deploy, no HA). Pass `Standard_D4s_v5` for
    a newer fixed-perf SKU once your subscription has DSv5 quota; the
    module does not enforce a SKU set — apply-time errors from AKS
    surface the exact quota family at fault.

    `only_critical_addons_enabled` taints the system pool with
    `CriticalAddonsOnly=true:NoSchedule` so only cluster-critical add-ons
    (coredns, kube-proxy, metrics-server, etc.) can land on it. Azure
    recommends `true` for production to keep user workloads from competing
    with the control-plane add-ons. The module default is `false` because
    the shipped sie-cluster Helm chart does not add `CriticalAddonsOnly`
    tolerations to the SIE gateway / sie-config / KEDA / Prometheus
    workloads, so flipping this to `true` requires either provisioning a
    dedicated user node pool for those workloads or adding the toleration
    via the chart values overlay.
  EOT
  type = object({
    vm_size                      = string
    min_count                    = number
    max_count                    = number
    os_disk_size_gb              = optional(number, 100)
    zones                        = optional(list(string), ["1", "2", "3"])
    only_critical_addons_enabled = optional(bool, false)
  })
  default = {
    vm_size   = "Standard_D4s_v3"
    min_count = 1
    max_count = 5
  }

  validation {
    condition     = var.system_node_pool.min_count >= 1 && var.system_node_pool.max_count >= var.system_node_pool.min_count
    error_message = "system_node_pool requires min_count >= 1 (AKS rejects 0) and max_count >= min_count."
  }
}

variable "auto_scaler_scale_down_unneeded" {
  description = "Cluster autoscaler scale-down-unneeded interval. Conservative default to avoid churning nodes on transient idle windows."
  type        = string
  default     = "10m"
}

variable "auto_scaler_scale_down_delay_after_add" {
  description = "Cluster autoscaler scale-down-delay-after-add interval. Conservative default to avoid scaling down right after a recent scale-up."
  type        = string
  default     = "10m"
}

# =============================================================================
# Workload Identity
# =============================================================================

variable "sie_namespace" {
  description = "Kubernetes namespace where SIE workloads run."
  type        = string
  default     = "sie"
}

variable "sie_service_account_name" {
  description = "Kubernetes ServiceAccount that federates to the workload UAMI."
  type        = string
  default     = "sie-server"
}

# =============================================================================
# Kubelet Log Retention
# =============================================================================

variable "kubelet_container_log_max_size_mb" {
  description = "Maximum size in MB of a single kubelet-managed container log file before rotation. AKS exposes this value as an integer count of MB (not a Kubernetes quantity string)."
  type        = number
  default     = 20

  validation {
    condition     = floor(var.kubelet_container_log_max_size_mb) == var.kubelet_container_log_max_size_mb && var.kubelet_container_log_max_size_mb >= 1
    error_message = "kubelet_container_log_max_size_mb must be a positive integer."
  }
}

variable "kubelet_container_log_max_files" {
  description = "Maximum number of rotated kubelet-managed container log files to retain per container."
  type        = number
  default     = 30

  validation {
    condition     = var.kubelet_container_log_max_files >= 2 && floor(var.kubelet_container_log_max_files) == var.kubelet_container_log_max_files
    error_message = "kubelet_container_log_max_files must be an integer at least 2."
  }
}

# =============================================================================
# GPU Node Pools
# =============================================================================
#
# A single resource (azurerm_kubernetes_cluster_node_pool) is expanded with
# for_each over this list. Adding A100 / H100 once quota is granted is a
# values-only change — no new resource blocks, no module restructuring.
#
# `gpu_class` drives a defaults lookup in node_pools.tf so callers only need
# to specify `gpu_class = "t4"` (or "a10", "a100", "h100") and an optional
# `vm_size` override.

variable "gpu_node_pools" {
  description = "GPU node pool configurations. One azurerm_kubernetes_cluster_node_pool is generated per entry."
  type = list(object({
    name            = string
    gpu_class       = string              # "t4" | "a10" | "a100" | "h100"
    vm_size         = optional(string)    # null → use gpu_class default
    node_count      = optional(number, 0) # min nodes (0 = scale-to-zero)
    max_count       = optional(number, 10)
    os_disk_size_gb = optional(number, 200)
    spot            = optional(bool, false)
    spot_max_price  = optional(number, -1) # -1 = on-demand price ceiling
    zones           = optional(list(string), ["1", "2", "3"])
    labels          = optional(map(string), {})
    node_taints     = optional(list(string), ["nvidia.com/gpu=present:NoSchedule"])
  }))
  default = []

  validation {
    condition = alltrue([
      for p in var.gpu_node_pools : contains(["t4", "a10", "a100", "h100"], p.gpu_class)
    ])
    error_message = "Each gpu_node_pools[*].gpu_class must be one of: t4, a10, a100, h100."
  }

  validation {
    condition     = length(var.gpu_node_pools) == length(distinct([for p in var.gpu_node_pools : p.name]))
    error_message = "gpu_node_pools[*].name must be unique."
  }

  validation {
    condition = alltrue([
      for p in var.gpu_node_pools : p.name != "default" && can(regex("^[a-z][a-z0-9]{0,11}$", p.name))
    ])
    error_message = "gpu_node_pools[*].name must be 1-12 lowercase alphanumeric chars (Azure AKS pool name limit) and must not be \"default\"."
  }

  validation {
    condition = alltrue([
      for p in var.gpu_node_pools : floor(p.os_disk_size_gb) == p.os_disk_size_gb && p.os_disk_size_gb >= 30
    ])
    error_message = "Each gpu_node_pools[*].os_disk_size_gb must be an integer at least 30."
  }

  validation {
    condition = alltrue([
      for p in var.gpu_node_pools : p.node_count >= 0 && p.max_count >= 1 && p.max_count >= p.node_count
    ])
    error_message = "Each gpu_node_pools[*] requires node_count >= 0, max_count >= 1, and max_count >= node_count."
  }
}

# =============================================================================
# Container Registry (ACR)
# =============================================================================

variable "acr_sku" {
  description = "ACR SKU: Basic, Standard, or Premium. Premium is required for retention policies, content trust, geo-replication, and private endpoints. Default Premium so private endpoints + retention work; downgrade to Standard or Basic for cost-sensitive dev clusters that don't need those features."
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be one of: Basic, Standard, Premium."
  }
}

variable "create_acr" {
  description = "Whether this module manages the Azure Container Registry. Default `false` defers to the chart's GHCR-hosted images and avoids registry-name collisions on subscriptions where ACR is externally managed. Set `true` to opt in. The acr_*_repository_url outputs are emitted regardless."
  type        = bool
  default     = false
}

variable "acr_name" {
  description = "Override for the ACR name. When null, defaults to a globally-unique \"<project_name_alphanum>acr<suffix>\". ACR names are 5-50 alphanumeric chars globally unique."
  type        = string
  default     = null
}

variable "server_acr_repository_name" {
  description = "Repository name within the ACR for sie-server images."
  type        = string
  default     = "sie-server"
}

variable "gateway_acr_repository_name" {
  description = "Repository name within the ACR for sie-gateway images."
  type        = string
  default     = "sie-gateway"
}

variable "config_acr_repository_name" {
  description = "Repository name within the ACR for sie-config images."
  type        = string
  default     = "sie-config"
}

variable "acr_repository_prefix" {
  description = "Namespace prefix for ACR repository names — final paths become \"<prefix>/<repo_name>\". When null, defaults to var.project_name (prevents collisions for two engineers sharing an account). Set to \"\" to disable prefixing (bare names — needed when ACR is externally managed under bare names)."
  type        = string
  default     = null
}

# =============================================================================
# Model cache + payload store (Storage Account + Blob container)
# =============================================================================
# When `create_model_cache = true` the module provisions a single Storage
# Account with one blob container (`sie-cache`) that serves two co-tenant
# workloads at sibling top-level prefixes inside the container:
#
#   abfs://sie-cache@<account>.dfs.core.windows.net/models/...
#       Model weights, populated by `sie-admin cache populate` and read
#       by SIE workers at startup. Long-lived; no lifecycle expiration.
#
#   abfs://sie-cache@<account>.dfs.core.windows.net/payloads/...
#       Large work-item payloads (images, long documents) that exceed the
#       in-band 1MiB NATS message budget. Written by sie-gateway on each
#       request and read once by a worker. Garbage-collected by the runtime
#       TTL (300s by default) and by a storage lifecycle rule (1 day) for
#       any orphans.
#
# Identity uses ABAC role-assignment conditions to scope each role to its
# prefix (see identity.tf). The principle is least-privilege: the workload
# identity can read weights but cannot delete or overwrite them, and can
# write payloads but cannot touch weights.

variable "create_model_cache" {
  description = "Create the managed Storage Account + Blob container backing the model-weights cache (models/) and the payload store for work items >1MB (payloads/). The payload store is required for large payloads such as images, so this defaults to true. Set false only if you bring your own storage (and wire payloadStore.url) or accept that >1MB requests fail."
  type        = bool
  default     = true
}

variable "model_cache_account_name" {
  description = "Override for the model-cache storage account name. When null, generates <project_alphanum_truncated_to_11>cache<random 4-byte hex>. Storage account names must be 3-24 lowercase alphanumeric chars and globally unique."
  type        = string
  default     = null

  validation {
    condition     = var.model_cache_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.model_cache_account_name))
    error_message = "model_cache_account_name must be 3-24 lowercase alphanumeric characters (Azure storage account naming rule)."
  }
}

variable "model_cache_container_name" {
  description = "Name of the blob container that holds both the model cache and the payload store."
  type        = string
  default     = "sie-cache"
}

variable "model_cache_versioning_enabled" {
  description = "Enable blob versioning on the model cache container. Default false; cache files are immutable per (repo, sha) so versioning adds storage cost with no benefit."
  type        = bool
  default     = false
}

variable "model_cache_kms_key_id" {
  description = "Resource ID of a Key Vault key for CMEK on the model cache account. When null, the account uses Microsoft-managed keys."
  type        = string
  default     = null
}

variable "model_cache_payload_expiration_days" {
  description = "Lifecycle expiration in days for blobs under the `payloads/` prefix. The runtime TTL on the gateway (300s by default) is the primary GC; this rule is the long-tail safety net."
  type        = number
  default     = 1

  validation {
    condition     = var.model_cache_payload_expiration_days >= 1 && floor(var.model_cache_payload_expiration_days) == var.model_cache_payload_expiration_days
    error_message = "model_cache_payload_expiration_days must be an integer at least 1."
  }
}

variable "storage_allowed_ip_ranges" {
  description = "Public IP CIDR ranges that bypass the model-cache storage account's Deny default. Use for operators or CI runners outside the cluster VNet that need to populate the cache (e.g. `sie-admin cache populate`). Ignored when enable_private_endpoints = true."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for raw_cidr in var.storage_allowed_ip_ranges : (
        length(trimspace(raw_cidr)) > 0
        && can(cidrhost(trimspace(raw_cidr), 0))
        && !contains(["0.0.0.0/0", "::/0"], trimspace(raw_cidr))
      )
    ])
    error_message = "storage_allowed_ip_ranges entries must be valid CIDRs and must not be 0.0.0.0/0 or ::/0 (Azure Storage rejects these and they defeat the point of the Deny default)."
  }
}

variable "storage_allowed_subnet_ids" {
  description = "Subnet IDs that bypass the model-cache storage account's Deny default. When null (the default) the module auto-populates the cluster's system + GPU subnets so the workloads can reach the cache. Pass an explicit list to override (e.g. add a bastion subnet). Pass [] to allow no subnets. Ignored when enable_private_endpoints = true. Caller-supplied subnets must have the `Microsoft.Storage` service endpoint enabled."
  type        = list(string)
  default     = null
}

# =============================================================================
# Private endpoints
# =============================================================================

variable "create_ingress_public_ip" {
  description = <<-EOT
    Provision a static public IP for the ingress controller in this module's
    resource group. Because the IP lives in the cluster RG (not the
    AKS-managed MC_<...> group), it survives cluster destroy/recreate cycles
    and can be pre-pointed in DNS. Pass the IP into the ingress-nginx Helm
    chart via the `ingress_public_ip` / `ingress_helm_args` outputs. Default
    false to match the module's other `create_*` opt-ins; flip to true for
    clusters with stable DNS.
  EOT
  type        = bool
  default     = false
}

variable "enable_private_endpoints" {
  description = "Provision private endpoints + private DNS zones for ACR and the model-cache Storage Account. When true, public_network_access on those resources is set to false."
  type        = bool
  default     = false
}

# =============================================================================
# Observability
# =============================================================================

variable "enable_cloud_logging" {
  description = "Enable AKS Container Insights + diagnostic settings for control-plane logs to a Log Analytics workspace."
  type        = bool
  default     = true
}

variable "enable_managed_prometheus" {
  description = "Enable AKS Managed Prometheus (azurerm_monitor_workspace + monitor_metrics block on the cluster)."
  type        = bool
  default     = false
}
