provider "aws" {
  region                      = "auto"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  endpoints {
    s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  }
}

# Read Omni's endpoint from the 00-omni-server layer's tfstate.
data "terraform_remote_state" "omni_server" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-omni-server.tfstate"
    region                      = "auto"
    encrypt                     = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    endpoints = {
      s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
    }
  }
}

# The KittyKatt/omni provider (community; no official siderolabs/omni provider
# exists in any registry as of 2026-04). Provider config matches siderolabs spec:
# endpoint + service_account_key. Apply fails with connection refused until
# 00-omni-server is live — that is expected; this layer applies in Phase B step 7.1.
provider "omni" {
  endpoint            = data.terraform_remote_state.omni_server.outputs.omni_url
  service_account_key = var.omni_service_account_key
}

# Cluster template data source renders the YAML that omni_cluster consumes.
# The KittyKatt/omni provider uses a YAML-document approach: HCL describes the
# desired state, templatefile-like data sources render YAML, and the omni_cluster
# resource pushes the YAML to Omni's API. This differs from the migration plan's
# sketch (which assumed direct HCL attributes), but achieves the same intent.
data "omni_cluster_template" "stawi" {
  name = "stawi-cluster"
  talos = {
    version = var.talos_version
  }
  kubernetes = {
    version = var.kubernetes_version
  }
  features = {
    enable_workload_proxy = true
  }
}

# Control-plane machine set — the three CP nodes.
# Machine UUIDs are populated via var.controlplane_machine_ids after nodes
# register with Omni (Phase B step 7.4). Empty list is valid at plan time.
resource "omni_cluster_machine_set_template" "controlplane" {
  kind     = "controlplane"
  machines = var.controlplane_machine_ids
}

# Worker machine set — all available worker nodes.
# Populated via var.worker_machine_ids after Phase B node registration.
resource "omni_cluster_machine_set_template" "workers" {
  name     = "stawi-cluster-workers"
  kind     = "worker"
  machines = var.worker_machine_ids
}

# Per-machine templates for control-plane nodes.
# The provider requires individual machine templates to bind roles to UUIDs.
resource "omni_cluster_machine_template" "controlplane" {
  for_each = toset(var.controlplane_machine_ids)
  name     = each.key
  role     = "controlplane"
}

# Per-machine templates for worker nodes.
resource "omni_cluster_machine_template" "workers" {
  for_each = toset(var.worker_machine_ids)
  name     = each.key
  role     = "worker"
}

# The cluster resource wires all the YAML together and pushes to Omni.
resource "omni_cluster" "stawi" {
  cluster_template       = data.omni_cluster_template.stawi.yaml
  control_plane_template = omni_cluster_machine_set_template.controlplane.yaml
  workers_template = [
    omni_cluster_machine_set_template.workers.yaml,
  ]
  machines_template = values(merge(
    { for m in omni_cluster_machine_template.controlplane : m.name => m.yaml },
    { for m in omni_cluster_machine_template.workers : m.name => m.yaml },
  ))
  delete_machine_links = false
}

# Kubeconfig resource — fetches a time-limited kubeconfig from Omni.
resource "omni_cluster_kubeconfig" "stawi" {
  cluster = omni_cluster.stawi.id
}
