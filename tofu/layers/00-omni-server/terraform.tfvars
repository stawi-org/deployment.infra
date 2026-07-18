# Substrate hosting omni-host: "contabo" adopts existing VPS 202727781
# (former bwire-3); "oci" provisions an A1.Flex in OCI bwire.
#
# Always Free A1 is 2 OCPU / 12 GB *total* per tenancy (post 2026-06-15).
# When provider=oci, Omni is sized at 1 OCPU / 6 GB so bwire can keep
# one Talos control plane at 1/6 (worker removed). Default module
# ocpus=2 would consume the whole free pool.
#
# History: 2026-05-24 reverted OCI→Contabo after inbound blackhole on
# eu-frankfurt-1 public IPs. 2026-07-18 re-attempted OCI (worker→Omni
# 1/6+1/6): instance created at 129.159.221.5 but global probes got
# "No route to host" on :22/:443/:8090/:8100 — same failure mode.
# Rolled back to Contabo; OCI instance left powered for diagnosis.
omni_host_provider = "contabo"

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
