# tofu/layers/02-oci-storage/outputs.tf

output "cluster_image_registry" {
  description = "Public OCI Object Storage bucket holding the schematic-keyed Talos image staging area (bwire only). Read by regenerate-talos-images.yml + node-oracle for OCI image-import URLs."
  value = {
    namespace = data.oci_objectstorage_namespace.this.namespace
    bucket    = oci_objectstorage_bucket.cluster_image_registry.name
    region    = local.bwire_region
    public_url_prefix = format(
      "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o",
      local.bwire_region,
      data.oci_objectstorage_namespace.this.namespace,
      oci_objectstorage_bucket.cluster_image_registry.name,
    )
  }
}

output "cluster_state_storage" {
  description = "Private OCI Object Storage bucket reserved for tofu state files (Track B migration target). Use the S3-compat endpoint with a Customer Secret Key."
  value = {
    namespace = data.oci_objectstorage_namespace.this.namespace
    bucket    = oci_objectstorage_bucket.cluster_state_storage.name
    region    = local.bwire_region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.this.namespace,
      local.bwire_region,
    )
  }
}

output "cluster_vault_storage" {
  description = "Private OCI Object Storage bucket holding SOPS-encrypted secrets (bwire only). Use the S3-compat endpoint."
  value = {
    namespace = data.oci_objectstorage_namespace.this.namespace
    bucket    = oci_objectstorage_bucket.cluster_vault_storage.name
    region    = local.bwire_region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.this.namespace,
      local.bwire_region,
    )
  }
}

output "omni_backup_storage" {
  description = "Private OCI Object Storage bucket for Omni's builtin etcd backup feature. Wire to omni-server via --etcd-backup-s3 + S3 env vars in the omni docker-compose."
  value = {
    namespace = data.oci_objectstorage_namespace.this.namespace
    bucket    = oci_objectstorage_bucket.omni_backup_storage.name
    region    = local.bwire_region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.this.namespace,
      local.bwire_region,
    )
  }
}

# Credentials shared by all bwire S3-compat consumers (omni-host
# etcd-backup, regenerate-talos-images uploads, sync-cluster-template's
# EtcdBackupS3Configs render). Single CSK on the operator user; field
# shape preserved verbatim from the prior 02-oracle-infra output so
# consumers don't churn.
output "omni_backup_writer_credentials" {
  description = "S3-compat credentials (single CSK) for OCI bwire object storage. Used by omni-host etcd-backup, regenerate-talos-images uploads, and sync-cluster-template's EtcdBackupS3Configs render."
  sensitive   = true
  value = {
    access_key_id     = oci_identity_customer_secret_key.bwire_operator.id
    secret_access_key = oci_identity_customer_secret_key.bwire_operator.key
    bucket            = oci_objectstorage_bucket.omni_backup_storage.name
    region            = local.bwire_region
    endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.this.namespace,
      local.bwire_region,
    )
  }
}

# Three OpenObserve standalones write to three buckets — one per
# signal type (logs / traces / metrics). All three share the
# alimbacho_operator CSK; only the bucket name differs.
#
# The buckets live in alimbacho67 (NOT bwire) so observability
# storage cost stays isolated from the bwire operator account
# that already holds image registry / state / vault / omni-
# backup.
#
# Per-signal lifecycle:
#   logs    : DELETE after 7 days
#   traces  : DELETE after 7 days
#   metrics : DELETE after 30 days
# OpenObserve's matching ZO_DATA_RETENTION_DAYS in each
# HelmRelease trims at the same cadence; the OCI lifecycle
# policy is the floor.
#
# After apply the workflow extracts each entry and runs
#   bao kv put -mount=secret \
#     antinvestor/telemetry/openobserve/oci-credentials-${signal} \
#     access_key=$ACCESS secret_key=$SECRET \
#     bucket=$BUCKET endpoint=$ENDPOINT region=$REGION
# so the per-signal openobserve-oci-${signal}-credentials
# ExternalSecrets can mint the kube Secrets OpenObserve consumes.
output "telemetry_storage_credentials" {
  description = "S3-compat credentials for OpenObserve's three telemetry buckets — keyed by signal (logs/traces/metrics). Each value points at its own tenancy + CSK. Pushed to OpenBao at antinvestor/telemetry/openobserve/oci-credentials-{signal} by the post-apply workflow step."
  sensitive   = true
  value = {
    logs = {
      access_key_id     = oci_identity_customer_secret_key.bwire_operator.id
      secret_access_key = oci_identity_customer_secret_key.bwire_operator.key
      bucket            = oci_objectstorage_bucket.telemetry_logs_storage.name
      region            = local.bwire_region
      endpoint = format(
        "https://%s.compat.objectstorage.%s.oraclecloud.com",
        data.oci_objectstorage_namespace.this.namespace,
        local.bwire_region,
      )
    }
    traces = {
      access_key_id     = oci_identity_customer_secret_key.brianelvis_operator.id
      secret_access_key = oci_identity_customer_secret_key.brianelvis_operator.key
      bucket            = oci_objectstorage_bucket.telemetry_traces_storage.name
      region            = local.brianelvis_region
      endpoint = format(
        "https://%s.compat.objectstorage.%s.oraclecloud.com",
        data.oci_objectstorage_namespace.brianelvis.namespace,
        local.brianelvis_region,
      )
    }
    metrics = {
      access_key_id     = oci_identity_customer_secret_key.alimbacho_operator.id
      secret_access_key = oci_identity_customer_secret_key.alimbacho_operator.key
      bucket            = oci_objectstorage_bucket.telemetry_metrics_storage.name
      region            = local.alimbacho_region
      endpoint = format(
        "https://%s.compat.objectstorage.%s.oraclecloud.com",
        data.oci_objectstorage_namespace.alimbacho.namespace,
        local.alimbacho_region,
      )
    }
  }
}
