# tofu/modules/oracle-account-infra/nodes.tf
data "talos_machine_configuration" "worker" {
  for_each           = var.workers
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = var.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches = [
    file("${var.shared_patches_dir}/common.yaml"),
    file("${var.shared_patches_dir}/network.yaml"),
    file("${var.shared_patches_dir}/storage.yaml"),
    file("${var.shared_patches_dir}/resolvers.yaml"),
    file("${var.shared_patches_dir}/timesync.yaml"),
    <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    hostname: ${var.account_key}-${each.key}
    auto: off
    EOT
    ,
    yamlencode({
      machine = {
        nodeLabels = merge(
          var.labels,
          each.value.labels,
          {
            "topology.kubernetes.io/region" = var.region
            "topology.kubernetes.io/zone"   = lower(replace(local.ad_0, ":", "-"))
            "node.antinvestor.io/provider"  = "oracle"
            "node.antinvestor.io/account"   = var.account_key
            "node.antinvestor.io/role"      = each.value.role
          },
          each.value.role == "controlplane" ? {
            "node-role.kubernetes.io/control-plane" = ""
            } : {
            "node-role.kubernetes.io/worker" = ""
          }
        )
        nodeAnnotations = merge(
          var.annotations,
          each.value.annotations,
          {
            "node.antinvestor.io/shape"               = each.value.shape
            "node.antinvestor.io/availability-domain" = local.ad_0
            "node.antinvestor.io/provider"            = "oracle"
            "node.antinvestor.io/account"             = var.account_key
            "node.antinvestor.io/role"                = each.value.role
          }
        )
      }
    }),
  ]
}

module "node" {
  for_each = var.workers
  source   = "../node-oracle"

  name                = "${var.account_key}-${each.key}"
  role                = each.value.role
  shape               = each.value.shape
  ocpus               = each.value.ocpus
  memory_gb           = each.value.memory_gb
  subnet_id           = oci_core_subnet.private.id
  image_id            = oci_core_image.talos.id
  compartment_ocid    = var.compartment_ocid
  assign_ipv6         = var.enable_ipv6
  availability_domain = local.ad_0
  labels              = merge(var.labels, each.value.labels)
  annotations         = merge(var.annotations, each.value.annotations)
  user_data           = base64encode(data.talos_machine_configuration.worker[each.key].machine_configuration)
  bastion_id          = oci_bastion_bastion.this.id
  account_key         = var.account_key
  region              = var.region

  providers = { oci = oci }
}
