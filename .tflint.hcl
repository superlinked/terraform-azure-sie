# TFLint Configuration for SIE AKS Terraform
#
# Run with: tflint --init && tflint
# Install: brew install tflint (macOS) or see https://github.com/terraform-linters/tflint

config {
  # Enable all available rules by default
  module = true
  force  = false
}

# =============================================================================
# Azure Provider Plugin
# =============================================================================

plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# =============================================================================
# Terraform Language Rules
# =============================================================================

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Enforce consistent naming conventions
rule "terraform_naming_convention" {
  enabled = true

  resource {
    format = "snake_case"
  }

  variable {
    format = "snake_case"
  }

  output {
    format = "snake_case"
  }
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}
