# OCI availability-domain in the bwire tenancy/region. Operator must
# set this to an AD with A1.Flex capacity. Look up via:
#   oci iam availability-domain list --profile bwire
bwire_availability_domain = "<set-by-operator>"

# Native etcd backup → OCI omni-backup-storage. Default false here
# because flipping it true changes the rendered docker-compose YAML
# (adds --etcd-backup-s3 flag), which trips user_data_sha drift in
# null_resource.ensure_image and forces a Contabo PUT reinstall.
# Operator-driven enablement order:
#   1. Mint OCI Customer Secret Key for the omni-backup-writer IAM
#      user in OCI bwire console (User > Customer Secret Keys).
#   2. Add OMNI_ETCD_BACKUP_S3_ACCESS_KEY_ID +
#      OMNI_ETCD_BACKUP_S3_SECRET_ACCESS_KEY as repo Actions secrets;
#      OMNI_ETCD_BACKUP_S3_BUCKET / REGION / ENDPOINT as repo Vars.
#   3. Trigger sync-cluster-template (push to main or
#      workflow_dispatch) so Omni gets the EtcdBackupS3Configs +
#      backupConfiguration.interval.
#   4. Flip this to true here, optionally bump
#      force_reinstall_generation, apply via tofu-omni-host.yml.
etcd_backup_enabled = true
