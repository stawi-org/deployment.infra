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

  # No lifecycle.ignore_changes — the contabo provider's Update path is
  # the canonical way to push image_id / user_data drift to a running
  # VPS. Tofu plan surfaces the diff, the provider's PATCH /
  # /v1/compute/instances/<id> handles the rest. No null_resource, no
  # custom bash. If a particular provider version doesn't honour the
  # update correctly, that's a provider bug to track upstream — not
  # something to paper over with a script.
}
