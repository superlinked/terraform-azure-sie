# SIE AKS Cluster
#
# The cluster carries Workload Identity + OIDC issuer + AAD-RBAC by default.
# UAMI assignments (control plane + kubelet) are created in identity.tf and
# referenced here.
#
# The system pool is inlined on the cluster resource per Azure convention.
# GPU pools are created separately in node_pools.tf via for_each.

# =============================================================================
# Log Analytics workspace (gated on observability flags)
# =============================================================================

resource "azurerm_log_analytics_workspace" "main" {
  # Only consumers are oms_agent and the diagnostic setting (both gated by
  # enable_cloud_logging). Managed Prometheus uses azurerm_monitor_workspace
  # below, not Log Analytics, so don't provision a billable workspace when
  # only Prometheus is enabled.
  count = var.enable_cloud_logging ? 1 : 0

  name                = local.names.log_workspace
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku               = "PerGB2018"
  retention_in_days = 30

  tags = local.resource_tags
}

# Managed Prometheus workspace (Azure Monitor workspace)
resource "azurerm_monitor_workspace" "prometheus" {
  count = var.enable_managed_prometheus ? 1 : 0

  name                = "${local.names.cluster}-prom"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = local.resource_tags
}

# =============================================================================
# AKS cluster
# =============================================================================

resource "azurerm_kubernetes_cluster" "main" {
  name                = local.names.cluster
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = local.names.cluster

  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = var.automatic_upgrade_channel
  sku_tier                  = "Standard"
  node_resource_group       = "${local.names.resource_group}-nodes"

  # Workload Identity wiring
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Azure RBAC for Kubernetes authorization. The kubelet + workload identities
  # authenticate via UAMI; cluster operators authenticate via Azure AD groups.
  # Local (static certificate) accounts remain enabled by default because the
  # in-module Kubernetes + Helm providers authenticate via kube_config certs
  # to install the NVIDIA device plugin. Flip var.local_account_disabled to
  # true in production once an AAD admin group is bound to cluster-admin RBAC
  # and the providers are reconfigured to use an exec/kubelogin flow.
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }
  local_account_disabled = var.local_account_disabled

  # Private vs. public API endpoint
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false
  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  # Identity: control-plane UAMI is created in identity.tf.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.controlplane.id]
  }

  kubelet_identity {
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
  }

  # Azure CNI overlay — pods get IPs from an overlay pool rather than the
  # subnet, so subnet sizing isn't a constraint on pod density.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.96.0.0/16"
    dns_service_ip      = "10.96.0.10"
    outbound_type       = "userAssignedNATGateway"
  }

  # Cluster autoscaler profile — keep scale-down conservative so transient
  # idle windows don't churn nodes (configurable via the variables below).
  auto_scaler_profile {
    scale_down_unneeded        = var.auto_scaler_scale_down_unneeded
    scale_down_delay_after_add = var.auto_scaler_scale_down_delay_after_add
  }

  # System pool — runs kube-system, ingress controllers, KEDA / Prometheus.
  # Inlined on the cluster resource per Azure convention.
  default_node_pool {
    name                         = "default"
    vm_size                      = var.system_node_pool.vm_size
    vnet_subnet_id               = azurerm_subnet.system.id
    zones                        = var.system_node_pool.zones
    os_disk_size_gb              = var.system_node_pool.os_disk_size_gb
    os_disk_type                 = "Managed"
    auto_scaling_enabled         = true
    min_count                    = var.system_node_pool.min_count
    max_count                    = var.system_node_pool.max_count
    orchestrator_version         = var.kubernetes_version
    only_critical_addons_enabled = var.system_node_pool.only_critical_addons_enabled

    upgrade_settings {
      max_surge = "33%"
    }

    kubelet_config {
      container_log_max_size_mb = var.kubelet_container_log_max_size_mb
      container_log_max_files   = var.kubelet_container_log_max_files
    }

    node_labels = merge(local.resource_labels, {
      "sie.superlinked.com/node-type" = "cpu"
    })

    tags = local.resource_tags
  }

  # Observability add-ons
  dynamic "oms_agent" {
    for_each = var.enable_cloud_logging ? [1] : []
    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.main[0].id
      msi_auth_for_monitoring_enabled = true
    }
  }

  dynamic "monitor_metrics" {
    for_each = var.enable_managed_prometheus ? [1] : []
    content {}
  }

  tags = local.resource_tags

  lifecycle {
    # Pool count / scaling state is managed by the autoscaler; ignore drift.
    ignore_changes = [
      default_node_pool[0].node_count,
    ]

    # Refuse to ship a public AKS API server open to the internet. Operators
    # must either enable the private cluster or supply at least one
    # authorized IP range. Set var.allow_public_api_server = true to bypass
    # for short-lived dev clusters where exposure is acceptable.
    precondition {
      condition = (
        var.enable_private_cluster
        || length(var.api_server_authorized_ip_ranges) > 0
        || var.allow_public_api_server
      )
      error_message = "AKS API server would be publicly reachable from any IP. Set enable_private_cluster = true, supply api_server_authorized_ip_ranges, or set allow_public_api_server = true to override."
    }

    # A handful of Azure regions don't expose availability zone 1. Catch the
    # combination at plan time so the operator gets a clear error instead of
    # an opaque AKS 400 "AvailabilityZoneNotSupported" mid-apply.
    # The list is hand-maintained — Azure has no data source for AZ
    # availability per region. Verified 2026-06-09 against `az account list-locations`.
    precondition {
      condition = !(
        contains(local.locations_without_zone_1, var.location)
        && contains(var.system_node_pool.zones, "1")
      )
      error_message = "Location ${var.location} does not support availability zone 1. Set system_node_pool.zones = [\"2\", \"3\"] (and the same on each gpu_node_pools[*].zones). Known regions without zone 1: ${join(", ", local.locations_without_zone_1)}."
    }
  }
}

# =============================================================================
# Deletion protection (management lock)
# =============================================================================
# CanNotDelete lock on the AKS cluster — blocks accidental terraform destroy
# and portal delete clicks. Toggle with var.deletion_protection.

resource "azurerm_management_lock" "aks" {
  count = var.deletion_protection ? 1 : 0

  name       = "${local.names.cluster}-delete-lock"
  scope      = azurerm_kubernetes_cluster.main.id
  lock_level = "CanNotDelete"
  notes      = "SIE AKS deletion protection. Set deletion_protection = false to remove."
}

# Grant the cluster creator AAD-RBAC Cluster Admin on this cluster so the operator
# who ran `terraform apply` can `kubectl ...` immediately (dev/single-user flow).
# Default off; opt in via var.grant_admin_to_creator. Shared/production clusters
# should bind a dedicated AAD group instead.
resource "azurerm_role_assignment" "creator_cluster_admin" {
  count = var.grant_admin_to_creator ? 1 : 0

  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# =============================================================================
# Control-plane diagnostic settings
# =============================================================================
# Sends AKS control-plane logs (kube-apiserver, audit, controller-manager,
# scheduler, cluster-autoscaler) and platform metrics to Log Analytics.

resource "azurerm_monitor_diagnostic_setting" "aks_controlplane" {
  count = var.enable_cloud_logging ? 1 : 0

  name                       = "${local.names.cluster}-diag"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main[0].id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
