# tofu/layers/04-flux/main.tf
data "terraform_remote_state" "talos" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/03-talos.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

data "terraform_remote_state" "secrets" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-talos-secrets.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# Layer 03's kubeconfig output is the structured kubernetes_client_configuration.
# Fields are base64-encoded in kubeconfig-land; the k8s/helm/kubectl providers
# want raw PEM.
locals {
  kc_raw = data.terraform_remote_state.talos.outputs.kubeconfig
  kc = {
    host               = local.kc_raw.host
    ca_certificate     = try(base64decode(local.kc_raw.ca_certificate), local.kc_raw.ca_certificate)
    client_certificate = try(base64decode(local.kc_raw.client_certificate), local.kc_raw.client_certificate)
    client_key         = try(base64decode(local.kc_raw.client_key), local.kc_raw.client_key)
  }
}

provider "kubernetes" {
  host                   = local.kc.host
  client_certificate     = local.kc.client_certificate
  client_key             = local.kc.client_key
  cluster_ca_certificate = local.kc.ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = local.kc.host
    client_certificate     = local.kc.client_certificate
    client_key             = local.kc.client_key
    cluster_ca_certificate = local.kc.ca_certificate
  }
}

# alekc/kubectl handles CRDs that don't exist at plan time — required because
# the FluxInstance CRD is installed by helm_release.flux_operator in the same
# apply, and hashicorp/kubernetes's kubernetes_manifest fails in that case.
provider "kubectl" {
  host                   = local.kc.host
  client_certificate     = local.kc.client_certificate
  client_key             = local.kc.client_key
  cluster_ca_certificate = local.kc.ca_certificate
  load_config_file       = false
}
