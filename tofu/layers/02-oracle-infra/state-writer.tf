module "oracle_account_state_writer" {
  for_each       = toset(local.oracle_account_keys)
  source         = "../../modules/node-state"
  provider_name  = "oracle"
  account        = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "oracle"
    account  = each.key
    nodes = try({
      for node_key, node in module.oracle_account[each.key].nodes_state :
      node_key => {
        provider_data = {
          oci_instance_ocid = node.id
          shape             = node.shape
          ocpus             = node.ocpus
          memory_gb         = node.memory_gb
          region            = node.region
          ipv4              = node.ipv4
          ipv6              = node.ipv6
          status            = "running"
          discovered_at     = timestamp()
        }
      }
    }, {})
  }

  depends_on = [module.oracle_account]
}
