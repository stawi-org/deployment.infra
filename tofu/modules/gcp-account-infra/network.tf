# tofu/modules/gcp-account-infra/network.tf
#
# Per-account VPC + worker subnet + firewall. Mirrors the OCI public-
# worker security list shape for the ports we need.
#
# Efficiency notes:
# - auto_create_subnetworks = false (no default /20 sprawl).
# - Default VPC CIDR is /24 (see variables) — enough for workers, not a /16.
# - No explicit egress rule: custom-mode VPC already has implied allow-all
#   egress; an extra EGRESS rule is pure API noise.
# - One ingress rule for both KubeSpan + Talos API (one resource, not two).

resource "google_compute_network" "this" {
  name                    = "stawi-${var.account_key}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  project                 = var.project_id
  description             = "Stawi Talos workers (${var.account_key})"
}

# Intentional design vs generic GCE CIS/trivy defaults:
# - no VPC flow logs / Private Google Access: out of v1 scope for Spot
#   Talos workers (public IPv4, same posture as OCI public workers)
#trivy:ignore:GCP-0029
#trivy:ignore:GCP-0075
#trivy:ignore:GCP-0076
resource "google_compute_subnetwork" "workers" {
  name          = "stawi-${var.account_key}-workers"
  ip_cidr_range = var.vpc_cidr
  region        = var.region
  network       = google_compute_network.this.id
  project       = var.project_id
  description   = "Worker subnet for Spot/standard Talos nodes"
}

# Intentional open ingress — same class as OCI seclist for Talos workers:
# KubeSpan hole-punching requires UDP 51820 from anywhere; Talos API is
# mTLS client-cert gated. See oracle-account-infra/network.tf.
#trivy:ignore:GCP-0073
resource "google_compute_firewall" "talos_workers" {
  name        = "stawi-${var.account_key}-talos-workers"
  network     = google_compute_network.this.name
  project     = var.project_id
  description = "KubeSpan (UDP 51820) + Talos API (TCP 50000); mirrors OCI public workers."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }
  allow {
    protocol = "tcp"
    ports    = ["50000"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["stawi-talos"]
}
