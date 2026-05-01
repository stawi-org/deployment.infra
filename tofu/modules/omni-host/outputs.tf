output "instance_id" { value = contabo_instance.this.id }
output "ipv4" { value = contabo_instance.this.ip_config[0].v4[0].ip }
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

# Per-user wg-users client config skeleton. The server's PUBLIC key
# is intentionally NOT in this output — it isn't known until first
# boot of the omni-host (wg-users-init.service generates it). Operator
# fetches it once via `ssh root@<omni-host> cat /etc/wireguard/
# wg-users.pubkey` and pastes it into the `[Peer] PublicKey` field
# below before sending to the user. The user replaces the
# <YOUR_PRIVATE_KEY> placeholder with the private half of their own
# locally-generated keypair.
output "wg_user_client_configs" {
  description = "Per-VPN-user wg-quick config skeletons. User fills in their own PrivateKey; operator fills in the server PublicKey from /etc/wireguard/wg-users.pubkey."
  value = {
    for idx, name in sort(keys(var.vpn_users)) :
    name => <<-EOT
      [Interface]
      PrivateKey = <YOUR_PRIVATE_KEY>
      Address = 10.100.0.${idx + 2}/24
      DNS = 1.1.1.1, 1.0.0.1

      [Peer]
      PublicKey = <SERVER_PUBLIC_KEY_FROM_wg-users.pubkey>
      Endpoint = ${var.siderolink_wireguard_advertised_host}:51820
      AllowedIPs = 0.0.0.0/0, ::/0
      PersistentKeepalive = 25
    EOT
  }
}
