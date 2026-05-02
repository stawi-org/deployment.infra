# tofu/modules/omni-host-oci/main.tf
#
# Single OCI ARM A1.Flex VM running Omni + Dex + Caddy via docker-
# compose. Configuration declarative via cloud-init. OCI substrate
# variant of tofu/modules/omni-host (Contabo).
#
# Replacement triggers: oci_core_instance natively recreates on
# metadata.user_data change (provider-default lifecycle). No
# null_resource.ensure_image equivalent needed — the OCI provider
# does what Contabo's PUT script approximated.

resource "random_uuid" "omni_account_id" {
  # The Omni account ID is baked into every Machine's SideroLink
  # config. Rotating it would orphan every cluster the host has
  # ever provisioned. Pin it.
  lifecycle { ignore_changes = [keepers] }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle { ignore_changes = [length, special] }
}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
    {
      omni_version                         = var.omni_version
      dex_version                          = var.dex_version
      nginx_version                        = var.nginx_version
      omni_account_id                      = random_uuid.omni_account_id.result
      omni_account_name                    = var.omni_account_name
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      dex_omni_client_secret               = random_password.dex_omni_client_secret.result
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
      dex_omni_client_secret               = random_password.dex_omni_client_secret.result
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
}

# Auto-discover the tenancy's ADs and pick by index — same pattern
# oracle-account-infra uses for cluster nodes. Operator doesn't set
# the AD-name string; index 0 picks the first AD (clamped to last
# AD if index is out-of-range so single-AD regions still work).
data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  available_ads = data.oci_identity_availability_domains.this.availability_domains[*].name
  ad_index      = min(var.availability_domain_index, length(local.available_ads) - 1)
  selected_ad   = local.available_ads[local.ad_index]
}

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.selected_ad
  shape               = var.shape
  display_name        = var.name

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = var.ubuntu_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = false # Reserved IP attached separately (network.tf).
    assign_ipv6ip    = var.enable_ipv6
    # No hostname_label: enabling it requires dns_label on both the
    # VCN and subnet, which wires up OCI's internal DNS service for
    # the subnet. The omni-host is reached publicly via cp.stawi.org
    # (Cloudflare-fronted) and SideroLink uses public IPs — no
    # internal DNS resolution needed. Dropping the label keeps the
    # network setup minimal.
  }

  metadata = {
    # OCI's instance.metadata is capped at 32 KB total. The omni-
    # host's cloud-init template is ~800 lines and base64-encodes
    # to ~54 KB — over the cap. base64gzip() (gzip + base64) gets
    # us to ~15-20 KB. cloud-init auto-detects gzip-compressed
    # user_data and decompresses transparently, so no consumer-
    # side change is needed.
    user_data = base64gzip(local.user_data)
  }

  preserve_boot_volume = false
}

# Block downstream layers on omni-stack readiness post-apply, so any
# follow-on layer that runs omnictl operations doesn't race a still-
# booting Omni. Polls /healthz on the public hostname.
resource "null_resource" "wait_for_omni_ready" {
  depends_on = [oci_core_instance.this, oci_core_public_ip.this]

  triggers = {
    instance_id = oci_core_instance.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      ENDPOINT = "https://${var.siderolink_api_advertised_host}/healthz"
    }
    command = <<-EOT
      set -euo pipefail
      echo "[wait_for_omni_ready] polling $ENDPOINT"
      deadline=$(( $(date +%s) + 600 ))
      while :; do
        code=$(curl -ksS -o /dev/null -w '%%{http_code}' --max-time 5 "$ENDPOINT" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
          echo "[wait_for_omni_ready] $ENDPOINT returned 200"
          exit 0
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
          echo "[wait_for_omni_ready] timed out after 10min waiting for $ENDPOINT (last code: $code)" >&2
          exit 1
        fi
        sleep 10
      done
    EOT
  }
}
