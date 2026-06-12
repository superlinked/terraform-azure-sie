# SIE AKS Cluster — Private Endpoints
#
# Private DNS zones + private endpoints for the managed ACR and the model-
# cache Storage Account, giving the cluster subnets private connectivity to
# those services without traversing the public internet.
#
# Opt-in via var.enable_private_endpoints. When false, ACR + Storage stay on
# the public endpoint (still AAD-gated and TLS-required).

# =============================================================================
# Private DNS zones
# =============================================================================

resource "azurerm_private_dns_zone" "acr" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.resource_tags
}

resource "azurerm_private_dns_zone" "blob" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.resource_tags
}

resource "azurerm_private_dns_zone" "dfs" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "privatelink.dfs.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.resource_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count = var.enable_private_endpoints ? 1 : 0

  name                  = "${local.names.cluster}-acr-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.resource_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count = var.enable_private_endpoints ? 1 : 0

  name                  = "${local.names.cluster}-blob-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.resource_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "dfs" {
  count = var.enable_private_endpoints ? 1 : 0

  name                  = "${local.names.cluster}-dfs-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.dfs[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.resource_tags
}

# =============================================================================
# Private endpoints
# =============================================================================

resource "azurerm_private_endpoint" "acr" {
  count = var.enable_private_endpoints && var.create_acr ? 1 : 0

  name                = "${local.names.cluster}-acr-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.names.cluster}-acr-psc"
    private_connection_resource_id = azurerm_container_registry.sie[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }

  tags = local.resource_tags
}

resource "azurerm_private_endpoint" "blob" {
  count = var.enable_private_endpoints && var.create_model_cache ? 1 : 0

  name                = "${local.names.cluster}-blob-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.names.cluster}-blob-psc"
    private_connection_resource_id = azurerm_storage_account.model_cache[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }

  tags = local.resource_tags
}

resource "azurerm_private_endpoint" "dfs" {
  count = var.enable_private_endpoints && var.create_model_cache ? 1 : 0

  name                = "${local.names.cluster}-dfs-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.names.cluster}-dfs-psc"
    private_connection_resource_id = azurerm_storage_account.model_cache[0].id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dfs"
    private_dns_zone_ids = [azurerm_private_dns_zone.dfs[0].id]
  }

  tags = local.resource_tags
}
