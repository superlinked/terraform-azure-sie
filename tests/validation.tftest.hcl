# SIE AKS Terraform — Validation Tests
#
# Run with: terraform -chdir=deploy/terraform/azure/infra test
# Requires Terraform >= 1.14.0 (matches the module's required_version)

provider "azurerm" {
  features {}
}

# File-level defaults — every run block inherits these unless it overrides.
# `owner` is required (no default in the module) so set a test placeholder
# once instead of in every run block.
variables {
  owner = "test@example.com"
}

# =============================================================================
# Variable Validation Tests (plan-only, no infrastructure)
# =============================================================================

run "validate_cluster_name" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.name == "sie-test"
    error_message = "AKS cluster name should match project_name variable"
  }

  assert {
    condition     = azurerm_resource_group.main.name == "sie-test-rg"
    error_message = "Resource group name should follow ${var.project_name}-rg convention"
  }
}

run "validate_gpu_pool_t4" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
    gpu_node_pools = [
      {
        name       = "t4spot"
        gpu_class  = "t4"
        node_count = 0
        max_count  = 5
        spot       = true
      }
    ]
  }

  # Single resource block expands to one pool — the values-only A100/H100
  # expansion path proven by symmetry.
  assert {
    condition     = contains(keys(azurerm_kubernetes_cluster_node_pool.gpu), "t4spot")
    error_message = "GPU pool t4spot should be planned"
  }

  # gpu_class lookup resolves to the T4 default SKU.
  assert {
    condition     = local.gpu_pool_vm_sizes["t4spot"] == "Standard_NC4as_T4_v3"
    error_message = "gpu_class=t4 should resolve to Standard_NC4as_T4_v3"
  }

  # Spot pool semantics
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.gpu["t4spot"].priority == "Spot"
    error_message = "Spot pool should set priority = Spot"
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.gpu["t4spot"].eviction_policy == "Delete"
    error_message = "Spot pool should set eviction_policy = Delete"
  }
}

run "validate_gpu_class_a100_values_only" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
    gpu_node_pools = [
      {
        name       = "a100"
        gpu_class  = "a100"
        node_count = 0
        max_count  = 2
      }
    ]
  }

  # Adding A100 is a values-only change — gpu_class lookup picks the right SKU.
  assert {
    condition     = local.gpu_pool_vm_sizes["a100"] == "Standard_NC24ads_A100_v4"
    error_message = "gpu_class=a100 should resolve to Standard_NC24ads_A100_v4 with no module changes"
  }
}

run "validate_workload_identity_enabled" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.oidc_issuer_enabled == true
    error_message = "OIDC issuer should be enabled for workload identity"
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.workload_identity_enabled == true
    error_message = "Workload identity should be enabled on the cluster"
  }

  assert {
    condition     = azurerm_federated_identity_credential.sie_workload.subject == "system:serviceaccount:sie:sie-server"
    error_message = "Federated credential subject should bind the default SA"
  }
}

run "validate_acr_image_paths" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
    create_acr              = true
  }

  assert {
    condition     = local.acr_server_repository_full_name == "sie-test/sie-server"
    error_message = "Server image path should be prefixed with project_name"
  }

  assert {
    condition     = local.acr_gateway_repository_full_name == "sie-test/sie-gateway"
    error_message = "Gateway image path should be prefixed with project_name"
  }

  assert {
    condition     = local.acr_config_repository_full_name == "sie-test/sie-config"
    error_message = "Config image path should be prefixed with project_name"
  }
}

run "validate_model_cache_payload_lifecycle" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
    create_model_cache      = true
  }

  assert {
    condition     = azurerm_storage_management_policy.model_cache[0].rule[0].name == "expire-payloads"
    error_message = "Storage lifecycle rule should be named expire-payloads"
  }

  assert {
    condition     = contains(azurerm_storage_management_policy.model_cache[0].rule[0].filters[0].prefix_match, "sie-cache/payloads/")
    error_message = "Lifecycle rule should target the sie-cache/payloads/ prefix"
  }
}

run "validate_ingress_public_ip" {
  command = plan

  variables {
    project_name             = "sie-test"
    allow_public_api_server  = true
    create_ingress_public_ip = true
  }

  assert {
    condition     = azurerm_public_ip.ingress[0].sku == "Standard"
    error_message = "Ingress public IP should be Standard SKU"
  }

  assert {
    condition     = azurerm_public_ip.ingress[0].allocation_method == "Static"
    error_message = "Ingress public IP should be statically allocated"
  }

  assert {
    condition     = azurerm_role_assignment.aks_ingress_ip[0].role_definition_name == "Network Contributor"
    error_message = "AKS control-plane UAMI should receive Network Contributor on the ingress IP"
  }
}

run "validate_rejects_bogus_upgrade_channel" {
  command = plan

  variables {
    project_name              = "sie-test"
    allow_public_api_server   = true
    automatic_upgrade_channel = "bogus"
  }

  expect_failures = [
    var.automatic_upgrade_channel,
  ]
}

run "validate_rejects_public_api_default" {
  command = plan

  variables {
    project_name = "sie-test"
    owner        = "test@example.com"
    # No allow_public_api_server, no enable_private_cluster, no
    # api_server_authorized_ip_ranges — the AKS precondition should fail
    # the plan to refuse shipping a publicly reachable control plane.
  }

  expect_failures = [
    azurerm_kubernetes_cluster.main,
  ]
}

run "validate_caf_tags_propagated" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "alice@example.com"
    environment             = "prod"
    cost_center             = "sie-platform"
    workload                = "sie"
    allow_public_api_server = true
  }

  assert {
    condition = (
      local.caf_tags["Environment"] == "prod"
      && local.caf_tags["Owner"] == "alice@example.com"
      && local.caf_tags["CostCenter"] == "sie-platform"
      && local.caf_tags["Workload"] == "sie"
    )
    error_message = "CAF tags should resolve to the four PascalCase keys required by the landing-zone policy"
  }

  assert {
    condition = (
      lookup(local.resource_tags, "Environment", "") == "prod"
      && lookup(local.resource_tags, "Owner", "") == "alice@example.com"
      && lookup(local.resource_tags, "CostCenter", "") == "sie-platform"
      && lookup(local.resource_tags, "Workload", "") == "sie"
    )
    error_message = "resource_tags should include all four CAF tags so every tag-supporting resource carries them"
  }
}

run "validate_rejects_bogus_environment" {
  command = plan

  variables {
    project_name = "sie-test"
    environment  = "bogus"
  }

  expect_failures = [
    var.environment,
  ]
}

run "validate_rejects_bogus_owner" {
  command = plan

  variables {
    project_name = "sie-test"
    owner        = "not-a-upn"
  }

  expect_failures = [
    var.owner,
  ]
}

run "validate_rejects_zone1_in_francecentral" {
  command = plan

  variables {
    project_name            = "sie-test"
    location                = "francecentral"
    allow_public_api_server = true
    # Module default for system_node_pool.zones is ["1","2","3"]; AKS
    # precondition should trip because francecentral has no zone 1.
  }

  expect_failures = [
    azurerm_kubernetes_cluster.main,
  ]
}

run "validate_zone1_restricted_region_succeeds_with_override" {
  command = plan

  variables {
    project_name            = "sie-test"
    location                = "francecentral"
    allow_public_api_server = true
    system_node_pool = {
      vm_size   = "Standard_D4s_v3"
      min_count = 1
      max_count = 5
      zones     = ["2", "3"]
    }
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.location == "francecentral"
    error_message = "francecentral should plan cleanly when system_node_pool.zones excludes zone 1"
  }
}

run "validate_network_topology" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
  }

  assert {
    condition     = contains(azurerm_virtual_network.main.address_space, "10.0.0.0/16")
    error_message = "VNet CIDR should default to 10.0.0.0/16"
  }

  # System + GPU subnets are bound to the NAT gateway so egress concentrates
  # on a single predictable public IP prefix. Subnet IDs are not known until
  # apply; assert the subnets exist and the NAT gateway is provisioned.
  assert {
    condition     = azurerm_subnet.system.name == "sie-test-snet-system"
    error_message = "System subnet should be named sie-test-snet-system"
  }

  assert {
    condition     = azurerm_subnet.gpu.name == "sie-test-snet-gpu"
    error_message = "GPU subnet should be named sie-test-snet-gpu"
  }

  assert {
    condition     = azurerm_nat_gateway.main.name == "sie-test-nat"
    error_message = "NAT gateway should be named sie-test-nat"
  }
}

run "validate_model_cache_storage_locked_down_by_default" {
  command = plan

  variables {
    project_name            = "sie-test"
    owner                   = "test@example.com"
    allow_public_api_server = true
    create_model_cache      = true
  }

  assert {
    condition     = azurerm_storage_account.model_cache[0].network_rules[0].default_action == "Deny"
    error_message = "Storage account network ACL must default to Deny when private endpoints are off"
  }

  assert {
    condition     = contains(azurerm_storage_account.model_cache[0].network_rules[0].bypass, "AzureServices")
    error_message = "Storage account network ACL bypass should include AzureServices so Azure-internal traffic (e.g. logging) is not blocked"
  }

  assert {
    condition     = length(local.storage_effective_allowed_subnet_ids) == 2
    error_message = "Default subnet allowlist should include the cluster's system + GPU subnets (2 entries)"
  }
}

run "validate_storage_ip_allowlist_passthrough" {
  command = plan

  variables {
    project_name              = "sie-test"
    owner                     = "test@example.com"
    allow_public_api_server   = true
    create_model_cache        = true
    storage_allowed_ip_ranges = ["203.0.113.5/32"]
  }

  assert {
    condition     = contains(azurerm_storage_account.model_cache[0].network_rules[0].ip_rules, "203.0.113.5/32")
    error_message = "Caller-supplied IP CIDR should appear in the storage account's ip_rules allowlist"
  }
}

run "validate_storage_private_endpoints_skip_acl" {
  command = plan

  variables {
    project_name             = "sie-test"
    owner                    = "test@example.com"
    allow_public_api_server  = true
    create_model_cache       = true
    enable_private_endpoints = true
  }

  assert {
    condition     = azurerm_storage_account.model_cache[0].public_network_access_enabled == false
    error_message = "Private endpoint mode must disable public network access on the storage account"
  }

  # The network ACL is omitted in private-endpoint mode (the dynamic
  # network_rules block iterates over []). The post-plan `network_rules`
  # attribute itself is computed, so assert against the local list that
  # drives the dynamic block — it should also be empty in this mode since
  # the cluster subnets no longer carry the Microsoft.Storage service
  # endpoint.
  assert {
    condition     = length(local.cluster_subnet_service_endpoints) == 0
    error_message = "Private endpoint mode should omit the Microsoft.Storage service endpoint from the cluster subnets"
  }
}

run "validate_storage_rejects_open_ip_range" {
  command = plan

  variables {
    project_name              = "sie-test"
    allow_public_api_server   = true
    storage_allowed_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [
    var.storage_allowed_ip_ranges,
  ]
}
