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
#
# ---------------------------------------------------------------------
# Audit: where each part of a CP machine config comes from
# ---------------------------------------------------------------------
# Critical security/identity material flowing into every CP config —
# documented here so a future operator can verify a single rendered
# config and trust the whole fleet.
#
#   PKI / tokens / cluster identity
#     machine_secrets  ← layer 00 tfstate (data.terraform_remote_state
#                        .secrets.outputs.machine_secrets). Layer 00 is
#                        INTENTIONALLY never wiped — cluster-reset.yml
#                        only purges layers 01/02/03 state. Same machine
#                        CA, cluster CA, kube CA, bootstrap token, and
#                        machine token are reused across every reinstall
#                        so a freshly-wiped node rejoins the existing
#                        cluster instead of forking a new trust root.
#     cluster_name     ← var.cluster_name (terraform.tfvars default
#                        "antinvestor-cluster"). Pinned per environment.
#     cluster_endpoint ← var.cluster_endpoint ("https://cp.antinvestor
#                        .com:6443"). MUST be a hostname that's also in
#                        cp_cert_sans (precondition asserts this).
#
#   Cert SANs (apid + apiserver)
#     local.cp_cert_sans  ← dns.tf, derived from var.cp_dns_zones:
#                            cp.<zone>      (round-robin)
#                            cp-1.<zone>..cp-N.<zone>  (per-CP, sorted
#                            stably by node_key)
#                          + var.extra_cert_sans (operator-supplied).
#                          Same source of truth feeds Cloudflare DNS
#                          records — change a zone, both DNS and SANs
#                          update in one apply.
#
#   Dial target (how this layer's apply path talks to the node)
#     local.per_node_apply_target[k]  ← apply.tf. For CPs this resolves
#                                        to "cp-N.<first-zone>" using
#                                        the same cp_sorted_keys ordering
#                                        as cp_cert_sans, so the dial
#                                        target is GUARANTEED to be in
#                                        SANs (precondition asserts it
#                                        too, defensively).
#
#   Installer image (Talos version pinning)
#     talos_image_factory_schematic.this.id + var.talos_version  ← image.tf
#                        + tofu/shared/versions.auto.tfvars.json
#                        Combined into local.installer_image_patch below.
#
# Worker configs use the same machine_secrets / cluster_name /
# cluster_endpoint, but DON'T set certSANs — workers don't run apiserver
# or etcd, and Talos auto-includes their on-NIC IPs as apid SANs. Today's
# worker dial targets are all on-NIC public IPv4 (Contabo workers); the
# day we add a NAT'd worker (OCI), we'll need per-worker DNS + SANs too.
# Tracked as a TODO in apply.tf's per_node_apply_target comment.

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
    # worker apid certs need every worker-<N>.<zone> name in their SAN
    # list so this layer's per-node apply can dial workers by a stable
    # DNS name (NAT'd public IPs aren't on the NIC and so aren't in
    # Talos's auto-SAN list). One shared list across all workers — same
    # pattern as CPs above; small cert bloat (~one entry per worker)
    # in exchange for a single SAN definition that doesn't need to be
    # split per node.
    yamlencode({
      machine = {
        certSANs = local.worker_cert_sans
      }
    }),
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

  # Identity invariants. Asserted at plan time so a stale endpoint /
  # zone change can never produce a config whose certificates won't
  # validate against the address the apply path dials. The precise
  # failure modes these guard against:
  #
  #   1) cluster_endpoint hostname missing from cert SANs ⇒ kubectl
  #      and the kube-apiserver-as-a-client (etcd peer dial, kubelet
  #      bootstrap) get x509 SAN-mismatch errors. Cluster won't form.
  #   2) Per-CP dial target (cp-N.<zone>) missing from cert SANs ⇒
  #      this layer's own talosctl apply-config fails immediately;
  #      apply path stalls or wedges.
  #
  # Both are silent until the apply hits the wire. Surface them at
  # plan time instead so a misconfiguration shows up in the PR diff.
  lifecycle {
    precondition {
      condition = contains(
        local.cp_cert_sans,
        regex("^https?://([^:/]+)", var.cluster_endpoint)[0],
      )
      error_message = "cluster_endpoint host (${var.cluster_endpoint}) is not in cp_cert_sans (${join(", ", local.cp_cert_sans)}). Update var.cp_dns_zones or var.extra_cert_sans, or change var.cluster_endpoint to a hostname that's already in SANs."
    }
    precondition {
      # Either an IP (Talos auto-includes interface IPs as SANs and
      # we accept that path), or an explicitly-listed SAN.
      condition = (
        can(regex("^[0-9.]+$", local.per_node_apply_target[each.key]))
        || contains(local.cp_cert_sans, local.per_node_apply_target[each.key])
      )
      error_message = "per-node dial target for CP ${each.key} (${local.per_node_apply_target[each.key]}) is not in cp_cert_sans. cp_sorted_keys index drift between dns.tf and apply.tf."
    }
  }
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

  # Mirror of the CP precondition above. Only check workers that this
  # layer will actually try to dial (direct_apply_nodes filters out
  # nodes without any public IP — those join via KubeSpan and aren't
  # configured by this layer's apply path). For the rest, the dial
  # target must either be an IP (Talos auto-SAN handles on-NIC IPs)
  # or be in worker_cert_sans.
  lifecycle {
    precondition {
      condition = (
        !contains(keys(local.direct_apply_nodes), each.key)
        || can(regex("^[0-9.]+$", local.per_node_apply_target[each.key]))
        || contains(local.worker_cert_sans, local.per_node_apply_target[each.key])
      )
      error_message = "per-node dial target for worker ${each.key} (${try(local.per_node_apply_target[each.key], "<not in direct_apply_nodes>")}) is not in worker_cert_sans (${join(", ", local.worker_cert_sans)}). worker_sorted_keys index drift between dns.tf and apply.tf, or a NAT'd public IP not anchored to a worker-N.<zone> name."
    }
  }
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
