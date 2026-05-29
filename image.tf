locals {
  talos_schematic_id = var.talos_schematic_id != null ? var.talos_schematic_id : talos_image_factory_schematic.this[0].id

  talos_installer_image_url = data.talos_image_factory_urls.amd64.urls.installer
  talos_amd64_image_url     = data.talos_image_factory_urls.amd64.urls.disk_image
  talos_arm64_image_url     = data.talos_image_factory_urls.arm64.urls.disk_image

  # Installer-image coordinates per external worker node pool. Each pool upgrades with its
  # own platform/arch (and schematic, defaulting to the cluster schematic) so e.g. oracle and
  # metal arm64 nodes get the right factory image rather than the cluster's hcloud image.
  external_worker_nodepool_image = {
    for np in local.external_worker_nodepools : np.name => {
      platform     = np.talos_platform
      architecture = np.talos_architecture
      schematic_id = np.talos_schematic_id != null ? np.talos_schematic_id : local.talos_schematic_id
    }
  }
  external_worker_schematic_data = {
    for key in distinct([
      for v in values(local.external_worker_nodepool_image) : "${v.platform}:${v.architecture}:${v.schematic_id}"
    ]) :
    key => {
      platform     = split(":", key)[0]
      architecture = split(":", key)[1]
      schematic_id = split(":", key)[2]
    }
  }

  amd64_image_required = anytrue([
    for np in concat(
      local.control_plane_nodepools,
      local.worker_nodepools,
      local.cluster_autoscaler_nodepools
    ) : substr(np.server_type, 0, 3) != "cax"
  ])
  arm64_image_required = anytrue([
    for np in concat(
      local.control_plane_nodepools,
      local.worker_nodepools,
      local.cluster_autoscaler_nodepools
    ) : substr(np.server_type, 0, 3) == "cax"
  ])

  image_label_selector = join(",",
    [
      "os=talos",
      "cluster=${var.cluster_name}",
      "talos_version=${var.talos_version}",
      "talos_schematic_id=${substr(local.talos_schematic_id, 0, 32)}"
    ]
  )

  talos_image_extentions_longhorn = [
    "siderolabs/iscsi-tools",
    "siderolabs/util-linux-tools"
  ]

  talos_image_extensions = distinct(
    concat(
      ["siderolabs/qemu-guest-agent"],
      var.talos_image_extensions,
      var.longhorn_enabled ? local.talos_image_extentions_longhorn : []
    )
  )
}

data "talos_image_factory_extensions_versions" "this" {
  count = var.talos_schematic_id == null ? 1 : 0

  talos_version = var.talos_version
  filters = {
    names = local.talos_image_extensions
  }
}

resource "talos_image_factory_schematic" "this" {
  count = var.talos_schematic_id == null ? 1 : 0

  schematic = yamlencode(
    {
      customization = {
        extraKernelArgs = var.talos_extra_kernel_args
        systemExtensions = {
          officialExtensions = (
            length(local.talos_image_extensions) > 0 ?
            data.talos_image_factory_extensions_versions.this[0].extensions_info.*.name :
            []
          )
        }
      }
    }
  )
}

data "talos_image_factory_urls" "amd64" {
  talos_version = var.talos_version
  schematic_id  = local.talos_schematic_id
  platform      = "hcloud"
  architecture  = "amd64"
}

data "talos_image_factory_urls" "arm64" {
  talos_version = var.talos_version
  schematic_id  = local.talos_schematic_id
  platform      = "hcloud"
  architecture  = "arm64"
}

# Installer images for external worker node pools (per platform/arch/schematic).
data "talos_image_factory_urls" "external_worker" {
  for_each = local.external_worker_schematic_data

  talos_version = var.talos_version
  schematic_id  = each.value.schematic_id
  platform      = each.value.platform
  architecture  = each.value.architecture
}

data "hcloud_images" "amd64" {
  count = local.amd64_image_required ? 1 : 0

  with_selector     = local.image_label_selector
  with_architecture = ["x86"]
  most_recent       = true
}

data "hcloud_images" "arm64" {
  count = local.arm64_image_required ? 1 : 0

  with_selector     = local.image_label_selector
  with_architecture = ["arm"]
  most_recent       = true
}

resource "terraform_data" "packer_init" {
  triggers_replace = [
    "${sha1(file("${path.module}/packer/requirements.pkr.hcl"))}",
    var.cluster_name,
    var.talos_version,
    local.talos_schematic_id,
    local.amd64_image_required,
    local.arm64_image_required
  ]

  provisioner "local-exec" {
    when        = create
    quiet       = true
    working_dir = "${path.module}/packer/"
    command     = "packer init -upgrade requirements.pkr.hcl"
  }

  depends_on = [data.external.client_prerequisites_check]
}

resource "terraform_data" "amd64_image" {
  count = local.amd64_image_required ? 1 : 0

  triggers_replace = [
    var.cluster_name,
    var.talos_version,
    local.talos_schematic_id
  ]

  provisioner "local-exec" {
    when        = create
    quiet       = true
    working_dir = "${path.module}/packer/"
    command = join(" ",
      [
        "${length(data.hcloud_images.amd64[0].images) > 0} ||",
        "packer build -force",
        "-var 'cluster_name=${var.cluster_name}'",
        "-var 'server_type=${var.packer_amd64_builder.server_type}'",
        "-var 'server_location=${var.packer_amd64_builder.server_location}'",
        "-var 'talos_version=${var.talos_version}'",
        "-var 'talos_schematic_id=${local.talos_schematic_id}'",
        "-var 'talos_image_url=${local.talos_amd64_image_url}'",
        "image_amd64.pkr.hcl"
      ]
    )
    environment = {
      HCLOUD_TOKEN = nonsensitive(var.hcloud_token)
    }
  }

  depends_on = [
    data.external.client_prerequisites_check,
    terraform_data.packer_init
  ]
}

resource "terraform_data" "arm64_image" {
  count = local.arm64_image_required ? 1 : 0

  triggers_replace = [
    var.cluster_name,
    var.talos_version,
    local.talos_schematic_id
  ]

  provisioner "local-exec" {
    when        = create
    quiet       = true
    working_dir = "${path.module}/packer/"
    command = join(" ",
      [
        "${length(data.hcloud_images.arm64[0].images) > 0} ||",
        "packer build -force",
        "-var 'cluster_name=${var.cluster_name}'",
        "-var 'server_type=${var.packer_arm64_builder.server_type}'",
        "-var 'server_location=${var.packer_arm64_builder.server_location}'",
        "-var 'talos_version=${var.talos_version}'",
        "-var 'talos_schematic_id=${local.talos_schematic_id}'",
        "-var 'talos_image_url=${local.talos_arm64_image_url}'",
        "image_arm64.pkr.hcl"
      ]
    )
    environment = {
      HCLOUD_TOKEN = nonsensitive(var.hcloud_token)
    }
  }

  depends_on = [
    data.external.client_prerequisites_check,
    terraform_data.packer_init
  ]
}

data "hcloud_image" "amd64" {
  count = local.amd64_image_required ? 1 : 0

  with_selector     = local.image_label_selector
  with_architecture = "x86"
  most_recent       = true

  depends_on = [terraform_data.amd64_image]
}

data "hcloud_image" "arm64" {
  count = local.arm64_image_required ? 1 : 0

  with_selector     = local.image_label_selector
  with_architecture = "arm"
  most_recent       = true

  depends_on = [terraform_data.arm64_image]
}

locals {
  # Per-discovered-external-node upgrade override, keyed by the node's reachable IP (the
  # value the worker/external upgrade loop iterates). Resolves the node's pool to its
  # installer image + schematic. Empty unless external_worker_discovery_enabled.
  external_worker_upgrade_overrides = {
    for hostname, s in local.talos_discovery_external_worker :
    coalesce(s.public_ipv4_address, s.private_ipv4_address) => {
      schematic_id = local.external_worker_nodepool_image[s.nodepool].schematic_id
      installer_image_url = data.talos_image_factory_urls.external_worker[
        "${local.external_worker_nodepool_image[s.nodepool].platform}:${local.external_worker_nodepool_image[s.nodepool].architecture}:${local.external_worker_nodepool_image[s.nodepool].schematic_id}"
      ].urls.installer
    }
  }
}
