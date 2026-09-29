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

run "rejects_ipv6_any_address_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["::/0"]
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

run "restricts_api_server_to_allowlist" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  }

  assert {
    condition = (
      !azurerm_kubernetes_cluster.main.private_cluster_enabled
      && azurerm_kubernetes_cluster.main.api_server_access_profile[0].authorized_ip_ranges == toset(["203.0.113.10/32"])
    )
    error_message = "The API server should accept only the allowlisted range"
  }
}

# =============================================================================
# System subnet load balancer ingress
# =============================================================================

run "default_opens_no_load_balancer_ports" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  }

  assert {
    condition     = length(var.public_load_balancer_ports) == 0 && !var.allow_public_load_balancer
    error_message = "The system subnet NSG should open no load balancer ports by default"
  }
}

run "rejects_load_balancer_ports_without_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
    public_load_balancer_ports      = ["443"]
  }

  expect_failures = [var.public_load_balancer_ports]
}

run "rejects_any_address_load_balancer_source_without_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["203.0.113.10/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.public_load_balancer_allowed_ip_ranges]
}

run "restricts_load_balancer_ports_to_sources" {
  command = plan

  variables {
    api_server_authorized_ip_ranges        = ["203.0.113.10/32"]
    public_load_balancer_ports             = ["443"]
    public_load_balancer_allowed_ip_ranges = ["198.51.100.0/24"]
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.system.security_rule :
      rule.name == "AllowPublicLoadBalancerInbound"
      && rule.source_address_prefixes == toset(["198.51.100.0/24"])
      && rule.source_address_prefix == null
      && rule.destination_port_ranges == toset(["443"])
    ])
    error_message = "The load balancer rule should admit only the configured sources"
  }
}

run "opt_in_allows_internet_load_balancer_source" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["203.0.113.10/32"]
    public_load_balancer_ports      = ["80", "443"]
    allow_public_load_balancer      = true
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.system.security_rule :
      rule.name == "AllowPublicLoadBalancerInbound" && rule.source_address_prefix == "Internet"
    ])
    error_message = "allow_public_load_balancer with no source list should use the Internet service tag"
  }
}
