# tofu/modules/node-gcp/main.tf
#
# Single GCE worker instance. Boots Talos in maintenance mode from an
# Omni-aware custom image (siderolink.api is baked into the image
# schematic — same model as node-oracle). Spot by default.

resource "terraform_data" "force_reinstall" {
  # Whole-resource reference in replace_triggered_by fires when this
  # sentinel is replaced (triggers_replace changes). Mirrors
  # node-oracle's force_reinstall pattern.
  triggers_replace = [var.force_reinstall_generation]
}

# Intentional design vs generic GCE CIS/trivy defaults:
# - public IP + can_ip_forward: cross-cloud KubeSpan/Flannel + CNI (mirrors OCI)
# - empty metadata / no OS Login / no project SSH keys: Talos has no SSH
# - no CMEK / shielded-VM suite: out of v1 scope for Spot Talos workers
#trivy:ignore:GCP-0030
#trivy:ignore:GCP-0031
#trivy:ignore:GCP-0033
#trivy:ignore:GCP-0036
#trivy:ignore:GCP-0041
#trivy:ignore:GCP-0043
#trivy:ignore:GCP-0045
#trivy:ignore:GCP-0067
resource "google_compute_instance" "this" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  # Prefer stop/start over destroy/create for in-place updates that
  # GCE can apply without replacing the instance (e.g. some metadata
  # paths). Spot + boot_disk ignore_changes keep fleet churn low.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.boot_disk_gb
      # pd-standard is enough for Talos boot + local scratch on Spot
      # workers and is ~half the $/GB of pd-balanced. Operators can
      # force a recreate with force_reinstall_generation if they need
      # a different disk type later (boot_disk is ignore_changes).
      type = "pd-standard"
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
    # Ephemeral public IPv4 — released when the instance terminates.
    access_config {}
  }

  # Required for CNI / KubeSpan encapsulation paths that rewrite packet
  # destinations (mirrors OCI skip_source_dest_check).
  can_ip_forward = true

  # Firewall target tag — gcp-account-infra rules match this tag.
  tags = ["stawi-talos"]

  # Spot by default; STANDARD when preemptible=false.
  # STOP (not DELETE) on preemption: boot disk + Talos state survive so
  # the node re-registers to Omni under the same Machine UUID after
  # desired_status=RUNNING restarts it. DELETE created ghost twins on
  # every preemption. instance_termination_action is Spot-only.
  scheduling {
    preemptible                 = var.preemptible
    automatic_restart           = var.preemptible ? false : true
    on_host_maintenance         = var.preemptible ? "TERMINATE" : "MIGRATE"
    provisioning_model          = var.preemptible ? "SPOT" : "STANDARD"
    instance_termination_action = var.preemptible ? "STOP" : null
  }

  # After Spot STOP, the next tofu apply starts the instance when
  # capacity is available (idempotent RUNNING reconciliation).
  desired_status = "RUNNING"

  # No metadata. GCP nodes boot in Talos maintenance mode; Omni pushes
  # machine config after SideroLink registration (kernel arg baked into
  # the image). Empty map is intentional — do not inject user-data.
  metadata = {}

  # GCE label values must match [a-z0-9_-]; sanitize account_key.
  labels = {
    stawi_provider = "gcp"
    stawi_account  = lower(replace(var.account_key, "/[^a-z0-9_-]/", "-"))
    stawi_role     = var.role
    stawi_spot     = var.preemptible ? "true" : "false"
  }

  lifecycle {
    # Omni / in-guest tools may touch metadata after first boot;
    # never churn the instance for metadata drift.
    # boot_disk: image self_link / size drift must NOT recreate the
    # fleet on every sync-talos-images run. New nodes still boot from
    # the current image at create time. Intentional reimage is only
    # force_reinstall_generation (operator-controlled). In-place
    # Talos upgrades go through Omni, not GCE disk reimage.
    ignore_changes = [
      metadata,
      boot_disk,
    ]
    replace_triggered_by = [
      terraform_data.force_reinstall,
    ]
  }
}

locals {
  nic0       = google_compute_instance.this.network_interface[0]
  private_ip = try(local.nic0.network_ip, null)
  public_ip  = try(local.nic0.access_config[0].nat_ip, null)
  # Prefer public IPv4 for endpoints; fall back to private if absent.
  ipv4 = coalesce(local.public_ip, local.private_ip)

  derived_labels = merge(
    {
      "node.stawi.org/provider" = "gcp"
      "node.stawi.org/account"  = var.account_key
      "node.stawi.org/role"     = var.role
      "node.stawi.org/name"     = var.name
      "node.stawi.org/spot"     = var.preemptible ? "true" : "false"
    },
    var.labels,
  )

  derived_annotations = merge(
    {
      "node.stawi.org/provider"     = "gcp"
      "node.stawi.org/account"      = var.account_key
      "node.stawi.org/role"         = var.role
      "node.stawi.org/machine-type" = var.machine_type
      "node.stawi.org/zone"         = var.zone
    },
    # Flannel public-ip-overwrite: GCP external IPv4 is 1:1 NAT to the
    # primary NIC address, so kubelet may see the private IP. Force
    # Flannel to use the actual public IP for cross-node VXLAN when
    # an external address is present.
    local.public_ip != null ? {
      "flannel.alpha.coreos.com/public-ip-overwrite" = local.public_ip
    } : {},
    var.annotations,
  )
}
