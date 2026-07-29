# Substrate hosting omni-host:
#   oci — A1.Flex in bwire (historically blocked by inbound blackholes)
#   gcp — STANDARD e2-micro on stawi-timber (Always Free US region + swap)
#
# Contabo substrate was removed (VPS fleet cut off). Production Omni is on GCP.
#
# Always Free e2-micro: free only in us-west1/us-central1/us-east1; 1 GiB
# RAM is tight (cloud-init adds 2 GiB swap). Raise machine type if OOM.
omni_host_provider         = "gcp"
omni_host_gcp_account      = "stawi-timber"
omni_host_gcp_region       = "us-central1"
omni_host_gcp_zone         = "us-central1-a"
omni_host_gcp_machine_type = "e2-micro"

# Keep in lock-step with tofu/shared/versions.auto.tfvars.json +
# workflow OMNI_VERSION (omnictl). This layer does not symlink the
# full versions auto-file (would inject undeclared talos/k8s keys).
omni_version = "v1.9.3"

# bwire_availability_domain_index defaults to 0 (first AD). The
# module auto-discovers ADs via oci_identity_availability_domains
# data source — same pattern oracle-account-infra uses for cluster
# nodes. Bump this only if AD-1 is out of A1.Flex capacity.

# Native etcd backup → OCI omni-backup-storage in bwire. The CSK
# used by Omni's --etcd-backup-s3 flag is now tofu-managed via
# 02-oracle-infra/oci-operator-csk.tf and reaches this layer via
# sync-cluster-template's tfstate read of `omni_backup_writer_credentials`.
# No manual operator CSK mint needed — the bwire tofu-apply creates it.
etcd_backup_enabled = true
