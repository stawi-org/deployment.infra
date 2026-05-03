# tofu/modules/omni-host-contabo/main.tf
#
# Single Contabo VPS (existing, adopted by id) running Omni + Dex +
# nginx via docker-compose. Configuration declarative via cloud-init.
# Contabo substrate variant of tofu/modules/omni-host-oci.
#
# Two-phase lifecycle (mirrors node-contabo):
#   - contabo_instance.this owns naming + image_id + product/region.
#     image_id changes are ignored at provider level (the provider's
#     reinstall path is broken — see node-contabo comment).
#   - null_resource.ensure_image owns the actual reinstall trigger via
#     ensure-image.sh, which PUTs a full payload to Contabo's API.
#     Bumping force_reinstall_generation re-runs unconditionally.
#
# product_id is intentionally omitted: the module adopts an existing
# VPS (imported via var.vps_id at the layer level), and Contabo's API
# cannot change a VPS product class in-place. Setting product_id here
# would only matter at create time — which never happens for adopted
# instances. No variable needed; whatever the VPS already has is
# retained.
#
# user_data is intentionally NOT set on contabo_instance.this: the
# provider's image_id-only PUT is broken (mirrors node-contabo's
# documented caveat), so the resource-level user_data would never
# be delivered to the VM. Actual cloud-init delivery goes through
# ensure-image.sh's reinstall PUT via USER_DATA env var.

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
}

resource "contabo_instance" "this" {
  display_name = var.name
  region       = var.region
  image_id     = var.image_id
  period       = 1

  # See node-contabo's identical block: the provider's image_id-only
  # PUT is broken, so we ignore it and let ensure-image.sh own
  # reinstall drift correction.
  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "null_resource" "ensure_image" {
  triggers = {
    instance_id                = contabo_instance.this.id
    target_image_id            = var.image_id
    force_reinstall_generation = var.force_reinstall_generation
    user_data_sha256           = sha256(local.user_data)
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      INSTANCE_ID           = contabo_instance.this.id
      TARGET_IMAGE_ID       = var.image_id
      USER_DATA             = local.user_data
      CONTABO_CLIENT_ID     = var.contabo_client_id
      CONTABO_CLIENT_SECRET = var.contabo_client_secret
      CONTABO_API_USER      = var.contabo_api_user
      CONTABO_API_PASSWORD  = var.contabo_api_password
      NODE_ROLE             = "omni-host"
      # FORCE_REINSTALL=1 skips the imageId-equality short-circuit so the
      # PUT fires unconditionally — used for config-only redeployments
      # where the image hasn't changed (e.g. vpn_users update).
      FORCE_REINSTALL = var.force_reinstall_generation > 1 ? "1" : "0"
    }
    command = "${path.module}/ensure-image.sh"
  }
}

# Block downstream layers on omni-stack readiness, same as omni-host-oci.
resource "null_resource" "wait_for_omni_ready" {
  depends_on = [null_resource.ensure_image]

  triggers = {
    instance_id = contabo_instance.this.id
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
