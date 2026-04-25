# tofu/layers/03-talos/firewall.tf
#
# Talos API (:50000) ingress allow-list. Sources:
#   1. https://api.github.com/meta -> .actions  (GitHub Actions runner
#      egress, so tofu-apply can drive the cluster)
#   2. var.admin_cidrs                          (operator IPs, optional)
#
# Feeds firewall-talos-api.yaml.tftpl, which overrides apid-ingress.
# Kubernetes API (:6443) is intentionally NOT restricted here — auth
# at the apiserver gates operator access (kubelogin via GitHub OIDC).

data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "tofu-apply-${var.cluster_name}"
  }
}

locals {
  _github_actions_cidrs = try(jsondecode(data.http.github_meta.response_body).actions, [])
  talos_api_ingress_cidrs = sort(distinct(concat(
    local._github_actions_cidrs,
    var.admin_cidrs,
  )))

  firewall_talos_api_patch = templatefile(
    "${path.module}/../../shared/patches/firewall-talos-api.yaml.tftpl",
    { talos_api_cidrs = local.talos_api_ingress_cidrs },
  )
}
