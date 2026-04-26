# tofu/layers/02-oracle-infra/imports.tf
#
# Adopt existing OCI instances on first apply in a fresh tofu state.
# Source: nodes.yaml's .nodes[<key>].provider_data.oci_instance_ocid —
# written back by the nodes-writer after every successful apply. On a
# fresh tofu state without a prior apply, the map is empty and tofu
# simply creates the instances.
#
# IMPORTANT: nodes.yaml can have stale OCIDs (e.g. operator wiped an
# instance via the OCI console after a failed reset). Importing a
# non-existent OCID errors hard ("Cannot import non-existent remote
# object"). Defend by listing the live instances in each account's
# compartment via data.oci_core_instances and only attempting to
# import OCIDs that still exist in OCI right now.
#
# Once a resource is in tofu state, the import block is a no-op.

# Live inventory of running/stopped instances per account, looked up
# through the per-account OCI provider alias so each query lands in
# the right tenancy + region.
data "oci_core_instances" "live" {
  for_each       = toset(local.oracle_account_keys)
  provider       = oci.account[each.key]
  compartment_id = try(local.oracle_auth_from_module[each.key].compartment_ocid, "")
  state          = "RUNNING"
}

locals {
  # OCIDs that currently exist in OCI, keyed by account.
  oracle_live_ocids_per_account = {
    for acct, data_inst in data.oci_core_instances.live :
    acct => toset([for i in data_inst.instances : i.id])
  }

  # Flatten per-account nodes into a single map keyed by
  # "<acct>:<node>" (colon separator avoids ambiguity with hyphens).
  # Filter to keep only OCIDs that ARE still in OCI — otherwise the
  # import block would error on a stale OCID from nodes.yaml.
  oracle_existing_instance_ocids = merge([
    for acct_key, node_map in local.oracle_nodes_from_module : {
      for node_key, node in node_map :
      "${acct_key}:${node_key}" => try(node.provider_data.oci_instance_ocid, null)
      if try(node.provider_data.oci_instance_ocid, null) != null
      && contains(try(local.oracle_live_ocids_per_account[acct_key], []), try(node.provider_data.oci_instance_ocid, ""))
    }
  ]...)
}

import {
  for_each = local.oracle_existing_instance_ocids
  to       = module.oracle_account[split(":", each.key)[0]].module.node[split(":", each.key)[1]].oci_core_instance.this
  id       = each.value
}

# Account-level OCI resources that survive cluster-reset's R2-state
# wipe (state goes; cloud objects don't): bastion + image bucket. Same
# defensive pattern as instances — list by name in the account's
# compartment/namespace and import only what's actually present.

data "oci_bastion_bastions" "by_name" {
  for_each                = toset(local.oracle_account_keys)
  provider                = oci.account[each.key]
  compartment_id          = try(local.oracle_auth_from_module[each.key].compartment_ocid, "")
  name                    = "cluster-bastion-${each.key}"
  bastion_lifecycle_state = "ACTIVE"
}

import {
  for_each = {
    for k in local.oracle_account_keys : k => one(data.oci_bastion_bastions.by_name[k].bastions)
    if length(data.oci_bastion_bastions.by_name[k].bastions) > 0
  }
  to = module.oracle_account[each.key].oci_bastion_bastion.this
  id = each.value.id
}

# Object Storage bucket. data.oci_objectstorage_namespace is queried
# inside the module already; here we need it again for the import-side
# bucket lookup.
data "oci_objectstorage_namespace" "by_account" {
  for_each       = toset(local.oracle_account_keys)
  provider       = oci.account[each.key]
  compartment_id = try(local.oracle_auth_from_module[each.key].compartment_ocid, "")
}

# data.oci_objectstorage_bucket errors if the bucket doesn't exist, so
# use the list endpoint and pick by name.
data "oci_objectstorage_bucket_summaries" "talos_images" {
  for_each       = toset(local.oracle_account_keys)
  provider       = oci.account[each.key]
  compartment_id = try(local.oracle_auth_from_module[each.key].compartment_ocid, "")
  namespace      = data.oci_objectstorage_namespace.by_account[each.key].namespace
}

locals {
  # Per-account: existing talos-images-<acct> bucket if present, else null.
  oracle_image_bucket_present = {
    for acct in local.oracle_account_keys : acct => length([
      for b in data.oci_objectstorage_bucket_summaries.talos_images[acct].bucket_summaries :
      b if b.name == "talos-images-${acct}"
    ]) > 0
  }
}

import {
  for_each = {
    for k in local.oracle_account_keys : k => k
    if try(local.oracle_image_bucket_present[k], false)
  }
  # Bucket import id format: n/<namespace>/b/<bucket-name>
  to = module.oracle_account[each.key].oci_objectstorage_bucket.talos_images[0]
  id = "n/${data.oci_objectstorage_namespace.by_account[each.key].namespace}/b/talos-images-${each.key}"
}
