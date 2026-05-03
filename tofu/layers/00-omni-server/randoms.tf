# Pinned secrets that ride with the omni-host across substrate
# switches. Live at layer scope (not inside any omni-host-* module)
# so flipping var.omni_host_provider doesn't rotate them — that
# would orphan every cluster ever provisioned by this Omni instance.

resource "random_uuid" "omni_account_id" {
  lifecycle { ignore_changes = [keepers] }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle { ignore_changes = [length, special] }
}
