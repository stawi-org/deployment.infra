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
  # Per-CP static IPv6 + kubelet nodeIP/validSubnets. Contabo has no
  # DHCPv6 so IPv6 must be declared statically; kubelet must be told
  # which subnets count as "the node's" for dual-stack scheduling.
  contabo_cp_nodes = {
    for k, v in local.controlplane_nodes : k => v if v.provider == "contabo"
  }
  cp_net_params = {
    for k, v in local.contabo_cp_nodes : k => {
      hostname     = k
      ipv4         = v.ipv4
      ipv4_gateway = format("%s.1", join(".", slice(split(".", v.ipv4), 0, 3)))
      ipv6         = v.ipv6
      # First four groups of the IPv6 + "::/64" = node's /64 subnet.
      # Handles both compressed and fully-expanded forms returned by
      # the Contabo API.
      ipv6_subnet  = v.ipv6 != null ? format("%s::/64", join(":", slice(split(":", v.ipv6), 0, 4))) : "::/128"
      ipv6_gateway = "fe80::1"
    }
  }

  # ---- certSANs ----
  # Pulled from dns.tf's local.cp_cert_sans — every cp-* FQDN across
  # every zone this layer publishes, plus operator-supplied extras.
  # Aliased here so the rest of this file can reference cp_cert_sans
  # unchanged.

  # ---- Admin-access firewall rule ---------------------------------
  # Talos API :50000 + Kubernetes API :6443 are restricted to the
  # GitHub Actions runner egress ranges (so tofu-apply can still
  # drive the cluster) plus var.admin_cidrs (operator IPs for direct
  # kubectl). Everything else in network.yaml is untouched — kubelet,
  # etcd, KubeSpan, and the CNI overlay still use their existing
  # intra-cluster rules.
  firewall_admin_patch = templatefile(
    "${path.module}/../../shared/patches/firewall-admin.yaml.tftpl",
    {
      talos_api_cidrs = local.admin_ingress_cidrs
      k8s_api_cidrs   = local.admin_ingress_cidrs
    },
  )

  # ---- Shared patch list (cluster-wide, provider-neutral) ----
  shared_cp_patches = [
    file("${path.module}/../../shared/patches/common.yaml"),
    file("${path.module}/../../shared/patches/network.yaml"),
    # firewall_admin_patch temporarily dropped during bootstrap — see
    # configs.tf local.firewall_admin_patch for rationale. Re-add once
    # the cluster is reachable and we've confirmed the fetched GitHub
    # Actions CIDR list covers the specific runner ranges in use.
    # local.firewall_admin_patch,
    file("${path.module}/../../shared/patches/storage.yaml"),
    file("${path.module}/../../shared/patches/resolvers.yaml"),
    file("${path.module}/../../shared/patches/timesync.yaml"),
    file("${path.module}/../../shared/patches/cluster-network.yaml"),
    yamlencode({
      machine = {
        certSANs = local.cp_cert_sans
      }
    }),
  ]
  shared_worker_patches = [
    file("${path.module}/../../shared/patches/common.yaml"),
    file("${path.module}/../../shared/patches/network.yaml"),
    # firewall_admin_patch temporarily dropped during bootstrap — see
    # configs.tf local.firewall_admin_patch for rationale. Re-add once
    # the cluster is reachable and we've confirmed the fetched GitHub
    # Actions CIDR list covers the specific runner ranges in use.
    # local.firewall_admin_patch,
    file("${path.module}/../../shared/patches/storage.yaml"),
    file("${path.module}/../../shared/patches/resolvers.yaml"),
    file("${path.module}/../../shared/patches/timesync.yaml"),
    file("${path.module}/../../shared/patches/cluster-network.yaml"),
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
}

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
    # Per-Contabo-CP patch: static IPv6 (DHCPv6 isn't available on
    # Contabo) + kubelet nodeIP pinning. Uses additive
    # machine.network.interfaces[].dhcp=true so DHCPv4 stays on.
    try([templatefile("${path.module}/../../shared/patches/node-contabo.tftpl", local.cp_net_params[each.key])], []),
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
