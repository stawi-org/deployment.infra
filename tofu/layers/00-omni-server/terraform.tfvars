# Substrate hosting omni-host:
#   contabo — existing VPS 202727781 (Ubuntu + docker-compose)
#   oci     — A1.Flex in bwire (blocked historically by inbound blackholes)
#   gcp     — STANDARD e2-micro on stawi-timber (Always Free US region + swap)
#
# Cutover to GCP (greenfield restore from Contabo R2 prefix):
#   1. Ensure bootstrap-gcp-wif has run for stawi-timber (WIF + SA).
#   2. tofu state rm 'module.omni_host_contabo[0].contabo_instance.this'
#      (and related) so Contabo VPS is orphaned for later Talos worker use
#      — do NOT destroy the VPS via tofu if you want to keep the hardware.
#   3. Set omni_host_provider = "gcp", apply 00-omni-server.
#   4. DNS A records for cp/cpd flip to the static GCE IP on the same apply.
#   5. Stop Omni on Contabo (docker compose down) after DNS propagates.
#
# Always Free e2-micro: free only in us-west1/us-central1/us-east1; 1 GiB
# RAM is tight (cloud-init adds 2 GiB swap). Raise machine type if OOM.
# Production remains Contabo until cutover (docs/omni-host-gcp.md).
omni_host_provider = "contabo"
# GCP settings used when omni_host_provider = "gcp":
omni_host_gcp_account      = "stawi-timber"
omni_host_gcp_region       = "us-central1"
omni_host_gcp_zone         = "us-central1-a"
omni_host_gcp_machine_type = "e2-micro"

# Keep in lock-step with tofu/shared/versions.auto.tfvars.json +
# workflow OMNI_VERSION (omnictl). This layer does not symlink the
# full versions auto-file (would inject undeclared talos/k8s keys).
omni_version = "v1.9.3"

# Contabo reinstall marker (only applies when provider=contabo).
# Bumped for the 2026-07-18 OCI cutover so a future Contabo rollback
# also gets a clean cloud-init path.
force_reinstall_generation = 5

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
