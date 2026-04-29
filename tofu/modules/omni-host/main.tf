# tofu/modules/omni-host/main.tf
#
# Single Contabo VPS running Omni + Dex + cloudflared via docker-compose.
# All configuration declarative via cloud-init; no SSH-driven setup.
#
# License note: Omni is BSL-licensed (non-production self-host, option iii).
# Revisit when Stawi has production revenue.
#
# Provider note: uses the existing repo-standard contabo/contabo provider
# (same as tofu/modules/node-contabo). Provider credentials are wired at
# the layer level (tofu/layers/00-omni-server) via the provider alias.

resource "random_uuid" "omni_account_id" {}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
    {
      omni_version                   = var.omni_version
      dex_version                    = var.dex_version
      cloudflared_version            = var.cloudflared_version
      omni_account_name              = var.omni_account_name
      siderolink_api_advertised_host = var.siderolink_api_advertised_host
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
      cloudflare_tunnel_token        = var.cloudflare_tunnel_token
      r2_endpoint                    = var.r2_endpoint
      r2_backup_access_key_id        = var.r2_backup_access_key_id
      r2_backup_secret_access_key    = var.r2_backup_secret_access_key
      r2_backup_bucket               = var.r2_backup_bucket
      r2_backup_prefix               = var.r2_backup_prefix
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

  # IMPORTANT: user_data is intentionally frozen post-creation.
  # cloud-init runs once at first boot; re-applying user_data does NOT
  # re-run cloud-init on the live VM. Tofu plan will silently swallow
  # any template-variable changes (omni_version, dex_version,
  # cloudflare_tunnel_token, etc.) without visible diff.
  #
  # To push config changes to a running host, choose:
  #   - Minor (bump container tags / rotate env): log in via Contabo
  #     serial console (root password from Contabo dashboard), edit
  #     /etc/omni/{docker-compose.yaml,*.env}, then
  #     `systemctl restart omni-stack.service`.
  #   - Major (OS / packages / cloud-init structure): `tofu taint
  #     module.omni_host.contabo_instance.this` then `tofu apply` to
  #     destroy+recreate. Restore the latest sqlite snapshot from R2.
  #
  # Rotating Dex/Tunnel secrets requires the major path.
  lifecycle {
    ignore_changes = [user_data]
  }
}
