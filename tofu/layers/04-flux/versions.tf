terraform {
  required_version = ">= 1.10"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.0" }
  }
}
