# tofu/layers/03-talos/versions.tf
#
# Layer-03 used to be the Talos bootstrap layer (talosctl apply-config
# / bootstrap, machine-config generation, Talos firewall config). All
# of that moved to Omni in 2026-04 — this layer now drives Omni
# cluster-template sync and per-machine label assignment via omnictl,
# plus cross-provider DNS (cp-N + prod.<zone>). The dir name
# `03-talos` is legacy; rename pending in a follow-up. Backend state
# key stays at production/03-talos.tfstate for state continuity.
terraform {
  required_version = ">= 1.10"
  required_providers {
    null = {
      source = "hashicorp/null"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Cloudflare provider retained transitionally while module.cluster_dns
# is still in this layer's tfstate. The `removed { destroy = false }`
# block in removed.tf will drop those resources from state on the next
# apply; until then, refresh needs an authenticated CF provider to
# read the live records. Task 8 of the dns-layer-split plan deletes
# this block + the cloudflare_api_token variable + the cloudflare
# entry in required_providers after the first apply.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# AWS provider points at Cloudflare R2 — required because the
# terraform_remote_state readers in main.tf use the s3 backend against
# R2's S3-compatible endpoint.
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
