# tofu/layers/03-talos/firewall.tf
#
# Build the CIDR allow-list for Talos API (:50000) and Kubernetes API
# (:6443) from two sources:
#
#   1. https://api.github.com/meta → .actions — GitHub Actions runner
#      egress ranges. Required so tofu-apply can continue to drive the
#      cluster. Fetched at plan time; the list refreshes whenever
#      GitHub publishes a new range (usually ~once a month), which
#      triggers a Talos machine-config diff + CP rolling reboot to
#      re-apply. Acceptable since the cluster stays cleanly in sync
#      without a human curating an IP list.
#
#   2. var.admin_cidrs — operator-supplied fixed CIDRs for direct
#      kubectl / talosctl from a known IP. Optional (default empty).
#
# The result feeds firewall-admin.yaml.tftpl, which overrides
# network.yaml's apid-ingress and kubernetes-api-ingress rules.

data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "tofu-apply-${var.cluster_name}"
  }
}

locals {
  # Parse once; try() keeps plan going if the endpoint ever returns
  # something malformed so the operator can fall back to admin_cidrs.
  _github_actions_cidrs = try(
    jsondecode(data.http.github_meta.response_body).actions,
    [],
  )
  github_actions_cidrs_v4 = [for c in local._github_actions_cidrs : c if !strcontains(c, ":")]
  github_actions_cidrs_v6 = [for c in local._github_actions_cidrs : c if strcontains(c, ":")]

  admin_cidrs_v4 = [for c in var.admin_cidrs : c if !strcontains(c, ":")]
  admin_cidrs_v6 = [for c in var.admin_cidrs : c if strcontains(c, ":")]

  # Union, deduped. Talos NetworkRuleConfig accepts mixed v4 + v6 in a
  # single ingress list — order within the list doesn't matter for
  # matching, but sort() keeps the rendered machine config stable
  # across plans so cosmetic reorderings don't trigger reboots.
  admin_ingress_cidrs = sort(distinct(concat(
    local.github_actions_cidrs_v4,
    local.github_actions_cidrs_v6,
    local.admin_cidrs_v4,
    local.admin_cidrs_v6,
  )))
}
