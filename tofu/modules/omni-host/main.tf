# tofu/modules/omni-host/main.tf
#
# Single Contabo VPS running Omni + Dex + Caddy via docker-compose. All
# configuration declarative via cloud-init; no SSH-driven setup.
#
# License note: Omni is BSL-licensed (non-production self-host, option iii).
# Revisit when Stawi has production revenue.

resource "random_uuid" "omni_account_id" {
  # The Omni account ID is baked into every machine's SideroLink config.
  # Rotating it (e.g. by re-creating the random_uuid resource via state
  # rebuild) would orphan every cluster the host has ever provisioned —
  # they'd reject the new ID's signed configs. Pin it.
  lifecycle {
    ignore_changes = [keepers]
  }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle {
    ignore_changes = [length, special]
  }
}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
    {
      omni_version                         = var.omni_version
      dex_version                          = var.dex_version
      nginx_version                        = var.nginx_version
      omni_account_id                      = random_uuid.omni_account_id.result
      omni_account_name                    = var.omni_account_name
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      dex_omni_client_secret               = random_password.dex_omni_client_secret.result
      initial_users                        = var.initial_users
      eula_name                            = var.eula_name
      eula_email                           = var.eula_email
    }
  )

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      name                                 = var.name
      docker_compose_yaml                  = local.docker_compose_yaml
      dex_omni_client_secret               = random_password.dex_omni_client_secret.result
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      github_oidc_client_id                = var.github_oidc_client_id
      github_oidc_client_secret            = var.github_oidc_client_secret
      github_oidc_allowed_orgs             = var.github_oidc_allowed_orgs
      cf_dns_api_token                     = var.cf_dns_api_token
      eula_email                           = var.eula_email
      ssh_authorized_keys                  = var.ssh_authorized_keys
      ssh_enabled                          = var.ssh_enabled
      r2_account_id                        = var.r2_account_id
      r2_access_key_id                     = var.r2_access_key_id
      r2_secret_access_key                 = var.r2_secret_access_key
      r2_bucket_name                       = var.r2_bucket_name
      r2_backup_prefix                     = var.r2_backup_prefix
      # Auto-assign VPN IPs starting at 10.100.0.2 (.1 is the server)
      # in the order tofu walks the map. Stable per name across plans
      # — adding a new user only assigns them an unused IP, never
      # rotates an existing user's. Empty map disables the user-VPN
      # feature: the systemd service still starts, but the rendered
      # wg-users.conf has no peers, so the interface is up with zero
      # accept-listed traffic.
      vpn_users = {
        for idx, name in sort(keys(var.vpn_users)) :
        name => {
          public_key  = var.vpn_users[name].public_key
          assigned_ip = "10.100.0.${idx + 2}"
        }
      }
    }
  )
}

resource "contabo_instance" "this" {
  display_name = var.name
  product_id   = var.contabo_product_id
  region       = var.contabo_region
  image_id     = var.contabo_image_id
  user_data    = local.user_data
  period       = 1

  # Match node-contabo's pattern (modules/node-contabo/main.tf): the
  # contabo provider's image_id-only PUT is silently treated as a
  # metadata update (~40s, disk untouched) rather than a real
  # reinstall. user_data drift is similar — the provider stores the
  # new seed but the running VPS doesn't see it until reinstall.
  # Pin both fields here so tofu state matches first-create values
  # and let null_resource.ensure_image below own all reinstall
  # decisions via the proven Contabo PUT path used for cluster nodes.
  lifecycle {
    ignore_changes = [image_id, user_data]
  }
}

# Drive omni-host reinstalls via the same tofu/modules/node-contabo/
# ensure-image.sh script the cluster nodes use. Idempotent: if the
# instance is already on the target image AND force_reinstall_generation
# hasn't been bumped past 1, the script no-ops. Bumping the generation
# (or changing the rendered cloud-init) re-keys this null_resource's
# trigger map, which fires a full Contabo PUT — disk wipe + cloud-init
# re-run on first boot. Combined with omni-restore.service (cloud-init
# unit that pulls the latest /var/lib/omni snapshot from R2 before
# omni-stack starts), a force_reinstall_generation bump is the canonical
# way to push live-config drift to the omni-host VPS without a manual
# SSH workflow.
resource "null_resource" "ensure_image" {
  triggers = {
    instance_id                = contabo_instance.this.id
    target_image_id            = var.contabo_image_id
    user_data_sha              = sha256(local.user_data)
    force_reinstall_generation = var.force_reinstall_generation
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      INSTANCE_ID           = contabo_instance.this.id
      TARGET_IMAGE_ID       = var.contabo_image_id
      USER_DATA             = local.user_data
      CONTABO_CLIENT_ID     = var.contabo_client_id
      CONTABO_CLIENT_SECRET = var.contabo_client_secret
      CONTABO_API_USER      = var.contabo_api_user
      CONTABO_API_PASSWORD  = var.contabo_api_password
      # Failure here is fatal — the omni-host is the cluster's whole
      # management plane; we don't ever want a "partial" reinstall.
      NODE_ROLE       = "controlplane"
      FORCE_REINSTALL = var.force_reinstall_generation > 1 ? "1" : "0"
    }
    command = "${path.module}/../node-contabo/ensure-image.sh"
  }
}

# Block on omni stack readiness post-reinstall so downstream layers
# (01-contabo-infra, 02-oracle-infra, 03-talos) don't start their
# Talos / omnictl operations against a still-restoring Omni. Polls
# the workload-proxy / siderolink hostname's TLS handshake — once
# nginx + omni + dex are all up the cert is served and TLS succeeds.
# 10-minute ceiling matches the worst-case Contabo-reinstall +
# omni-restore-pulls-from-R2 + omni-stack-ready window.
resource "null_resource" "wait_for_omni_ready" {
  depends_on = [null_resource.ensure_image]

  triggers = {
    ensure_image_id = null_resource.ensure_image.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      ENDPOINT = "https://${var.siderolink_api_advertised_host}/healthz"
    }
    command = <<-EOT
      set -euo pipefail
      echo "[wait_for_omni_ready] polling $ENDPOINT"
      deadline=$(( $(date +%s) + 600 ))
      while :; do
        code=$(curl -ksS -o /dev/null -w '%%{http_code}' --max-time 5 "$ENDPOINT" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
          echo "[wait_for_omni_ready] $ENDPOINT returned 200"
          exit 0
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
          echo "[wait_for_omni_ready] timed out after 10min waiting for $ENDPOINT (last code: $code)" >&2
          exit 1
        fi
        sleep 10
      done
    EOT
  }
}
