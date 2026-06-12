# Centralized naming convention for SIE Azure resources.
# Single source of truth for every resource name in this module.
#
# Pattern: ${project_name}${suffix}
# Tag: sie-cluster = ${project_name}

locals {
  name_suffixes = {
    resource_group = "-rg"
    cluster        = ""
    vnet           = "-vnet"
    snet_system    = "-snet-system"
    snet_gpu       = "-snet-gpu"
    snet_pe        = "-snet-pe"
    nsg_system     = "-nsg-system"
    nsg_gpu        = "-nsg-gpu"
    nat_gateway    = "-nat"
    nat_public_ip  = "-nat-pip"
    workload_uami  = "-workload"
    kubelet_uami   = "-kubelet"
    cp_uami        = "-controlplane"
    log_workspace  = "-logs"
  }
}
