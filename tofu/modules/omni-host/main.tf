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

  # IMPORTANT: user_data is intentionally frozen post-creation. cloud-init
  # runs once at first boot; re-applying user_data does NOT re-run cloud-init
  # on the live VM. Tofu plan will silently swallow template-variable changes
  # (omni_version, dex_version, etc.) without visible diff.
  #
  # To push config changes to a running host:
  #   - Minor (bump container tags / rotate env / cert renewal): serial-console
  #     in, edit /etc/omni/{docker-compose.yaml,*.env,certs/*}, then
  #     `systemctl restart omni-stack.service`.
  #   - Major (OS / packages / cloud-init structure): `tofu taint
  #     module.omni_host.contabo_instance.this` then `tofu apply` to
  #     destroy+recreate. Restore /var/lib/omni from your backup before
  #     re-enabling — losing the keys directory means losing every cluster.
  lifecycle {
    ignore_changes = [user_data]
  }
}

# Contabo's create call returns immediately with the instance object but
# no IP — the IP is assigned async (typically within ~30-90s but up to a
# few minutes). The provider's resource Read does not repopulate
# ip_config when the IP is later assigned, so a same-apply downstream
# resource (the cp.<zone> A record below) sees an empty value and the
# Cloudflare API rejects it. Poll Contabo's API ourselves and stash the
# IP in state via data.external — survives across re-applies.
data "external" "vps_ip" {
  program = ["bash", "${path.module}/wait-for-contabo-ip.sh"]
  query = {
    instance_id   = contabo_instance.this.id
    client_id     = var.contabo_client_id
    client_secret = var.contabo_client_secret
    api_user      = var.contabo_api_user
    api_password  = var.contabo_api_password
  }
}
