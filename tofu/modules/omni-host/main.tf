# tofu/modules/omni-host/main.tf
#
# Single Contabo VPS running Omni + Dex + Caddy via docker-compose. All
# configuration declarative via cloud-init; no SSH-driven setup.
#
# License note: Omni is BSL-licensed (non-production self-host, option iii).
# Revisit when Stawi has production revenue.

resource "random_uuid" "omni_account_id" {
  # The Omni account ID is baked into every machine's SideroLink config.
  # Rotating it (e.g. by re-creating the random_uuid resource via state
  # rebuild) would orphan every cluster the host has ever provisioned —
  # they'd reject the new ID's signed configs. Pin it.
  lifecycle {
    ignore_changes = [keepers]
  }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle {
    ignore_changes = [length, special]
  }
}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
    {
      omni_version                         = var.omni_version
      dex_version                          = var.dex_version
      caddy_version                        = var.caddy_version
      omni_account_name                    = var.omni_account_name
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      dex_omni_client_secret               = random_password.dex_omni_client_secret.result
      initial_users                        = var.initial_users
      eula_name                            = var.eula_name
      eula_email                           = var.eula_email
    }
  )

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      name                           = var.name
      docker_compose_yaml            = local.docker_compose_yaml
      omni_account_id                = random_uuid.omni_account_id.result
      dex_omni_client_secret         = random_password.dex_omni_client_secret.result
      siderolink_api_advertised_host = var.siderolink_api_advertised_host
      github_oidc_client_id          = var.github_oidc_client_id
      github_oidc_client_secret      = var.github_oidc_client_secret
      github_oidc_allowed_orgs       = var.github_oidc_allowed_orgs
      tls_cert_pem                   = var.tls_cert_pem
      tls_key_pem                    = var.tls_key_pem
      cloudflare_api_token           = var.cloudflare_api_token
      cloudflare_zone_id             = var.cloudflare_zone_id
      cloudflare_dns_record_ids      = var.cloudflare_dns_record_ids
    }
  )
}

resource "contabo_instance" "this" {
  display_name = var.name
  product_id   = var.contabo_product_id
  region       = var.contabo_region
  image_id     = var.contabo_image_id
  user_data    = local.user_data
  period       = 1

  # Contabo VPSs are NEVER destroyed/replaced via tofu. user_data and
  # image_id are absorbed here; in-place reinstall on user_data drift
  # is driven by null_resource.ensure_image below, which re-uses the
  # node-contabo module's ensure-image.sh (the official internal driver
  # for Contabo VPS lifecycle). MODE=reinstall always — first-create
  # technically wastes one redundant install pass; rare enough to ignore.
  lifecycle {
    ignore_changes = [user_data, image_id]
  }
}

# Reinstall-in-place driver. Triggers when:
#   - contabo_instance.this.id is fresh (first apply for this VPS)
#   - the rendered user_data hash drifts (Omni version bump, cert
#     rotation, cloud-init structural change, Caddy/Dex bumps, etc.)
#
# Calls into tofu/modules/node-contabo/ensure-image.sh — the official
# Contabo VPS lifecycle driver in this repo. Adds two parameters to
# what node-contabo passes: USER_DATA (full omni-host cloud-init,
# instead of the minimal stub Talos uses), and READY_CHECK pointing
# at https://cp.<zone>/ (instead of Talos's TCP probe on :50000).
resource "null_resource" "ensure_image" {
  triggers = {
    instance_id    = contabo_instance.this.id
    user_data_hash = sha256(local.user_data)
  }
  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      MODE                  = "reinstall"
      INSTANCE_ID           = contabo_instance.this.id
      TARGET_IMAGE_ID       = var.contabo_image_id
      USER_DATA             = local.user_data
      NODE_ROLE             = "controlplane" # fail tofu on errors (single VPS, no fleet isolation)
      READY_CHECK           = "https:https://${var.siderolink_api_advertised_host}/"
      CONTABO_CLIENT_ID     = var.contabo_client_id
      CONTABO_CLIENT_SECRET = var.contabo_client_secret
      CONTABO_API_USER      = var.contabo_api_user
      CONTABO_API_PASSWORD  = var.contabo_api_password
    }
    command = "${path.module}/../node-contabo/ensure-image.sh"
  }
}
