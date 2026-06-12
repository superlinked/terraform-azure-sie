# NVIDIA Device Plugin and GPU Storage
#
# AKS pre-installs NVIDIA drivers on the GPU node image when a GPU VM size is
# selected, but it does NOT install the Kubernetes device plugin. Without it,
# GPU nodes don't advertise nvidia.com/gpu resources and GPU pods stay
# Pending.

resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.17.1"
  namespace  = "kube-system"

  values = [
    yamlencode({
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "kubernetes.azure.com/scalesetpriority"
          operator = "Equal"
          value    = "spot"
          effect   = "NoSchedule"
        },
      ]
      # Override the chart's default affinity, which requires Node Feature
      # Discovery labels (`feature.node.kubernetes.io/pci-10de.present`,
      # `nvidia.com/gpu.present`). AKS doesn't ship NFD by default. Use AKS's
      # native GPU node label instead so the DaemonSet lands without an
      # extra NFD install.
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key      = "kubernetes.azure.com/accelerator"
                    operator = "In"
                    values   = ["nvidia"]
                  }
                ]
              }
            ]
          }
        }
      }
    })
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_kubernetes_cluster_node_pool.gpu,
  ]
}

# AKS's managed-csi StorageClass is the default in recent AKS versions, so
# no extra StorageClass configuration is required.
