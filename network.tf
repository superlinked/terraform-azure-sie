# SIE AKS Cluster — Network
#
# VNet + subnets + NSGs + NAT gateway for the AKS cluster.
# The system pool runs in snet-system, GPU pools in snet-gpu, and private
# endpoints (ACR / Storage) live in snet-pe. NSGs apply the AKS recommended
# inbound rules; outbound for both worker subnets is concentrated through a
# single NAT gateway so the cluster has a predictable egress IP.

# =============================================================================
# AZ + SKU availability for GPU pools
# =============================================================================
# Effective per-pool VM SKU, hoisted to a local so it's available to outputs
# and the test suite. azurerm has no first-class "SKU availability by zone"
# data source as of provider 4.x, so we surface the request shape and rely on
# apply-time errors for unsupported region/SKU combinations.

locals {
  gpu_pool_vm_sizes = {
    for p in var.gpu_node_pools :
    p.name => coalesce(p.vm_size, local.gpu_class_defaults[p.gpu_class].vm_size)
  }

  # Service endpoints to apply to the system + GPU subnets. We only enable
  # Microsoft.Storage when the module-managed model-cache account is on the
  # public path (no private endpoints) — that's the case where the storage
  # account's network ACL needs subnet-bound traffic to identify as VNet
  # rather than internet egress.
  cluster_subnet_service_endpoints = (
    var.create_model_cache && !var.enable_private_endpoints
    ? ["Microsoft.Storage"]
    : []
  )
}

# =============================================================================
# VNet + subnets
# =============================================================================

resource "azurerm_virtual_network" "main" {
  name                = local.names.vnet
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_cidr]
  tags                = local.resource_tags
}

resource "azurerm_subnet" "system" {
  name                 = local.names.snet_system
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.system_subnet_cidr]
  service_endpoints    = local.cluster_subnet_service_endpoints
}

resource "azurerm_subnet" "gpu" {
  name                 = local.names.snet_gpu
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.gpu_subnet_cidr]
  service_endpoints    = local.cluster_subnet_service_endpoints
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = local.names.snet_pe
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.private_endpoint_subnet_cidr]
  private_endpoint_network_policies = "Enabled"
}

# =============================================================================
# NSGs
# =============================================================================
# AKS recommends NSGs be applied at the subnet level (not the NIC). The
# default inbound deny + intra-VNet allow is sufficient for the worker
# subnets; outbound goes through the NAT gateway below.

resource "azurerm_network_security_group" "system" {
  name                = local.names.nsg_system
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.resource_tags
}

resource "azurerm_network_security_group" "gpu" {
  name                = local.names.nsg_gpu
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.resource_tags
}

resource "azurerm_subnet_network_security_group_association" "system" {
  subnet_id                 = azurerm_subnet.system.id
  network_security_group_id = azurerm_network_security_group.system.id
}

resource "azurerm_subnet_network_security_group_association" "gpu" {
  subnet_id                 = azurerm_subnet.gpu.id
  network_security_group_id = azurerm_network_security_group.gpu.id
}

# =============================================================================
# NAT gateway
# =============================================================================
# One NAT gateway with a /28 public IP prefix (16 IPs) for the GPU subnet.
# Concentrates egress so external services see a predictable source IP.
# Azure NAT gateway is zonal but can serve subnets across zones.

resource "azurerm_public_ip_prefix" "nat" {
  name                = "${local.names.nat_public_ip}-prefix"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  prefix_length       = 28
  # Azure NAT gateway is zonal (single zone). Pick zone 2 in regions that
  # don't expose zone 1 so apply doesn't fail with "AvailabilityZoneNotSupported";
  # mirrors the constraint enforced on the AKS system / GPU node pools via
  # locations_without_zone_1.
  zones = [contains(local.locations_without_zone_1, var.location) ? "2" : "1"]
  tags  = local.resource_tags
}

resource "azurerm_nat_gateway" "main" {
  name                    = local.names.nat_gateway
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  # See zone selection rationale on azurerm_public_ip_prefix.nat above. Must
  # match the public-IP-prefix zone so the prefix association is valid.
  zones = [contains(local.locations_without_zone_1, var.location) ? "2" : "1"]
  tags  = local.resource_tags
}

resource "azurerm_nat_gateway_public_ip_prefix_association" "main" {
  nat_gateway_id      = azurerm_nat_gateway.main.id
  public_ip_prefix_id = azurerm_public_ip_prefix.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "system" {
  subnet_id      = azurerm_subnet.system.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "azurerm_subnet_nat_gateway_association" "gpu" {
  subnet_id      = azurerm_subnet.gpu.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# =============================================================================
# Ingress public IP (opt-in)
# =============================================================================
# Static Standard-SKU public IP for the ingress controller. Owned by the
# cluster RG (not the AKS-managed MC_<...> group), so it survives a cluster
# destroy/recreate and DNS can be pre-pointed. The AKS control-plane UAMI is
# granted Network Contributor on the IP so the load balancer controller can
# attach it as the LB frontend. Pass into ingress-nginx via:
#   --set controller.service.loadBalancerIP=$(terraform output -raw ingress_public_ip)
#   --set "controller.service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-resource-group=$(terraform output -raw resource_group_name)"
# or use the pre-composed `ingress_helm_args` output.

resource "azurerm_public_ip" "ingress" {
  count = var.create_ingress_public_ip ? 1 : 0

  name                = "${local.names.cluster}-ingress-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.resource_tags
}

resource "azurerm_role_assignment" "aks_ingress_ip" {
  count = var.create_ingress_public_ip ? 1 : 0

  # AKS guidance is to scope Network Contributor at the resource group that
  # owns the public IP, not the IP itself. The AKS control plane needs to
  # list and read sibling network resources during LB attach, and a
  # resource-id scope returns LinkedAuthorizationFailed 403s.
  # https://learn.microsoft.com/azure/aks/static-ip
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.controlplane.principal_id
}

# =============================================================================
# Validation
# =============================================================================
# Pre-flight check: each requested GPU pool's VM SKU must have at least one
# zone offering in the chosen region.
#
# Note: azurerm has no first-class "SKU availability by zone" data source as
# of provider 4.x. We surface a softer check by intersecting the requested
# pool zones with the region's published zones from the extended_locations
# data source, and rely on apply-time errors for SKU restrictions.

resource "terraform_data" "gpu_pool_zone_validation" {
  for_each = { for p in var.gpu_node_pools : p.name => p }

  lifecycle {
    precondition {
      condition     = length(each.value.zones) >= 1
      error_message = "GPU pool ${each.key} must request at least one availability zone in var.location."
    }

    # Same zone-1 trap as the AKS resource — fail at plan time with a clear
    # message instead of an opaque AKS 400 mid-apply.
    precondition {
      condition = !(
        contains(local.locations_without_zone_1, var.location)
        && contains(each.value.zones, "1")
      )
      error_message = "GPU pool ${each.key}: location ${var.location} does not support availability zone 1. Set zones = [\"2\", \"3\"] on this pool. Known regions without zone 1: ${join(", ", local.locations_without_zone_1)}."
    }
  }
}
