# SIE AKS Cluster — Outputs
#
# Outputs consumed by the sie-cluster Helm chart and external tooling.

# =============================================================================
# Cluster Connection
# =============================================================================

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.main.name
}

output "cluster_id" {
  description = "AKS cluster resource ID."
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_endpoint" {
  description = "AKS API server FQDN."
  value       = azurerm_kubernetes_cluster.main.fqdn
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the AKS API."
  value       = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Azure region the cluster runs in."
  value       = azurerm_kubernetes_cluster.main.location
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}

output "resource_group_name" {
  description = "Name of the resource group holding cluster resources."
  value       = azurerm_resource_group.main.name
}

# =============================================================================
# Workload Identity (OIDC + federated credentials)
# =============================================================================

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster — used for federating external workloads."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "sie_workload_identity_client_id" {
  description = "Client ID of the SIE workload UAMI — pass to Helm as the azure.workload.identity/client-id annotation value."
  value       = azurerm_user_assigned_identity.workload.client_id
}

output "sie_workload_identity_principal_id" {
  description = "Principal/object ID of the SIE workload UAMI — useful for additional role assignments outside this module."
  value       = azurerm_user_assigned_identity.workload.principal_id
}

output "workload_identity_annotation" {
  description = <<-EOT
    Pre-composed `<annotation-key>=<client-id>` string. Consumers that
    parse this output expect a key/value pair split on `=`.

    NOT a Helm --set RHS. For a manual `helm install`, pass the bare
    client id from `sie_workload_identity_client_id` instead:

      --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$(terraform output -raw sie_workload_identity_client_id)"
  EOT
  value       = "azure.workload.identity/client-id=${azurerm_user_assigned_identity.workload.client_id}"
}

# =============================================================================
# Container Registry (ACR)
# =============================================================================

output "acr_name" {
  description = "ACR name (null when create_acr=false and no external ACR is configured)."
  value       = local.acr_name_effective
}

output "acr_login_server" {
  description = "ACR login server (e.g., sieacrabc123.azurecr.io)."
  value       = local.acr_login_server
}

output "acr_server_repository_url" {
  description = "ACR image reference for sie-server (login_server/prefix/sie-server)."
  value       = local.acr_server_repository_url
}

output "acr_gateway_repository_url" {
  description = "ACR image reference for sie-gateway."
  value       = local.acr_gateway_repository_url
}

output "acr_config_repository_url" {
  description = "ACR image reference for sie-config."
  value       = local.acr_config_repository_url
}

# =============================================================================
# Model cache + payload store
# =============================================================================

output "model_cache_account_name" {
  description = "Storage account name of the managed model cache. Null when create_model_cache=false."
  value       = try(azurerm_storage_account.model_cache[0].name, null)
}

output "model_cache_container_name" {
  description = "Blob container name of the managed model cache. Null when create_model_cache=false."
  value       = try(azurerm_storage_container.model_cache[0].name, null)
}

output "model_cache_bucket_url" {
  description = "Model cache URL with the /models prefix — pass to Helm as workers.common.clusterCache.url and to sie-admin as --target."
  value       = try("abfs://${azurerm_storage_container.model_cache[0].name}@${azurerm_storage_account.model_cache[0].name}.dfs.core.windows.net/models", null)
}

output "payload_store_url" {
  description = "Payload store URL (model cache container under the /payloads prefix). The chart auto-derives this from clusterCache.url so most operators do not set it directly."
  value       = try("abfs://${azurerm_storage_container.model_cache[0].name}@${azurerm_storage_account.model_cache[0].name}.dfs.core.windows.net/payloads", null)
}

output "model_cache_helm_args" {
  description = "Helm --set arguments to wire the managed model cache into the sie-cluster chart. Empty when create_model_cache=false."
  value = try(
    join(" ", [
      "--set workers.common.clusterCache.enabled=true",
      "--set workers.common.clusterCache.url=abfs://${azurerm_storage_container.model_cache[0].name}@${azurerm_storage_account.model_cache[0].name}.dfs.core.windows.net/models",
    ]),
    ""
  )
}

# =============================================================================
# GPU Pools
# =============================================================================

output "gpu_node_pool_names" {
  description = "Names of the configured GPU node pools."
  value       = [for p in var.gpu_node_pools : p.name]
}

output "gpu_node_pool_disk_sizes_gb" {
  description = "Root OS disk size in GiB per configured GPU node pool."
  value       = { for p in var.gpu_node_pools : p.name => p.os_disk_size_gb }
}

# =============================================================================
# Ingress public IP
# =============================================================================

output "ingress_public_ip" {
  description = "Static public IP address for the ingress controller. Null when create_ingress_public_ip = false."
  value       = try(azurerm_public_ip.ingress[0].ip_address, null)
}

output "ingress_helm_args" {
  description = "Pre-composed Helm --set arguments to attach the static ingress IP to ingress-nginx. Empty when create_ingress_public_ip = false. The annotation key uses Helm's `\\.` escape so shell command substitution preserves it literally — do NOT wrap in extra shell quotes; the surrounding command (`$(terraform output -raw ingress_helm_args)`) word-splits the value correctly."
  value = try(
    join(" ", [
      "--set controller.service.loadBalancerIP=${azurerm_public_ip.ingress[0].ip_address}",
      "--set controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-resource-group=${azurerm_resource_group.main.name}",
    ]),
    ""
  )
}

output "gpu_node_pool_vm_sizes" {
  description = "Effective Azure VM SKU per configured GPU node pool (resolved from gpu_class default unless overridden)."
  value       = local.gpu_pool_vm_sizes
}
