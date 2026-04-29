provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Read Contabo OAuth2 credentials from R2-backed sopsed inventory —
# same pattern layer 01 uses. The omni-host lives in the bwire account.
module "contabo_account_state" {
  source              = "../../modules/node-state"
  provider_name       = "contabo"
  account             = "bwire"
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = "/tmp/inventory"
}

provider "contabo" {
  oauth2_client_id     = module.contabo_account_state.auth.auth.oauth2_client_id
  oauth2_client_secret = module.contabo_account_state.auth.auth.oauth2_client_secret
  oauth2_user          = module.contabo_account_state.auth.auth.oauth2_user
  oauth2_pass          = module.contabo_account_state.auth.auth.oauth2_pass
}

# Resolve the Contabo Ubuntu 24.04 LTS image ID at plan time using the
# same OAuth2 creds we just gave the contabo provider. The provider's
# data "contabo_image" only looks up by exact UUID, so name-resolution
# lives in this small module (two http data sources). No operator
# action, no opaque IDs in tfvars, no secrets exposed outside CI.
module "ubuntu_24_04_image" {
  source = "../../modules/contabo-image-lookup"

  name_pattern   = "^Ubuntu 24\\.04"
  standard_image = true
  client_id      = module.contabo_account_state.auth.auth.oauth2_client_id
  client_secret  = module.contabo_account_state.auth.auth.oauth2_client_secret
  api_user       = module.contabo_account_state.auth.auth.oauth2_user
  api_password   = module.contabo_account_state.auth.auth.oauth2_pass
}

provider "aws" {
  region                      = "auto"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  endpoints {
    s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  }
}

# Cloudflare Zero Trust Tunnel that fronts cp.antinvestor.com + cp.stawi.org.
# Outbound-only from the omni-host (no inbound port on the VPS).
resource "cloudflare_zero_trust_tunnel_cloudflared" "omni" {
  account_id = var.cloudflare_account_id
  name       = "omni"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "omni" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.omni.id
  config = {
    ingress = [
      { hostname = "cp.antinvestor.com", service = "http://127.0.0.1:8090" },
      { hostname = "cp.stawi.org", service = "http://127.0.0.1:8090" },
      { service = "http_status:404" }
    ]
  }
}

locals {
  # The TUNNEL_TOKEN that cloudflared expects is a base64-encoded JSON blob:
  # {"a": "<account_tag>", "s": "<tunnel_secret_base64>", "t": "<tunnel_id>"}
  # The provider does not expose a pre-built token attribute; construct it here.
  tunnel_token = base64encode(jsonencode({
    a = cloudflare_zero_trust_tunnel_cloudflared.omni.account_tag
    s = cloudflare_zero_trust_tunnel_cloudflared.omni.tunnel_secret
    t = cloudflare_zero_trust_tunnel_cloudflared.omni.id
  }))

  # DNS CNAME target for orange-cloud records pointing at this tunnel.
  tunnel_cname = "${cloudflare_zero_trust_tunnel_cloudflared.omni.id}.cfargotunnel.com"
}

module "omni_host" {
  source = "../../modules/omni-host"

  name                           = "cluster-omni-contabo"
  contabo_image_id               = module.ubuntu_24_04_image.image_id
  omni_version                   = var.omni_version
  dex_version                    = var.dex_version
  cloudflared_version            = var.cloudflared_version
  omni_account_name              = "stawi"
  siderolink_api_advertised_host = "cp.antinvestor.com"
  extra_dns_aliases              = ["cp.stawi.org"]
  github_oidc_client_id          = var.github_oidc_client_id
  github_oidc_client_secret      = var.github_oidc_client_secret
  cloudflare_tunnel_token        = local.tunnel_token
  r2_endpoint                    = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  r2_backup_access_key_id        = var.etcd_backup_r2_access_key_id
  r2_backup_secret_access_key    = var.etcd_backup_r2_secret_access_key
}

# Orange-cloud DNS records — both zones point at the same CF Tunnel.

resource "cloudflare_dns_record" "cp_antinvestor" {
  zone_id = var.cloudflare_zone_id_antinvestor
  name    = "cp"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Cloudflare Tunnel target for self-hosted Omni."
}

resource "cloudflare_dns_record" "cp_stawi" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cp"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Cloudflare Tunnel target for self-hosted Omni."
}
