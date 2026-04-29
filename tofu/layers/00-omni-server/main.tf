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
# same OAuth2 creds we just gave the contabo provider.
module "ubuntu_24_04_image" {
  source = "../../modules/contabo-image-lookup"

  name_pattern   = "^ubuntu-24\\.04$"
  standard_image = true
  client_id      = module.contabo_account_state.auth.auth.oauth2_client_id
  client_secret  = module.contabo_account_state.auth.auth.oauth2_client_secret
  api_user       = module.contabo_account_state.auth.auth.oauth2_user
  api_password   = module.contabo_account_state.auth.auth.oauth2_pass
}

# AWS provider points at Cloudflare R2 — required because node-state
# declares aws as required_providers (for inventory writes that this
# layer doesn't currently perform). Tofu init still needs it configured.
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

# Adopt the existing Contabo VPS instance — never create a fresh one.
# 202727781 was originally provisioned as contabo-bwire-node-3 (Talos
# CP). Repurposing it as the omni-host: the disk is reinstalled in
# place by null_resource.ensure_image once layer 01-contabo-infra
# stops managing it. Same VPS, never destroyed, only reimaged.
import {
  to = module.omni_host.contabo_instance.this
  id = "202727781"
}

module "omni_host" {
  source = "../../modules/omni-host"

  # Naming convention: <provider>-<account>-<role>. Cluster nodes are
  # contabo-bwire-node-N; the omni-host is the same shape with role
  # "omni" instead of "node-N". Lets future-us add other-account or
  # other-provider Omni instances without bespoke naming.
  name                                 = "contabo-bwire-omni"
  contabo_image_id                     = module.ubuntu_24_04_image.image_id
  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  tls_cert_pem                         = var.omni_tls_cert
  tls_key_pem                          = var.omni_tls_key
  initial_users                        = var.omni_initial_users
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email
}

# DNS records pull the IPs straight from the imported contabo_instance —
# tofu knows them because the instance exists. AAAA included so
# clients with v6 connectivity hit the VPS directly.

# Browser-facing UI: orange-cloud (Cloudflare proxies HTTPS, accepts the
# origin cert at the edge).
resource "cloudflare_dns_record" "cp_stawi_a" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cp"
  type    = "A"
  content = module.omni_host.ipv4
  proxied = true
  ttl     = 1
  comment = "Omni UI — orange-cloud."
}

resource "cloudflare_dns_record" "cp_stawi_aaaa" {
  count   = module.omni_host.ipv6 == null ? 0 : 1
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cp"
  type    = "AAAA"
  content = module.omni_host.ipv6
  proxied = true
  ttl     = 1
  comment = "Omni UI — orange-cloud (v6)."
}

# Talos-facing endpoints: gray-cloud direct. Cloudflare's free plan only
# proxies a fixed set of HTTP(S) ports (no :8090, no :8100, no UDP),
# so SideroLink API + k8s-proxy + WireGuard cannot ride orange-cloud.
# Talos validates the origin cert directly.
resource "cloudflare_dns_record" "cpd_stawi_a" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cpd"
  type    = "A"
  content = module.omni_host.ipv4
  proxied = false
  ttl     = 300
  comment = "Omni Talos-facing (8090/8100/50180) — gray-cloud."
}

resource "cloudflare_dns_record" "cpd_stawi_aaaa" {
  count   = module.omni_host.ipv6 == null ? 0 : 1
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cpd"
  type    = "AAAA"
  content = module.omni_host.ipv6
  proxied = false
  ttl     = 300
  comment = "Omni Talos-facing — gray-cloud (v6)."
}
