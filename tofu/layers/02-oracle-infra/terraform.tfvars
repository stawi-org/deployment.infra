# tofu/layers/02-oracle-infra/terraform.tfvars
#
# cluster_endpoint is the Talos/Kubernetes API endpoint that nodes embed in
# their generated machine config. Uses kubernetes-controlplane-api-1's public
# IPv4 (same IP preserved across PR #9's reinstall).
cluster_endpoint = "https://cp.antinvestor.com:6443"

# oci_accounts is normally injected from the canonical R2 inventory object
# at production/config/cluster-inventory.yaml via TF_VAR_oci_accounts. The
# older GitHub secret ladder still works as a bootstrap fallback; see
# .github/workflows/tofu-layer.yml for the compatibility path.
oci_accounts = {}
