# tofu/layers/04-dns/versions.tf
#
# DNS-only layer. Reads node IPs from upstream infra layer tfstates and
# writes A/AAAA records to Cloudflare. Carved out of 03-talos in
# 2026-05 (spec: docs/superpowers/specs/2026-05-20-dns-layer-split-design.md)
# so a CF API failure no longer blocks Talos machine-config apply.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

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
