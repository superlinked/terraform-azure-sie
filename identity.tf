# SIE AKS Cluster — Identity
#
# Three user-assigned managed identities and the federated credential that
# binds the workload UAMI to the Kubernetes ServiceAccount that SIE workers
# run under. UAMI rather than service principal so Terraform never holds
# long-lived credentials.

# =============================================================================
# Control-plane UAMI
# =============================================================================
# Replaces the AKS-created system-assigned identity so we can reference its
# principal_id from outputs and from any cluster-extension role assignments.

resource "azurerm_user_assigned_identity" "controlplane" {
  name                = local.names.cp_uami
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.resource_tags
}

# Allow the control-plane UAMI to assign the kubelet UAMI to nodes — required
# by AKS when both identities are user-assigned.
resource "azurerm_role_assignment" "controlplane_uses_kubelet" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.controlplane.principal_id
}

# Network contributor on the VNet so the control plane can manage NICs and
# the NAT-gateway-bound subnets it places nodes into.
resource "azurerm_role_assignment" "controlplane_network" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.controlplane.principal_id
}

# =============================================================================
# Kubelet UAMI
# =============================================================================
# The identity attached to each node — used to pull images from ACR via the
# AcrPull role assignment configured in acr.tf.

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = local.names.kubelet_uami
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.resource_tags
}

# =============================================================================
# Workload UAMI + federated credential
# =============================================================================
# Bound to the in-cluster ServiceAccount that SIE workers run under. Pods
# annotated with `azure.workload.identity/client-id=<this client_id>` exchange
# their projected SA token for an Azure AD access token at runtime.

resource "azurerm_user_assigned_identity" "workload" {
  name                = local.names.workload_uami
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.resource_tags
}

# Wait for the AKS OIDC issuer URL to be queryable by the IAM control plane
# after cluster create. On a fresh subscription the issuer document propagates
# a few seconds behind the cluster's "ready" signal, and the federated
# credential below fails with `Error: AADSTS70021: No matching federated
# identity record found` on the first apply if created too quickly.
resource "time_sleep" "wait_for_oidc_issuer" {
  depends_on      = [azurerm_kubernetes_cluster.main]
  create_duration = "30s"

  triggers = {
    cluster_id = azurerm_kubernetes_cluster.main.id
  }
}

resource "azurerm_federated_identity_credential" "sie_workload" {
  name      = "${local.names.cluster}-sie-workload"
  parent_id = azurerm_user_assigned_identity.workload.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:${var.sie_namespace}:${var.sie_service_account_name}"

  depends_on = [
    azurerm_kubernetes_cluster.main,
    time_sleep.wait_for_oidc_issuer,
  ]
}

# =============================================================================
# Role assignments
# =============================================================================
# Storage Blob role assignments scoped to the model-cache container are
# created in storage.tf so they can reference the container resource
# directly. ACR pull assignments live in acr.tf for the same reason.
