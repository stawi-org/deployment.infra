# tofu/modules/gcp-account-infra/network.tf
#
# Per-account VPC + worker subnet + firewall. Mirrors the OCI public-
# worker security list shape: unrestricted egress, KubeSpan UDP 51820
# and Talos API TCP 50000 open from the internet (auth is WireGuard /
# client cert). Instances are tagged stawi-talos by node-gcp.

resource "google_compute_network" "this" {
  name                    = "stawi-${var.account_key}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  project                 = var.project_id
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
}

resource "google_compute_firewall" "egress_all" {
  name      = "stawi-${var.account_key}-egress"
  network   = google_compute_network.this.name
  project   = var.project_id
  direction = "EGRESS"
  allow { protocol = "all" }
  destination_ranges = ["0.0.0.0/0"]
}

# Intentional open ingress — same class as OCI seclist for Talos workers:
# KubeSpan hole-punching requires UDP 51820 from anywhere; Talos API is
# mTLS client-cert gated. See oracle-account-infra/network.tf.
#trivy:ignore:GCP-0073
resource "google_compute_firewall" "kubespan" {
  name    = "stawi-${var.account_key}-kubespan"
  network = google_compute_network.this.name
  project = var.project_id
  allow {
    protocol = "udp"
    ports    = ["51820"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["stawi-talos"]
  description   = "KubeSpan WireGuard; hole-punching from peer clouds. Mirrors OCI public workers."
}

#trivy:ignore:GCP-0073
resource "google_compute_firewall" "talos_api" {
  name    = "stawi-${var.account_key}-talos-api"
  network = google_compute_network.this.name
  project = var.project_id
  allow {
    protocol = "tcp"
    ports    = ["50000"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["stawi-talos"]
  description   = "Talos API; auth is client cert. Mirrors OCI public workers."
}
