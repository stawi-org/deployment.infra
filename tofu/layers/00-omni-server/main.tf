provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Contabo auth from inventory (same source as 01-contabo-infra). Prefer
# this over TF_VAR CONTABO_* secrets, which drift and caused HTTP 401
# invalid_grant on omni-host plans while contabo-infra stayed healthy.
module "contabo_omni_account_state" {
  count               = var.omni_host_provider == "contabo" ? 1 : 0
  source              = "../../modules/node-state"
  provider_name       = "contabo"
  account             = "bwire"
  local_inventory_dir = var.local_inventory_dir
}

locals {
  contabo_oauth = var.omni_host_provider == "contabo" ? {
    client_id     = try(module.contabo_omni_account_state[0].auth.auth.oauth2_client_id, var.contabo_client_id)
    client_secret = try(module.contabo_omni_account_state[0].auth.auth.oauth2_client_secret, var.contabo_client_secret)
    api_user      = try(module.contabo_omni_account_state[0].auth.auth.oauth2_user, var.contabo_api_user)
    api_password  = try(module.contabo_omni_account_state[0].auth.auth.oauth2_pass, var.contabo_api_password)
    } : {
    client_id     = var.contabo_client_id
    client_secret = var.contabo_client_secret
    api_user      = var.contabo_api_user
    api_password  = var.contabo_api_password
  }
}

provider "contabo" {
  oauth2_client_id     = local.contabo_oauth.client_id
  oauth2_client_secret = local.contabo_oauth.client_secret
  oauth2_user          = local.contabo_oauth.api_user
  oauth2_pass          = local.contabo_oauth.api_password
}

# Latest Ubuntu 24.04 LTS image_id for Contabo's standard VPS pool.
module "ubuntu_24_04_image_contabo" {
  count  = var.omni_host_provider == "contabo" ? 1 : 0
  source = "../../modules/contabo-image-lookup"

  name_pattern  = "^ubuntu-24\\.04$"
  client_id     = local.contabo_oauth.client_id
  client_secret = local.contabo_oauth.client_secret
  api_user      = local.contabo_oauth.api_user
  api_password  = local.contabo_oauth.api_password
}

# Read bwire OCI auth from R2-backed inventory — same pattern
# 02-oracle-infra uses. node-state reads s3://cluster-tofu-state/
# production/inventory/oracle/bwire/auth.yaml (pre-staged by the
# operator before merge per the implementation plan's PRE-3 step).
module "bwire_account_state" {
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = "bwire"
  local_inventory_dir = "/tmp/inventory"
}

provider "oci" {
  alias               = "bwire"
  tenancy_ocid        = module.bwire_account_state.auth.auth.tenancy_ocid
  region              = module.bwire_account_state.auth.auth.region
  config_file_profile = "bwire"
  auth                = "SecurityToken"
}

# Latest Ubuntu 24.04 LTS aarch64 image in the bwire region.
data "oci_core_images" "ubuntu_aarch64" {
  provider                 = oci.bwire
  compartment_id           = module.bwire_account_state.auth.auth.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
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

# Cluster VCN + public subnet, looked up by the conventional names
# 02-oracle-infra creates them with. Sharing this subnet (same one the
# cluster CP uses) is the workaround for the 2026-05-03 BGP-propagation
# incident — fresh prefixes from a dedicated omni-host VCN stayed
# under 10% global reachability for hours, while the cluster VCN's
# announcement path was solid throughout. Side benefit: one VCN per
# tenancy keeps the always-free network resource count lower.
data "oci_core_vcns" "bwire_cluster" {
  provider       = oci.bwire
  compartment_id = module.bwire_account_state.auth.auth.compartment_ocid
  display_name   = "cluster-vcn-bwire"
}

data "oci_core_subnets" "bwire_cluster_public" {
  provider       = oci.bwire
  compartment_id = module.bwire_account_state.auth.auth.compartment_ocid
  vcn_id         = data.oci_core_vcns.bwire_cluster.virtual_networks[0].id
  display_name   = "cluster-subnet-public-bwire"
}

module "omni_host_oci" {
  count     = var.omni_host_provider == "oci" ? 1 : 0
  source    = "../../modules/omni-host-oci"
  providers = { oci = oci.bwire }

  name                      = "oci-bwire-omni"
  omni_account_id           = random_uuid.omni_account_id.result
  dex_omni_client_secret    = random_password.dex_omni_client_secret.result
  compartment_ocid          = module.bwire_account_state.auth.auth.compartment_ocid
  availability_domain_index = var.bwire_availability_domain_index
  ubuntu_image_ocid         = data.oci_core_images.ubuntu_aarch64.images[0].id
  enable_ipv6               = try(module.bwire_account_state.auth.auth.enable_ipv6, true)
  vcn_id                    = data.oci_core_vcns.bwire_cluster.virtual_networks[0].id
  subnet_id                 = data.oci_core_subnets.bwire_cluster_public.subnets[0].id

  # Share Always Free A1 with bwire Talos CP (1/6 each). Worker removed.
  ocpus               = 1
  memory_gb           = 6
  boot_volume_size_gb = 50

  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  nginx_version                        = var.nginx_version
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  cf_dns_api_token                     = var.cloudflare_api_token
  initial_users                        = [for e in split(",", var.omni_initial_users) : trimspace(e) if trimspace(e) != ""]
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email

  r2_account_id        = var.r2_account_id
  r2_access_key_id     = var.r2_access_key_id
  r2_secret_access_key = var.r2_secret_access_key

  # Greenfield 2026-07-18 OCI cutover (worker capacity → Omni). Empty
  # prefix ⇒ omni-restore finds nothing ⇒ fresh master keys. All Talos
  # nodes re-register after force_reinstall_generation bumps.
  r2_backup_prefix = "production/omni-backups-2026-07-18-oci"

  etcd_backup_enabled = var.etcd_backup_enabled

  vpn_users = var.vpn_users

  # SSH temporarily enabled for cutover diagnostics; clear after stable.
  ssh_authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID5xol7Isv6niRCRydIo4LRrKxWD3p8WBMXe/IGYK0JD bwire517@gmail.com"]
}

# Adopt the existing Contabo VPS rather than creating a new one.
# omni_host_contabo_vps_id defaults to "202727781". The for_each gate
# matches the count gate on module.omni_host_contabo — when
# omni_host_provider="oci", the target module instance doesn't exist
# and the import would error with "Configuration for import target
# does not exist". The import is a no-op once the resource is in state.
import {
  for_each = var.omni_host_provider == "contabo" ? toset([var.omni_host_contabo_vps_id]) : toset([])
  to       = module.omni_host_contabo[0].contabo_instance.this
  id       = each.value
}

module "omni_host_contabo" {
  count  = var.omni_host_provider == "contabo" ? 1 : 0
  source = "../../modules/omni-host-contabo"

  vps_id                     = var.omni_host_contabo_vps_id
  name                       = "contabo-bwire-node-3"
  region                     = var.omni_host_contabo_region
  image_id                   = try(module.ubuntu_24_04_image_contabo[0].image_id, "")
  force_reinstall_generation = var.force_reinstall_generation
  contabo_client_id          = local.contabo_oauth.client_id
  contabo_client_secret      = local.contabo_oauth.client_secret
  contabo_api_user           = local.contabo_oauth.api_user
  contabo_api_password       = local.contabo_oauth.api_password

  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  nginx_version                        = var.nginx_version
  omni_account_id                      = random_uuid.omni_account_id.result
  dex_omni_client_secret               = random_password.dex_omni_client_secret.result
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  cf_dns_api_token                     = var.cloudflare_api_token
  initial_users                        = [for e in split(",", var.omni_initial_users) : trimspace(e) if trimspace(e) != ""]
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email
  etcd_backup_enabled                  = var.etcd_backup_enabled
  vpn_users                            = var.vpn_users
  ssh_authorized_keys                  = [] # public SSH off post-bootstrap; admin via WG

  r2_account_id        = var.r2_account_id
  r2_access_key_id     = var.r2_access_key_id
  r2_secret_access_key = var.r2_secret_access_key

  # Fresh restore namespace for the 2026-05-24 revert-to-Contabo
  # (OCI inbound-edge break — see terraform.tfvars). Restore finds
  # nothing at this prefix → omni-keys generates fresh master keys
  # → Omni starts clean. Greenfield: every cluster gets re-registered,
  # no production state lost.
  r2_backup_prefix = "production/omni-backups-2026-05-24-contabo"
}

# GCP Always Free–oriented Omni host (STANDARD e2-micro, never Spot).
# Auth: tofu/shared/accounts/gcp/<omni_host_gcp_account>/auth.yaml (SOPS).
# Provider ADC is established by tofu-layer WIF for this account.
module "gcp_omni_account_state" {
  count               = var.omni_host_provider == "gcp" ? 1 : 0
  source              = "../../modules/node-state"
  provider_name       = "gcp"
  account             = var.omni_host_gcp_account
  local_inventory_dir = var.local_inventory_dir
}

provider "google" {
  # Always declared (providers cannot be count-gated). Modules use count so no
  # GCE resources are managed when omni_host_provider!=gcp, but OpenTofu still
  # configures this provider — CI/local must supply ADC/WIF for the account in
  # omni_host_gcp_account even while production substrate remains Contabo.
  # Project comes from auth when present, else placeholder (unused for APIs).
  project = try(module.gcp_omni_account_state[0].auth.auth.project_id, "unused-when-not-gcp")
  region  = var.omni_host_gcp_region
}

module "omni_host_gcp" {
  count  = var.omni_host_provider == "gcp" ? 1 : 0
  source = "../../modules/omni-host-gcp"

  project_id   = module.gcp_omni_account_state[0].auth.auth.project_id
  name         = "gcp-${var.omni_host_gcp_account}-omni"
  region       = var.omni_host_gcp_region
  zone         = var.omni_host_gcp_zone
  machine_type = var.omni_host_gcp_machine_type

  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  nginx_version                        = var.nginx_version
  omni_account_id                      = random_uuid.omni_account_id.result
  dex_omni_client_secret               = random_password.dex_omni_client_secret.result
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  cf_dns_api_token                     = var.cloudflare_api_token
  initial_users                        = [for e in split(",", var.omni_initial_users) : trimspace(e) if trimspace(e) != ""]
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email
  etcd_backup_enabled                  = var.etcd_backup_enabled
  vpn_users                            = var.vpn_users
  ssh_authorized_keys                  = []

  r2_account_id        = var.r2_account_id
  r2_access_key_id     = var.r2_access_key_id
  r2_secret_access_key = var.r2_secret_access_key
  # Reuse Contabo backup prefix so first boot can restore Omni etcd
  # and keep machine registrations (cutover continuity).
  r2_backup_prefix = "production/omni-backups-2026-05-24-contabo"
}

# DNS records pull the IPs straight from the active omni-host — tofu knows
# them because the instance exists. AAAA included when the substrate has v6.
#
# data sources lookup pre-existing CF records by name so the
# import {} blocks below can adopt them — earlier failed/cancelled
# applies left orphan records in CF without matching tofu state, and
# `cloudflare_dns_record` create then fails with "identical record
# already exists". Querying-then-importing is the no-manual-steps fix.
data "cloudflare_dns_records" "cp" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = { exact = "cp.stawi.org" }
}

data "cloudflare_dns_records" "cpd" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = { exact = "cpd.stawi.org" }
}

locals {
  # Match the PROXIED record specifically — historically this layer
  # raced with 03-talos's cluster_dns module which planted DNS-only
  # `cp.<zone>` A/AAAA records pointing at every Talos CP node. If
  # this import grabbed one of those by being non-deterministic on
  # `[0]`, the omni-host's DNS state would be hijacked. The per-CP
  # records there are now scoped to `cp-<N>` and the round-robin is
  # gone (see tofu/layers/03-talos/dns.tf), but pinning to proxied=true
  # also defends against any future stray DNS-only `cp` record.
  cp_a_id     = try([for r in data.cloudflare_dns_records.cp.result : r.id if r.type == "A" && r.proxied][0], null)
  cp_aaaa_id  = try([for r in data.cloudflare_dns_records.cp.result : r.id if r.type == "AAAA" && r.proxied][0], null)
  cpd_a_id    = try([for r in data.cloudflare_dns_records.cpd.result : r.id if r.type == "A"][0], null)
  cpd_aaaa_id = try([for r in data.cloudflare_dns_records.cpd.result : r.id if r.type == "AAAA"][0], null)
}

locals {
  # Active omni-host outputs, substrate-agnostic. Exactly one module has count=1.
  omni_host_ipv4 = coalescelist(
    module.omni_host_contabo[*].ipv4,
    module.omni_host_oci[*].ipv4,
    module.omni_host_gcp[*].ipv4,
  )[0]
  # GCP v1 has no public IPv6 — filter nulls so coalescelist does not fail.
  omni_host_ipv6 = try(coalescelist([
    for ip in concat(
      module.omni_host_contabo[*].ipv6,
      module.omni_host_oci[*].ipv6,
      module.omni_host_gcp[*].ipv6,
    ) : ip if ip != null
  ])[0], null)
  # Plan-time known: whether AAAA records should exist.
  omni_host_has_ipv6 = var.omni_host_provider != "gcp" && try(module.bwire_account_state.auth.auth.enable_ipv6, true)
}

import {
  for_each = local.cp_a_id == null ? toset([]) : toset([local.cp_a_id])
  to       = cloudflare_dns_record.cp_stawi
  id       = "${var.cloudflare_zone_id_stawi}/${each.value}"
}

import {
  for_each = local.cpd_a_id == null ? toset([]) : toset([local.cpd_a_id])
  to       = cloudflare_dns_record.cpd_stawi
  id       = "${var.cloudflare_zone_id_stawi}/${each.value}"
}

# AAAA imports only when the active substrate has public IPv6. GCP Omni
# has IPv4-only today (count=0 on *_v6); importing into a missing index
# fails plan with "Configuration for import target does not exist".
import {
  for_each = local.omni_host_has_ipv6 && local.cp_aaaa_id != null ? toset([local.cp_aaaa_id]) : toset([])
  to       = cloudflare_dns_record.cp_stawi_v6[0]
  id       = "${var.cloudflare_zone_id_stawi}/${each.value}"
}

import {
  for_each = local.omni_host_has_ipv6 && local.cpd_aaaa_id != null ? toset([local.cpd_aaaa_id]) : toset([])
  to       = cloudflare_dns_record.cpd_stawi_v6[0]
  id       = "${var.cloudflare_zone_id_stawi}/${each.value}"
}

# Browser-facing UI: orange-cloud (Cloudflare proxies HTTPS, accepts the
# origin cert at the edge).
resource "cloudflare_dns_record" "cp_stawi" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cp"
  type    = "A"
  content = local.omni_host_ipv4
  proxied = true
  ttl     = 1
  comment = "Omni UI — orange-cloud."
}

resource "cloudflare_dns_record" "cp_stawi_v6" {
  # Predicate must be plan-time-known (not known-after-apply).
  count   = local.omni_host_has_ipv6 ? 1 : 0
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cp"
  type    = "AAAA"
  content = local.omni_host_ipv6
  proxied = true
  ttl     = 1
  comment = "Omni UI — orange-cloud (v6)."
}

# Talos-facing endpoints: gray-cloud direct. Cloudflare's free plan only
# proxies a fixed set of HTTP(S) ports (no :8090, no :8100, no UDP),
# so SideroLink API + k8s-proxy + WireGuard cannot ride orange-cloud.
# Talos validates the origin cert directly.
resource "cloudflare_dns_record" "cpd_stawi" {
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cpd"
  type    = "A"
  content = local.omni_host_ipv4
  proxied = false
  ttl     = 300
  comment = "Omni Talos-facing (8090/8100/50180) — gray-cloud."
}

resource "cloudflare_dns_record" "cpd_stawi_v6" {
  count   = local.omni_host_has_ipv6 ? 1 : 0
  zone_id = var.cloudflare_zone_id_stawi
  name    = "cpd"
  type    = "AAAA"
  content = local.omni_host_ipv6
  proxied = false
  ttl     = 300
  comment = "Omni Talos-facing — gray-cloud (v6)."
}

# OPERATOR-MANAGED: Cloudflare zone gRPC setting must be ON for
# omnictl (gRPC over HTTP/2 via CF) to work without CF's browser-
# integrity-check returning 403/text-html. Set once in the CF
# dashboard: stawi.org zone → Network → gRPC → On. Not tofu-
# managed because the current cloudflare_api_token scope is
# DNS:edit only, and adding zone:settings:edit broadens the token
# beyond what's needed for the rest of the layer.
