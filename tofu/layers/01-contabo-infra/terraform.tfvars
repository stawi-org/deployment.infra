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
