# SIE Model Cache and Payload Store — Storage Account + Blob Container
#
# Provisions a single managed Storage Account with one blob container that
# serves both the model cache (under models/) and the gateway payload store
# (under payloads/). Both prefixes are independently IAM-scoped via ABAC
# conditions on role assignments.
#
# Opt-in via var.create_model_cache.
#
# IMPORTANT: callers MUST set `storage_use_azuread = true` on their
# azurerm provider block when var.create_model_cache = true. This module
# disables shared-access-key auth (`shared_access_key_enabled = false`),
# so the provider's post-create blob-service probe needs an AAD token
# instead of a SAS key. Without the provider setting, apply fails with
# `403 KeyBasedAuthenticationNotPermitted` immediately after the storage
# account is created. See examples/dev-nc4ast4-spot/main.tf for the
# provider configuration.

locals {
  normalized_model_cache_account_name = (
    var.model_cache_account_name == null || trimspace(var.model_cache_account_name) == ""
    ? null
    : lower(trimspace(var.model_cache_account_name))
  )
}

resource "random_id" "model_cache_suffix" {
  count       = var.create_model_cache && local.normalized_model_cache_account_name == null ? 1 : 0
  byte_length = 4
}

locals {
  # Azure storage account names are 3-24 lowercase alphanumeric, globally
  # unique. The auto-generated form is "<project>cache<random hex>"; we
  # truncate the project portion to 11 chars so the worst case stays within
  # 11 + 5 ("cache") + 8 (random_id.byte_length=4 → 8 hex chars) = 24.
  project_alphanum_cache_prefix = substr(local.project_alphanum, 0, 11)

  model_cache_account_name_effective = (
    var.create_model_cache
    ? coalesce(local.normalized_model_cache_account_name, "${local.project_alphanum_cache_prefix}cache${try(random_id.model_cache_suffix[0].hex, "")}")
    : null
  )

  # Network ACL allowlist for the model-cache storage account. When
  # var.storage_allowed_subnet_ids is null the module auto-allows the cluster's
  # own system + GPU subnets so the workloads can reach the cache. Callers can
  # pass an explicit list (including []) to override.
  storage_default_allowed_subnet_ids = [
    azurerm_subnet.system.id,
    azurerm_subnet.gpu.id,
  ]
  storage_effective_allowed_subnet_ids = (
    var.storage_allowed_subnet_ids != null
    ? var.storage_allowed_subnet_ids
    : local.storage_default_allowed_subnet_ids
  )
}

# =============================================================================
# Storage account
# =============================================================================

resource "azurerm_storage_account" "model_cache" {
  count = var.create_model_cache ? 1 : 0

  name                = local.model_cache_account_name_effective
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  infrastructure_encryption_enabled = true
  allow_nested_items_to_be_public   = false
  default_to_oauth_authentication   = true

  # Enable Hierarchical Namespace (Data Lake Gen2) so the cluster cache URL
  # can use the `abfs://` scheme that the SIE chart's clusterCache + payload
  # store expects. NOTE: HNS is a one-way door — once enabled it cannot be
  # disabled. Migrating to a flat-namespace account requires destroying and
  # recreating the storage account (and the data in it). If you want to
  # `import` an existing flat-namespace account into this module later, the
  # account types are incompatible and import will fail.
  is_hns_enabled = true

  public_network_access_enabled = !var.enable_private_endpoints

  # Network ACL. When enable_private_endpoints = true, public access is
  # already off above, so the ACL would never be consulted — skip it to keep
  # the resource minimal. Otherwise: Deny by default, allow only the cluster's
  # workload subnets (auto-populated) and any caller-supplied operator IPs.
  dynamic "network_rules" {
    for_each = var.enable_private_endpoints ? [] : [1]
    content {
      default_action             = "Deny"
      bypass                     = ["AzureServices"]
      virtual_network_subnet_ids = local.storage_effective_allowed_subnet_ids
      ip_rules                   = var.storage_allowed_ip_ranges
    }
  }

  blob_properties {
    versioning_enabled = var.model_cache_versioning_enabled

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.resource_tags
}

# =============================================================================
# Optional CMEK
# =============================================================================
# When var.model_cache_kms_key_id is set, encrypt the account with the
# supplied Key Vault key. The user is responsible for provisioning the key
# and granting the storage account access to it (see README).

resource "azurerm_storage_account_customer_managed_key" "model_cache" {
  count = var.create_model_cache && var.model_cache_kms_key_id != null ? 1 : 0

  storage_account_id = azurerm_storage_account.model_cache[0].id
  key_vault_key_id   = var.model_cache_kms_key_id
}

# =============================================================================
# Blob container
# =============================================================================

resource "azurerm_storage_container" "model_cache" {
  count = var.create_model_cache ? 1 : 0

  name                  = var.model_cache_container_name
  storage_account_id    = azurerm_storage_account.model_cache[0].id
  container_access_type = "private"
}

# =============================================================================
# Lifecycle: GC payloads/ after N days
# =============================================================================
# Direct parity with the S3/GCS payloads-1d rule. Day granularity is a Storage
# lifecycle limit; the runtime TTL (default 300s) is the primary GC. Models/
# is not affected.

resource "azurerm_storage_management_policy" "model_cache" {
  count = var.create_model_cache ? 1 : 0

  storage_account_id = azurerm_storage_account.model_cache[0].id

  rule {
    name    = "expire-payloads"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${var.model_cache_container_name}/payloads/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.model_cache_payload_expiration_days
      }
    }
  }
}

# =============================================================================
# Workload identity bindings — ABAC-scoped
# =============================================================================
# Two role assignments on the storage account, each with an ABAC condition
# scoping the role to a single top-level prefix in the container.
#
#   models/    Storage Blob Data Reader      (workload UAMI)
#   payloads/  Storage Blob Data Contributor (workload UAMI)
#
# Implemented as two built-in role assignments with ABAC StringStartsWith
# conditions. The condition strings use Azure's ABAC condition language: the
# `Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path`
# attribute is matched against the prefix.

locals {
  models_prefix_condition = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}
          AND NOT SubOperationMatches{'Blob.List'})
      )
      OR
      @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringStartsWithIgnoreCase 'models/'
    )
  EOT

  payloads_prefix_condition = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}
          AND NOT SubOperationMatches{'Blob.List'})
        AND
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
        AND
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})
      )
      OR
      @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringStartsWithIgnoreCase 'payloads/'
    )
  EOT
}

resource "azurerm_role_assignment" "workload_models_reader" {
  count = var.create_model_cache ? 1 : 0

  scope                = azurerm_storage_container.model_cache[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id

  condition         = local.models_prefix_condition
  condition_version = "2.0"
  description       = "Read-only on models/ prefix only."
}

resource "azurerm_role_assignment" "workload_payloads_rw" {
  count = var.create_model_cache ? 1 : 0

  scope                = azurerm_storage_container.model_cache[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id

  condition         = local.payloads_prefix_condition
  condition_version = "2.0"
  description       = "Read+write+delete on payloads/ prefix only."
}
