# tofu/layers/01-contabo-infra/terraform.tfvars
# Inventory is injected from the canonical R2 object at production/config/cluster-inventory.yaml.
contabo_accounts = {}

# ssh_public_key is injected via env var TF_VAR_ssh_public_key (from GitHub secrets or operator env).


# Cluster DNS (cp.* + cp-<N>.* round-robin + prod.* for LB-labelled
# nodes) is published by layer 03-talos, which has a global view of
# every CP across every provider. Zone configuration lives in that
# layer's terraform.tfvars — not here.

# Reinstalls (cluster-wide or per-node) are now driven by request
# files under .github/reconstruction/. The tofu-reconstruct workflow
# opens a PR with a reinstall-*.yaml file; merging it fires the
# cluster-reinstall workflow which dispatches tofu-apply, and the
# request hash flows into per-node trigger keys via reconstruction.tf.

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"


# Bump to force a fleet-wide Contabo VPS reinstall on next apply,
# regardless of image_id stability. Pairs with the same knob in
# 02-oracle-infra/terraform.tfvars; bump both together when rolling
# every cluster node (e.g. after the omni-host's /var/lib/omni was
# wiped, leaving the existing nodes' kernel-cmdline jointokens
# stale).
#
# Bump history:
#   2 — 2026-05-01: post-omni-host-state-wipe recovery. Existing
#                   nodes had stale jointokens; Omni rejected joins
#                   with `has_valid_join_token: false`. Forced
#                   reinstall onto fresh images carrying the current
#                   Omni's token.
#   5 — 2026-05-01: clean-slate reinstall after `omni-cluster-delete`
#                   + bulk `omni-machine-delete` cleared the stawi
#                   cluster and all zombie Machine UUIDs. Pairs with
#                   the wait-for-registration fix in layer 03's
#                   sync-machine-labels.sh so post-reinstall labelling
#                   doesn't race the SideroLink phone-home.
#   6 — 2026-05-01: fleet-wide reinstall paired with the omni-host
#                   IPv6-forwarding fix landing on layer 00. Clean
#                   start for cluster nodes once cross-CP etcd peering
#                   actually works, so SideroLink Links are minted
#                   against an Omni that can forward.
#   8 — 2026-05-02: paired with the omni-host migration off Contabo
#                   onto OCI bwire (PR #156). New omni-host mints a
#                   fresh SideroLink token at first boot; bumping
#                   here rolls every Contabo VPS — including the
#                   freed bwire-3 (was 202727781 / Contabo omni-host)
#                   newly re-adopted by this layer — onto images
#                   carrying that new token.
force_reinstall_generation = 9
