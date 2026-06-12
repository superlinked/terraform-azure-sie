# SIE AKS Cluster — GPU Node Pools
#
# A single azurerm_kubernetes_cluster_node_pool resource is expanded with
# for_each over var.gpu_node_pools. Adding A100 or H100 once Azure quota is
# granted is a values-only change in the caller's gpu_node_pools list — no
# new resource blocks, no module restructuring.

# =============================================================================
# GPU class → default SKU map
# =============================================================================
# Caller specifies gpu_class = "t4" | "a10" | "a100" | "h100" and the module
# resolves the right VM size. `vm_size` on the pool object overrides this
# default for callers who want a larger SKU within the same family.

locals {
  gpu_class_defaults = {
    t4 = {
      vm_size = "Standard_NC4as_T4_v3"
    }
    a10 = {
      vm_size = "Standard_NV6ads_A10_v5"
    }
    a100 = {
      vm_size = "Standard_NC24ads_A100_v4"
    }
    h100 = {
      vm_size = "Standard_NC40ads_H100_v5"
    }
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  for_each = { for p in var.gpu_node_pools : p.name => p }

  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vnet_subnet_id        = azurerm_subnet.gpu.id

  vm_size = coalesce(each.value.vm_size, local.gpu_class_defaults[each.value.gpu_class].vm_size)

  zones = each.value.zones

  os_disk_size_gb = each.value.os_disk_size_gb
  os_disk_type    = "Managed"
  os_type         = "Linux"

  # AKS auto-installs the NVIDIA driver on N-series VMs. Declaring the
  # attribute explicitly prevents `terraform plan` from showing it as drift
  # on every refresh and forcing replacement of the node pool. Matches the
  # upstream Azure SIE module's pattern.
  gpu_driver = "Install"

  auto_scaling_enabled = true
  node_count           = each.value.node_count
  min_count            = each.value.node_count
  max_count            = each.value.max_count

  # Spot configuration. Azure spot pools require `priority = "Spot"`,
  # `eviction_policy = "Delete"`, and `spot_max_price = -1` (= on-demand
  # price ceiling) for standard scale-set spot capacity behaviour.
  priority        = each.value.spot ? "Spot" : "Regular"
  eviction_policy = each.value.spot ? "Delete" : null
  spot_max_price  = each.value.spot ? each.value.spot_max_price : null

  node_taints = concat(
    each.value.node_taints,
    each.value.spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : [],
  )

  # Merge order is intentional: module-managed labels first (resource labels
  # + node-type + gpu-class default), then the user's per-pool labels last
  # so a user-supplied `sie.superlinked.com/gpu-type` (e.g. "t4-spot") wins
  # over the gpu_class default. Without this, two pools sharing a class
  # (t4 spot + t4 on-demand) end up with identical labels, the cluster
  # autoscaler can't distinguish them at simulation time, and pods that
  # select one specifically get NotTriggerScaleUp.
  node_labels = merge(
    local.resource_labels,
    {
      "sie.superlinked.com/node-type" = "gpu"
      "sie.superlinked.com/gpu-type"  = each.value.gpu_class
    },
    each.value.labels,
  )

  kubelet_config {
    container_log_max_size_mb = var.kubelet_container_log_max_size_mb
    container_log_max_files   = var.kubelet_container_log_max_files
  }

  # Spot pools don't support max_surge — AKS rejects the block.
  dynamic "upgrade_settings" {
    for_each = each.value.spot ? [] : [1]
    content {
      max_surge = "33%"
    }
  }

  tags = local.resource_tags

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }
}
