# SIE AKS Cluster — Infrastructure Module
#
# Azure-only resources: resource group, VNet, AKS cluster, GPU node pools,
# managed identities, federated credentials, ACR, model-cache storage.
# Kubernetes + Helm providers are wired to the AKS user credentials so
# in-cluster resources (the NVIDIA device plugin) can be installed by the
# same apply.

# =============================================================================
# Data sources
# =============================================================================

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

# =============================================================================
# Local variables
# =============================================================================

locals {
  # Suffix-driven names (see naming.tf for the single source of truth).
  names = {
    for key, suffix in local.name_suffixes :
    key => "${var.project_name}${suffix}"
  }

  # CAF baseline tags. Keys are PascalCase to match the parameter names
  # used by typical Azure CAF landing-zone tag-baseline policies.
  caf_tags = {
    "Environment" = var.environment
    "Owner"       = var.owner
    "CostCenter"  = var.cost_center
    "Workload"    = var.workload
  }

  # Standard tags applied to every tag-supporting Azure resource. Order
  # matters: callers' var.tags come first, then the SIE identifiers, then
  # the CAF baseline. The CAF and SIE literals come last so they always win
  # over var.tags — "Environment", "Workload", "project", "sie-cluster" are
  # uniform across clusters regardless of caller input.
  resource_tags = merge(
    var.tags,
    {
      "project"     = "sie"
      "sie-cluster" = var.project_name
    },
    local.caf_tags,
  )

  # Kubernetes node labels. Kept separate from resource_tags because
  # Azure tag rules are looser than Kubernetes label rules — passing
  # arbitrary var.tags into node_labels can fail AKS create/update on
  # spaces, slashes, or values longer than 63 chars. Only the curated
  # project + cluster identifiers, both regex-safe, end up on nodes.
  resource_labels = {
    "project"     = "sie"
    "sie-cluster" = var.project_name
  }

  # Azure regions where availability zone 1 isn't available. AKS rejects
  # node pools with zone 1 in these regions with a 400 error. Hand-maintained
  # — there's no azurerm data source for AZ availability by region. Update
  # this list if Azure expands AZ support in any of these or adds new
  # restricted regions.
  locations_without_zone_1 = [
    "francecentral",
    "southafricawest",
    "brazilsoutheast",
    "swedensouth",
    "norwaywest",
    "switzerlandwest",
    "westcentralus",
  ]
}

# =============================================================================
# Resource group
# =============================================================================

resource "azurerm_resource_group" "main" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.resource_tags
}

# =============================================================================
# Provider wiring for in-cluster resources
# =============================================================================
# Helm + Kubernetes providers point at the AKS cluster created in aks.tf.
# Authentication uses the AKS user (admin disabled) kubeconfig embedded in
# the cluster resource.

# Use kube_admin_config rather than kube_config. With AAD-RBAC enabled
# (azure_rbac_enabled = true on the AKS resource), kube_config returns the
# cluster-user identity whose certificate auth is rejected — the cluster
# requires AAD tokens for that user. kube_admin_config returns the local
# admin certificate which bypasses AAD-RBAC and works for in-module
# provider auth. Populated only while var.local_account_disabled = false.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_admin_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.main.kube_admin_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate)
  }
}
