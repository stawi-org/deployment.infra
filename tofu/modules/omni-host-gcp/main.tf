# tofu/modules/omni-host-gcp/main.tf
#
# Single GCE VM (STANDARD, never Spot) running Omni + Dex + nginx via
# docker-compose. Mirrors omni-host-contabo / omni-host-oci cloud-init
# stack. Intended for Always Free e2-micro in us-central1/us-west1/us-east1
# (with swap) or a paid STANDARD e2-small/medium for production comfort.

data "google_compute_image" "ubuntu" {
  project = "ubuntu-os-cloud"
  family  = "ubuntu-2404-lts-amd64"
}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/../../shared/templates/omni-host/docker-compose.yaml.tftpl",
    {
      omni_version                         = var.omni_version
      dex_version                          = var.dex_version
      nginx_version                        = var.nginx_version
      omni_account_id                      = var.omni_account_id
      omni_account_name                    = var.omni_account_name
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      dex_omni_client_secret               = var.dex_omni_client_secret
      initial_users                        = var.initial_users
      eula_name                            = var.eula_name
      eula_email                           = var.eula_email
      etcd_backup_enabled                  = var.etcd_backup_enabled
    }
  )

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      name                                 = var.name
      docker_compose_yaml                  = local.docker_compose_yaml
      dex_omni_client_secret               = var.dex_omni_client_secret
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      github_oidc_client_id                = var.github_oidc_client_id
      github_oidc_client_secret            = var.github_oidc_client_secret
      github_oidc_allowed_orgs             = var.github_oidc_allowed_orgs
      cf_dns_api_token                     = var.cf_dns_api_token
      eula_email                           = var.eula_email
      ssh_authorized_keys                  = var.ssh_authorized_keys
      r2_account_id                        = var.r2_account_id
      r2_access_key_id                     = var.r2_access_key_id
      r2_secret_access_key                 = var.r2_secret_access_key
      r2_bucket_name                       = var.r2_bucket_name
      r2_backup_prefix                     = var.r2_backup_prefix
      vpn_users = {
        for idx, name in sort(keys(var.vpn_users)) :
        name => {
          public_key  = var.vpn_users[name].public_key
          assigned_ip = "10.100.0.${idx + 2}"
        }
      }
    }
  )

  gce_labels = merge(
    {
      stawi_role     = "omni-host"
      stawi_provider = "gcp"
    },
    var.labels,
  )
}

# Omni must be internet-reachable (cp/cpd public DNS). Same posture as
# Contabo/OCI Omni hosts. Trivy ignores match node-gcp / intentional design.
#trivy:ignore:GCP-0030
#trivy:ignore:GCP-0031
#trivy:ignore:GCP-0033
#trivy:ignore:GCP-0036
#trivy:ignore:GCP-0041
#trivy:ignore:GCP-0045
#trivy:ignore:GCP-0067
resource "google_compute_instance" "omni" {
  project      = var.project_id
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  # Always-on management plane — never Spot/preemptible.
  scheduling {
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.boot_disk_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.omni.id
    access_config {
      nat_ip = google_compute_address.omni.address
    }
  }

  tags = ["omni-host"]

  labels = local.gce_labels

  metadata = {
    user-data              = local.user_data
    block-project-ssh-keys = "TRUE"
    enable-oslogin         = "FALSE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  allow_stopping_for_update = true

  # Force replace when cloud-init content changes (Omni has no hot-reload;
  # same philosophy as Contabo ensure-image / user_data_sha256 trigger).
  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
    ]
    replace_triggered_by = [
      terraform_data.user_data,
    ]
  }
}

resource "terraform_data" "user_data" {
  input = sha256(local.user_data)
}
