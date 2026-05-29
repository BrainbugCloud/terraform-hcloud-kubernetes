locals {
  # External worker nodes are discovered by hostname: "<cluster>-<nodepool>-<suffix>".
  # The suffix is caller-chosen (e.g. "-01"), unlike the autoscaler's hex suffix.
  external_worker_hostname_pattern = "^${var.cluster_name}-(${join("|", distinct([for np in local.external_worker_nodepools : np.name]))})-.+$"

  # Per-nodepool Talos config. Plain Worker config — no platform networking is injected;
  # public nodes use their own networking and a vSwitch dedi supplies a VLAN interface via
  # var.external_worker_config_patches. Mirrors the cluster-autoscaler config generation.
  external_worker_nodepool_talos_config_patch = {
    for nodepool in local.external_worker_nodepools : nodepool.name => [
      {
        machine = {
          nodeLabels      = nodepool.labels
          nodeAnnotations = nodepool.annotations
          kubelet = {
            extraConfig = merge(
              {
                registerWithTaints = nodepool.taints
                systemReserved = {
                  cpu               = "100m"
                  memory            = "300Mi"
                  ephemeral-storage = "1Gi"
                }
                kubeReserved = {
                  cpu               = "100m"
                  memory            = "350Mi"
                  ephemeral-storage = "1Gi"
                }
              },
              var.kubernetes_kubelet_extra_config
            )
          }
        }
      }
    ]
  }
}

data "talos_machine_configuration" "external_worker" {
  for_each = { for nodepool in local.external_worker_nodepools : nodepool.name => nodepool }

  talos_version = var.talos_version
  cluster_name  = var.cluster_name
  # External nodes join over the public internet, so they target the external API endpoint
  # (not the private VIP the autoscaler/vSwitch nodes use).
  cluster_endpoint   = local.kube_api_url_external
  kubernetes_version = var.kubernetes_version
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    [for patch in local.talos_base_config_patches : yamlencode(patch)],
    [for patch in local.external_worker_nodepool_talos_config_patch[each.key] : yamlencode(patch)],
    [for patch in var.external_worker_config_patches : yamlencode(patch)]
  )
}
