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
# (no provider API call). After this commit's 03-talos apply
# completes, the cluster_dns module is no longer in 03-talos's
# tfstate, and this file can be deleted in a follow-up commit.
removed {
  from = module.cluster_dns
  lifecycle {
    destroy = false
  }
}
