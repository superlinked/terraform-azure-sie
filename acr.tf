# SIE AKS Cluster — Azure Container Registry
#
# One ACR holds three sibling repositories (sie-server / sie-gateway /
# sie-config) under a project-name prefix. ACR repos are auto-created on
# first push, so this module provisions the registry, the retention policy,
# and the AcrPull role assignments only.

# =============================================================================
# Effective name + URL composition
# =============================================================================
# Compose the URL strings from inputs rather than reading them off the
# resource attribute so they remain valid whether the registry is managed
# here or pre-existing.

locals {
  project_alphanum = lower(replace(var.project_name, "-", ""))

  # NOTE: nested ternary, not coalesce(). Terraform's coalesce() is eager — it
  # evaluates every argument before picking, so when var.create_acr=true AND
  # var.acr_name is set, random_string.acr_suffix has count=0 and indexing
  # [0].result raises "invalid index" even though the value is unused.
  # The conditional below is lazy and only references the random_string when
  # var.acr_name is null (the same condition that gates count=1 on the resource).
  acr_name_effective = (
    var.create_acr
    ? (var.acr_name != null ? var.acr_name : "${local.project_alphanum}acr${random_string.acr_suffix[0].result}")
    : var.acr_name
  )

  acr_login_server = (
    local.acr_name_effective != null
    ? "${local.acr_name_effective}.azurecr.io"
    : null
  )

  acr_repository_prefix_effective = var.acr_repository_prefix == null ? var.project_name : trim(var.acr_repository_prefix, "/")
  acr_repository_name_prefix      = local.acr_repository_prefix_effective == "" ? "" : "${local.acr_repository_prefix_effective}/"

  acr_server_repository_full_name  = "${local.acr_repository_name_prefix}${var.server_acr_repository_name}"
  acr_gateway_repository_full_name = "${local.acr_repository_name_prefix}${var.gateway_acr_repository_name}"
  acr_config_repository_full_name  = "${local.acr_repository_name_prefix}${var.config_acr_repository_name}"

  acr_server_repository_url  = local.acr_login_server == null ? null : "${local.acr_login_server}/${local.acr_server_repository_full_name}"
  acr_gateway_repository_url = local.acr_login_server == null ? null : "${local.acr_login_server}/${local.acr_gateway_repository_full_name}"
  acr_config_repository_url  = local.acr_login_server == null ? null : "${local.acr_login_server}/${local.acr_config_repository_full_name}"
}

resource "random_string" "acr_suffix" {
  count   = var.create_acr && var.acr_name == null ? 1 : 0
  length  = 6
  special = false
  upper   = false
  numeric = true
}

# =============================================================================
# ACR resource
# =============================================================================

resource "azurerm_container_registry" "sie" {
  count = var.create_acr ? 1 : 0

  name                = local.acr_name_effective
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku           = var.acr_sku
  admin_enabled = false

  # When private endpoints are enabled, lock the registry to private network
  # access only. Otherwise leave the default (public + AAD-gated). Note that
  # ACR private endpoints require Premium SKU; the precondition below blocks
  # the unsupported combination at plan time.
  public_network_access_enabled = !var.enable_private_endpoints
  network_rule_bypass_option    = "AzureServices"

  # Retention policy is a Premium-only feature. Set null on Basic/Standard.
  retention_policy_in_days = var.acr_sku == "Premium" ? 30 : null
  trust_policy_enabled     = false

  tags = local.resource_tags

  lifecycle {
    precondition {
      condition     = !var.enable_private_endpoints || var.acr_sku == "Premium"
      error_message = "ACR private endpoints require Premium SKU. Set acr_sku = \"Premium\" or disable enable_private_endpoints."
    }
  }
}

# =============================================================================
# AcrPull role assignments
# =============================================================================
# The kubelet UAMI pulls images during pod startup. The workload UAMI can
# also pull (for any in-pod registry clients).

resource "azurerm_role_assignment" "kubelet_acrpull" {
  count = var.create_acr ? 1 : 0

  scope                = azurerm_container_registry.sie[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
}

resource "azurerm_role_assignment" "workload_acrpull" {
  count = var.create_acr ? 1 : 0

  scope                = azurerm_container_registry.sie[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}
