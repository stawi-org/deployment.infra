# tofu/modules/omni-host-gcp/network.tf
#
# Dedicated VPC for Omni (not the Spot worker VPC). Static external IP
# so cp.stawi.org / cpd.stawi.org stay stable across instance replace.

resource "google_compute_network" "omni" {
  project                 = var.project_id
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

#trivy:ignore:GCP-0029
#trivy:ignore:GCP-0075
#trivy:ignore:GCP-0076
resource "google_compute_subnetwork" "omni" {
  project                  = var.project_id
  name                     = "${var.name}-subnet"
  ip_cidr_range            = var.vpc_cidr
  region                   = var.region
  network                  = google_compute_network.omni.id
  private_ip_google_access = true
}

resource "google_compute_address" "omni" {
  project = var.project_id
  name    = "${var.name}-ipv4"
  region  = var.region
}

# Public Omni endpoints (cp/cpd) require 0.0.0.0/0 on Omni ports — same as Contabo/OCI.
#trivy:ignore:GCP-0071
#trivy:ignore:GCP-0073
resource "google_compute_firewall" "omni_ingress" {
  project = var.project_id
  name    = "${var.name}-ingress"
  network = google_compute_network.omni.name

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8090", "8100"]
  }

  allow {
    protocol = "udp"
    # 50180 SideroLink WG; 51820 admin user-VPN
    ports = ["50180", "51820"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["omni-host"]
  description   = "Omni UI, machine-api, k8s-proxy, SideroLink WG, user-VPN"
}

resource "google_compute_firewall" "omni_egress" {
  project   = var.project_id
  name      = "${var.name}-egress"
  network   = google_compute_network.omni.name
  direction = "EGRESS"

  allow {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["omni-host"]
}
