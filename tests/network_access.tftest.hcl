# SIE AKS Terraform - Kubernetes API and load balancer access tests
#
# Run with: terraform test -filter=tests/network_access.tftest.hcl
# Uses mock providers, so no cloud credentials are needed.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
    }
  }

  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/sie-test-rg/providers/Microsoft.ContainerService/managedClusters/sie-test"
      kube_config = [{
        host                   = "https://sie-test.example.invalid:443"
        username               = "clusterUser"
        password               = "unused"
        client_certificate     = "dGVzdA=="
        client_key             = "dGVzdA=="
        cluster_ca_certificate = "dGVzdA=="
      }]
      kube_admin_config = [{
        host                   = "https://sie-test.example.invalid:443"
        username               = "clusterAdmin"
        password               = "unused"
        client_certificate     = "dGVzdA=="
        client_key             = "dGVzdA=="
        cluster_ca_certificate = "dGVzdA=="
      }]
    }
    override_during = plan
  }

  mock_resource "azurerm_public_ip_prefix" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/sie-test-rg/providers/Microsoft.Network/publicIPPrefixes/sie-test-nat-pip-prefix"
      ip_prefix = "198.51.100.16/28"
    }
    override_during = plan
  }
}

mock_provider "azuread" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  project_name = "sie-test"
  owner        = "test@example.com"
}


# =============================================================================
# Kubernetes API server
# =============================================================================

run "rejects_unset_api_access" {
  command = plan

  expect_failures = [azurerm_kubernetes_cluster.main]
}

run "rejects_ipv4_any_address_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_split_any_address_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_aggregate_above_one_slash8_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["11.0.0.0/8", "12.0.0.0/8"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_ipv6_any_address" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["::/0"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_ipv6_range" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["2001:4860::/32"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_documentation_placeholder" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_documentation_placeholder_even_with_opt_in" {
  command = plan

  variables {
    allow_public_api_server         = true
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_range_containing_documentation_range" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.112.0/23"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_allowlist_without_room_for_nat_prefix" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = [for i in range(200) : cidrsubnet("100.0.0.0/8", 16, i)]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_allowlist_on_private_cluster" {
  command = plan

  variables {
    enable_private_cluster          = true
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "restricts_api_server_to_allowlist" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
  }

  assert {
    condition = (
      !azurerm_kubernetes_cluster.main.private_cluster_enabled
      && azurerm_kubernetes_cluster.main.api_server_access_profile[0].authorized_ip_ranges == toset(["8.8.8.8/32", "198.51.100.16/28"])
    )
    error_message = "The API server should accept only the allowlisted range and the cluster's NAT gateway egress prefix"
  }
}

run "accepts_allowlist_totalling_one_slash8" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["11.0.0.0/9", "11.128.0.0/9"]
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.main.api_server_access_profile[0].authorized_ip_ranges) == 3
    error_message = "An allowlist covering exactly one /8 should be accepted"
  }
}

run "private_cluster_without_allowlist" {
  command = plan

  variables {
    enable_private_cluster = true
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.main.private_cluster_enabled
      && length(azurerm_kubernetes_cluster.main.api_server_access_profile[0].authorized_ip_ranges) == 0
    )
    error_message = "A private cluster should carry no authorized ranges"
  }
}

run "opt_in_without_allowlist_adds_no_ranges" {
  command = plan

  variables {
    allow_public_api_server = true
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.main.api_server_access_profile[0].authorized_ip_ranges) == 0
    error_message = "The NAT gateway prefix should be added only alongside an operator allowlist"
  }
}

# =============================================================================
# System subnet load balancer ingress
# =============================================================================

run "default_opens_no_load_balancer_ports" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
  }

  assert {
    condition     = length(azurerm_network_security_group.system.security_rule) == 0
    error_message = "The system subnet NSG should carry no inbound rule by default"
  }
}

run "rejects_load_balancer_ports_without_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
    public_load_balancer_ports      = ["443"]
  }

  expect_failures = [var.public_load_balancer_ports]
}

run "rejects_any_address_load_balancer_source_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "rejects_load_balancer_source_aggregate_above_one_slash8" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["11.0.0.0/8", "12.0.0.0/8"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "rejects_ipv4_mapped_ipv6_load_balancer_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["::ffff:0:0/96"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "rejects_service_tag_load_balancer_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["Internet"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "rejects_documentation_load_balancer_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["198.51.100.0/24"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "rejects_load_balancer_source_containing_documentation_range" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["198.51.100.0/23"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "restricts_load_balancer_ports_to_sources" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["8.8.8.8/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["9.9.9.0/24"]
  }

  assert {
    condition = (
      length(azurerm_network_security_group.system.security_rule) == 1
      && anytrue([
        for rule in azurerm_network_security_group.system.security_rule :
        rule.name == "AllowPublicLoadBalancerInbound"
        && rule.source_address_prefixes == toset(["9.9.9.0/24"])
        && rule.source_address_prefix == ""
        && rule.destination_port_ranges == toset(["443"])
      ])
    )
    error_message = "The load balancer rule should admit only the configured sources"
  }
}

run "opt_in_allows_internet_load_balancer_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
    public_load_balancer_ports      = ["80", "443"]
    allow_public_load_balancer      = true
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.system.security_rule :
      rule.name == "AllowPublicLoadBalancerInbound"
      && rule.source_address_prefix == "Internet"
      && length(rule.source_address_prefixes) == 0
    ])
    error_message = "allow_public_load_balancer with no source list should use the Internet service tag"
  }
}

# =============================================================================
# Upgrade from the previous default (these runs apply to mocked state, so they
# stay last in the file)
# =============================================================================

run "upgrade_applies_previous_default_rule" {
  command = apply

  plan_options {
    target = [azurerm_network_security_group.system]
  }

  override_resource {
    target = azurerm_resource_group.main
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/sie-test-rg"
    }
  }

  override_resource {
    target = azurerm_network_security_group.system
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/sie-test-rg/providers/Microsoft.Network/networkSecurityGroups/sie-test-nsg-system"
    }
  }

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
    public_load_balancer_ports      = ["80", "443", "8080"]
    allow_public_load_balancer      = true
  }

  assert {
    condition     = length(azurerm_network_security_group.system.security_rule) == 1
    error_message = "The previous default rule should be in state before the upgrade"
  }
}

run "upgrade_to_defaults_removes_the_rule" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["8.8.8.8/32"]
  }

  assert {
    condition     = length(azurerm_network_security_group.system.security_rule) == 0
    error_message = "Upgrading with the defaults should remove AllowPublicLoadBalancerInbound from the system NSG"
  }
}
