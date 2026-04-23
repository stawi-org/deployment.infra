# provider "aws" is used by the node-state module's aws_s3_object reads/writes
# against Cloudflare R2 (S3-compatible). Generated — keep identical across
# layers. Sync with scripts/sync-provider-aws.sh if the template changes.
provider "aws" {
  region                      = "auto"
  access_key                  = null
  secret_key                  = null
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  }

  # R2 requires path-style addressing.
  s3_use_path_style = true
}
