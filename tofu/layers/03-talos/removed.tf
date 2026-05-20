# tofu/layers/03-talos/removed.tf
#
# TRANSITIONAL — delete after the first successful 03-talos apply.
#
# DNS was split out of this layer into 04-dns (2026-05; spec:
# docs/superpowers/specs/2026-05-20-dns-layer-split-design.md). The
# `module.cluster_dns` resources need to leave 03-talos's tfstate
# WITHOUT being destroyed in Cloudflare — 04-dns's import block
# adopts them on its first apply.
#
# `lifecycle.destroy = false` means tofu plans a state-only removal
# (no provider API call) — but refresh BEFORE the planned removal
# still needs an authenticated cloudflare provider to read each
# resource's current state. That's why the cloudflare provider +
# cloudflare_api_token variable are retained in versions.tf /
# variables.tf for now. Task 8 of the dns-layer-split plan deletes
# this file AND the provider config together, once the first apply
# has cleared module.cluster_dns from state.
removed {
  from = module.cluster_dns
  lifecycle {
    destroy = false
  }
}
