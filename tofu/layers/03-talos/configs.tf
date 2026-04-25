# tofu/layers/03-talos/configs.tf
#
# Talos machine-config generation. Produces:
#   - `cp[<key>]`     — per-control-plane config, with platform-specific
#                       static networking (LinkConfig + HostnameConfig +
#                       kubelet.nodeIP.validSubnets) for Contabo nodes
#                       auto-derived from layer 01's live IPs.
#   - `worker[<key>]` — per-worker config for every declared worker node
#                       (OCI, Contabo worker pools, and named on-prem
#                       workers). Contabo workers get static IP patches;
#                       OCI workers use cloud metadata; on-prem workers
#                       rely on their local network and KubeSpan.
#   - `generic_worker` — a platform-neutral worker config with only the
#                       shared patches, suitable for on-prem/home-lab
#                       machines joining via KubeSpan over outbound
#                       internet. Published as an artifact.

locals {
  # Per-Contabo-node static IPv6 + kubelet nodeIP/validSubnets. Contabo
  # has no DHCPv6 so IPv6 must be declared statically; kubelet must be
  # told which subnets count as "the node's" so it advertises the
  # public IPv6 GUA as INTERNAL-IP rather than a KubeSpan ULA.
  #
  # Same patch shape for CPs and workers — only the per_node_configs
  # consumer differs (CP patch list vs worker patch list).
  contabo_nodes = {
    for k, v in local.all_nodes_from_state : k => v if try(v.provider, "") == "contabo"
  }
  contabo_net_params = {
    for k, v in local.contabo_nodes : k => {
      hostname     = k
      ipv4         = v.ipv4
      ipv4_gateway = format("%s.1", join(".", slice(split(".", v.ipv4), 0, 3)))
      ipv6         = v.ipv6
      # First four groups of the IPv6 + "::/64" = node's /64 subnet.
      # Handles both compressed and fully-expanded forms returned by
      # the Contabo API.
      ipv6_subnet  = try(v.ipv6, null) != null ? format("%s::/64", join(":", slice(split(":", v.ipv6), 0, 4))) : "::/128"
      ipv6_gateway = "fe80::1"
    }
  }

  # ---- certSANs ----
  # Pulled from dns.tf's local.cp_cert_sans — every cp-* FQDN across
  # every zone this layer publishes, plus operator-supplied extras.
  # Aliased here so the rest of this file can reference cp_cert_sans
  # unchanged.

  # ---- Shared patch list (cluster-wide, provider-neutral) ----
  # apid (:50000) is narrowed by firewall.tf to GitHub Actions egress +
  # var.admin_cidrs (CI runners + operator IPs). kube-apiserver (:6443)
  # stays at network.yaml's 0.0.0.0/0 + ::/0 — it'll be gated at the
  # auth layer (kubelogin → GitHub OIDC) rather than by network ACL.
  shared_cp_patches = [
    file("${path.module}/../../shared/patches/common.yaml"),
    file("${path.module}/../../shared/patches/network.yaml"),
    local.firewall_talos_api_patch,
    file("${path.module}/../../shared/patches/storage.yaml"),
    file("${path.module}/../../shared/patches/resolvers.yaml"),
    file("${path.module}/../../shared/patches/timesync.yaml"),
    file("${path.module}/../../shared/patches/cluster-network.yaml"),
    local.installer_image_patch,
    yamlencode({
      machine = {
        certSANs = local.cp_cert_sans
      }
    }),
  ]
  shared_worker_patches = [
    file("${path.module}/../../shared/patches/common.yaml"),
    file("${path.module}/../../shared/patches/network.yaml"),
    local.firewall_talos_api_patch,
    file("${path.module}/../../shared/patches/storage.yaml"),
    file("${path.module}/../../shared/patches/resolvers.yaml"),
    file("${path.module}/../../shared/patches/timesync.yaml"),
    file("${path.module}/../../shared/patches/cluster-network.yaml"),
    local.installer_image_patch,
  ]
  worker_hostname_patches = {
    for k, _ in local.worker_nodes : k => <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    hostname: ${k}
    auto: off
    EOT
  }

  # Pin machine.install.image to the factory installer for our exact
  # schematic + Talos version. Without this, Talos defaults to whatever
  # the talos provider version emits (currently v1.13.0-alpha.2 from
  # provider 0.11.0-beta.1), which silently drifts the cluster off
  # var.talos_version. Multi-arch manifest, so the same URL works for
  # Contabo amd64 and OCI arm64 — Docker picks the right one per node.
  installer_image_patch = yamlencode({
    machine = {
      install = {
        image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"
      }
    }
  })
}

# Schematic resource lives in image.tf — its id is referenced above.

data "talos_machine_configuration" "cp" {
  for_each           = local.controlplane_nodes
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = data.terraform_remote_state.secrets.outputs.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  config_patches = concat(
    local.shared_cp_patches,
    # Per-Contabo-node patch: static IPv6 (DHCPv6 isn't available on
    # Contabo) + kubelet nodeIP/validSubnets pinning so the public
    # IPv6 GUA — not a KubeSpan ULA — is advertised as INTERNAL-IP.
    # Same shape for CPs and workers; non-Contabo providers fall
    # through (try() returns []).
    try([templatefile("${path.module}/../../shared/patches/node-contabo.tftpl", local.contabo_net_params[each.key])], []),
    [
      yamlencode({
        machine = {
          nodeLabels      = each.value.derived_labels
          nodeAnnotations = each.value.derived_annotations
        }
      }),
    ],
  )
}

data "talos_machine_configuration" "worker" {
  for_each           = local.worker_nodes
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = data.terraform_remote_state.secrets.outputs.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  config_patches = concat(
    local.shared_worker_patches,
    # Same per-Contabo-node patch as CPs above. Workers without a
    # contabo_net_params entry (OCI / onprem) fall through.
    try([templatefile("${path.module}/../../shared/patches/node-contabo.tftpl", local.contabo_net_params[each.key])], []),
    [
      local.worker_hostname_patches[each.key],
      yamlencode({
        machine = {
          nodeLabels      = each.value.derived_labels
          nodeAnnotations = each.value.derived_annotations
        }
      }),
    ],
  )
}

# Platform-neutral worker config. Contains only the shared patches — no
# LinkConfig, no cloud metadata assumptions. Suitable for a laptop or
# on-prem box that reaches the internet over its local network and
# joins the cluster through the outbound KubeSpan WireGuard tunnel.
# No public IP needed on the joining machine.
data "talos_machine_configuration" "generic_worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = data.terraform_remote_state.secrets.outputs.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches     = local.shared_worker_patches
}
