# tofu/layers/02-oracle-infra/terraform.tfvars
#
# cluster_endpoint is the Talos/Kubernetes API endpoint that workers embed in
# their generated machine config. Uses kubernetes-controlplane-api-1's public
# IPv4 (same IP preserved across PR #9's reinstall).
cluster_endpoint = "https://cp.antinvestor.com:6443"

# oci_accounts is NOT set here — it's built from GitHub secrets in CI and
# injected via TF_VAR_oci_accounts by .github/workflows/tofu-layer.yml. See
# that workflow for the JSON shape. For local `tofu plan`, set
# TF_VAR_oci_accounts=... in your shell.
oci_accounts = {}
