output "instance_id" { value = contabo_instance.this.id }
output "ipv4" { value = data.external.vps_ip.result.ipv4 }
output "ipv6" { value = try(contabo_instance.this.ip_config[0].v6[0].ip, null) }
output "omni_account_id" {
  value     = random_uuid.omni_account_id.result
  sensitive = true
}
output "dex_omni_client_secret" {
  value     = random_password.dex_omni_client_secret.result
  sensitive = true
}
output "user_data" {
  value     = local.user_data
  sensitive = true
}
