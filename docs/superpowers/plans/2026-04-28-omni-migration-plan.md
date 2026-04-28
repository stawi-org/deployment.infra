# Omni Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move cluster lifecycle off this repo's tofu+talosctl rendering pipeline onto self-hosted Omni. Existing partially-broken `antinvestor-cluster` is torn down; new `stawi-cluster` runs on the same hardware (Contabo + OCI + on-prem) and is managed entirely by Omni. Operator's day-1 mental model becomes: edit `nodes.yaml`, push, done.

**Architecture:** Single Contabo VPS (`cluster-omni-contabo`, was `contabo-bwire-node-3`) running Ubuntu 24.04 LTS Minimal with a docker-compose stack of `omni` + `dex` + `cloudflared`. All config declarative via tofu-rendered cloud-init — no SSH-driven setup. Cloudflare orange-cloud at `cp.antinvestor.com` and `cp.stawi.org` proxies to the omni-host via CF Tunnel; no inbound ports on the VPS. Cluster nodes (Contabo CPs + OCI + on-prem) boot Talos with the `siderolink-agent` extension, dial home to Omni, get auto-allocated to `stawi-cluster`.

**Tech Stack:** OpenTofu 1.10, Cloudflare R2 backend, Talos v1.13.0, Omni latest, Dex (OIDC proxy), cloudflared, docker-compose, Ubuntu 24.04 LTS, terraform-provider-omni.

**License posture:** BSL self-host non-production (option iii in the spec). Revisit when Stawi has revenue.

**Phases:**
- **Phase A — Build (non-destructive)** — tasks 1–4. New code lands; existing cluster keeps running.
- **Phase B — Cutover (destructive)** — tasks 5–7. Existing cluster torn down; Omni stood up; `stawi-cluster` bootstraps. Expected 30–90 min downtime window.
- **Phase C — Cleanup** — tasks 8–9. Delete dead workflows, layers, scripts.

Reference spec: `docs/superpowers/specs/2026-04-28-omni-migration-design.md`.

---

## Phase A — Build

### Task 1: omni-host module + cloud-init

**Goal:** Reusable tofu module that provisions a single Contabo Ubuntu 24.04 VPS and brings up the Omni stack via docker-compose, fully declarative.

**Files:**
- Create: `tofu/modules/omni-host/main.tf`
- Create: `tofu/modules/omni-host/variables.tf`
- Create: `tofu/modules/omni-host/outputs.tf`
- Create: `tofu/modules/omni-host/cloud-init.yaml.tftpl`
- Create: `tofu/modules/omni-host/docker-compose.yaml.tftpl`
- Create: `tofu/modules/omni-host/versions.tf`
- Test: `tofu/modules/omni-host/tests/cloud-init_test.bats` (rendering + yaml-validity smoke test)

- [ ] **Step 1.1: Pin component versions in versions.auto.tfvars.json**

```json
{
  "talos_version": "v1.13.0",
  "kubernetes_version": "v1.35.2",
  "flux_version": "v2.4.0",
  "omni_version": "v1.4.6",
  "dex_version": "v2.41.1",
  "cloudflared_version": "2025.10.1"
}
```

Update `tofu/shared/versions.auto.tfvars.json` to add these three keys. The omni-host module reads them via `var.omni_version` etc.

- [ ] **Step 1.2: Write `tofu/modules/omni-host/variables.tf`**

```hcl
variable "name" {
  type        = string
  description = "Hostname for the Omni host VPS, e.g. cluster-omni-contabo."
}

variable "contabo_product_id" {
  type        = string
  default     = "V47"  # VPS-S, 1 CPU/8GB; sufficient for single-instance Omni + dex + cloudflared
  description = "Contabo product ID for the omni-host VPS shape."
}

variable "contabo_image_id" {
  type        = string
  description = "Contabo image ID for Ubuntu 24.04 LTS Minimal. Resolve via the Contabo API."
}

variable "contabo_region" {
  type    = string
  default = "EU"
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH keys allowed during cloud-init bootstrap and for break-glass access. After bootstrap the host has all inbound ports DROPped except CF Tunnel egress; SSH is reachable only via the Contabo console."
}

variable "omni_version" { type = string }
variable "dex_version" { type = string }
variable "cloudflared_version" { type = string }

variable "omni_account_name" {
  type        = string
  description = "Top-level Omni account name (e.g. \"stawi\")."
}

variable "siderolink_api_advertised_host" {
  type        = string
  description = "Public hostname Omni advertises in node siderolink cmdlines, e.g. cp.antinvestor.com."
}

variable "extra_dns_aliases" {
  type        = list(string)
  default     = []
  description = "Extra hostnames the Omni cert/SAN should cover, e.g. [\"cp.stawi.org\"]."
}

variable "github_oidc_client_id" {
  type        = string
  sensitive   = true
  description = "GitHub App client ID brokered via Dex into Omni."
}

variable "github_oidc_client_secret" {
  type        = string
  sensitive   = true
}

variable "github_oidc_allowed_orgs" {
  type        = list(string)
  default     = ["stawi-org"]
}

variable "cloudflare_tunnel_token" {
  type        = string
  sensitive   = true
  description = "Token for the pre-created CF Tunnel that fronts cp.antinvestor.com / cp.stawi.org."
}

variable "r2_endpoint" { type = string }

variable "r2_backup_access_key_id" {
  type      = string
  sensitive = true
}

variable "r2_backup_secret_access_key" {
  type      = string
  sensitive = true
}

variable "r2_backup_bucket" {
  type    = string
  default = "cluster-tofu-state"
}

variable "r2_backup_prefix" {
  type    = string
  default = "production/omni-backups/"
}
```

- [ ] **Step 1.3: Write `tofu/modules/omni-host/docker-compose.yaml.tftpl`**

```yaml
# Rendered by tofu and dropped at /etc/omni/docker-compose.yaml.
# Pinned tags only — bumping the version is a deliberate tofu var change.
version: "3.9"
services:
  omni:
    image: ghcr.io/siderolabs/omni:${omni_version}
    container_name: omni
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/lib/omni:/var/lib/omni
      - /etc/omni/omni.env:/etc/omni/omni.env:ro
    env_file:
      - /etc/omni/omni.env
    command:
      - --account-id=$${OMNI_ACCOUNT_ID}
      - --name=${omni_account_name}
      - --advertised-api-url=https://${siderolink_api_advertised_host}
      - --siderolink-api-advertised-url=https://${siderolink_api_advertised_host}
      - --machine-api-bind-addr=0.0.0.0:8090
      - --siderolink-wireguard-advertised-addr=$${OMNI_PUBLIC_IP}:50180
      - --auth-auth0-enabled=false
      - --auth-saml-enabled=false
      - --siderolink-disable-last-endpoint=false

  dex:
    image: ghcr.io/dexidp/dex:${dex_version}
    container_name: dex
    restart: unless-stopped
    network_mode: host
    volumes:
      - /etc/dex/config.yaml:/etc/dex/config.yaml:ro

  cloudflared:
    image: cloudflare/cloudflared:${cloudflared_version}
    container_name: cloudflared
    restart: unless-stopped
    network_mode: host
    command: tunnel --no-autoupdate run
    env_file:
      - /etc/cloudflared/cloudflared.env
```

(Versions, account name, advertised host all interpolated at tofu-render time. Hosts get exact values, no env-var indirection at runtime — single source of truth in tofu.)

- [ ] **Step 1.4: Write `tofu/modules/omni-host/cloud-init.yaml.tftpl`**

```yaml
#cloud-config
hostname: ${name}
fqdn: ${name}

users:
  - name: opadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
%{ for k in ssh_authorized_keys ~}
      - ${k}
%{ endfor ~}

apt:
  sources:
    docker:
      source: "deb [arch=amd64 signed-by=$KEY_FILE] https://download.docker.com/linux/ubuntu noble stable"
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

package_update: true
package_upgrade: true
packages:
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-buildx-plugin
  - docker-compose-plugin
  - rclone
  - sqlite3
  - unattended-upgrades

write_files:
  - path: /etc/omni/docker-compose.yaml
    permissions: "0640"
    owner: root:root
    content: |
${indent(6, docker_compose_yaml)}

  - path: /etc/omni/omni.env
    permissions: "0600"
    owner: root:root
    content: |
      OMNI_ACCOUNT_ID=${omni_account_id}
      OMNI_PUBLIC_IP=$$(curl -fsSL https://api.ipify.org)

  - path: /etc/dex/config.yaml
    permissions: "0640"
    owner: root:root
    content: |
      issuer: https://${siderolink_api_advertised_host}/dex
      storage: { type: sqlite3, config: { file: /var/lib/dex/dex.db } }
      web: { http: 0.0.0.0:5556 }
      connectors:
        - type: github
          id: github
          name: GitHub
          config:
            clientID: ${github_oidc_client_id}
            clientSecret: ${github_oidc_client_secret}
            redirectURI: https://${siderolink_api_advertised_host}/dex/callback
            orgs:
%{ for org in github_oidc_allowed_orgs ~}
              - name: ${org}
%{ endfor ~}
      oauth2: { skipApprovalScreen: true }
      staticClients:
        - id: omni
          secret: $$(openssl rand -hex 32)
          redirectURIs: [https://${siderolink_api_advertised_host}/oauth/callback]
          name: Omni

  - path: /etc/cloudflared/cloudflared.env
    permissions: "0600"
    owner: root:root
    content: |
      TUNNEL_TOKEN=${cloudflare_tunnel_token}

  - path: /etc/rclone/rclone.conf
    permissions: "0600"
    owner: root:root
    content: |
      [r2]
      type = s3
      provider = Cloudflare
      access_key_id = ${r2_backup_access_key_id}
      secret_access_key = ${r2_backup_secret_access_key}
      endpoint = ${r2_endpoint}
      acl = private

  - path: /etc/systemd/system/omni-stack.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Omni stack (omni + dex + cloudflared)
      Requires=docker.service
      After=docker.service network-online.target
      [Service]
      Type=oneshot
      RemainAfterExit=true
      ExecStart=/usr/bin/docker compose -f /etc/omni/docker-compose.yaml up -d --remove-orphans
      ExecStop=/usr/bin/docker compose -f /etc/omni/docker-compose.yaml down
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/omni-backup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Snapshot Omni sqlite + rclone to R2
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/omni-backup.sh

  - path: /etc/systemd/system/omni-backup.timer
    permissions: "0644"
    content: |
      [Unit]
      Description=Hourly Omni state backup
      [Timer]
      OnCalendar=hourly
      Persistent=true
      [Install]
      WantedBy=timers.target

  - path: /usr/local/bin/omni-backup.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      tmp=$(mktemp -d)
      trap "rm -rf $tmp" EXIT
      sqlite3 /var/lib/omni/omni.db ".backup '$tmp/omni-$ts.db'"
      gzip -9 "$tmp/omni-$ts.db"
      rclone copy "$tmp/" "r2:${r2_backup_bucket}/${r2_backup_prefix}" --include "omni-*.db.gz"
      # 30-day retention
      rclone delete --min-age 30d "r2:${r2_backup_bucket}/${r2_backup_prefix}"

  - path: /etc/iptables/rules.v4
    permissions: "0640"
    content: |
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -p icmp -j ACCEPT
      COMMIT

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

runcmd:
  - mkdir -p /var/lib/omni /var/lib/dex
  - chown -R root:root /var/lib/omni /var/lib/dex
  - chmod 0700 /var/lib/omni /var/lib/dex
  - DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  - iptables-restore < /etc/iptables/rules.v4
  - systemctl daemon-reload
  - systemctl enable --now omni-stack.service omni-backup.timer
```

- [ ] **Step 1.5: Write `tofu/modules/omni-host/main.tf`**

```hcl
# tofu/modules/omni-host/main.tf
#
# Single Contabo VPS running Omni + Dex + cloudflared via docker-compose.
# All configuration declarative via cloud-init; no SSH-driven setup.

resource "random_uuid" "omni_account_id" {}

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
    {
      omni_version                   = var.omni_version
      dex_version                    = var.dex_version
      cloudflared_version            = var.cloudflared_version
      omni_account_name              = var.omni_account_name
      siderolink_api_advertised_host = var.siderolink_api_advertised_host
    }
  )

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      name                           = var.name
      ssh_authorized_keys            = var.ssh_authorized_keys
      docker_compose_yaml            = local.docker_compose_yaml
      omni_account_id                = random_uuid.omni_account_id.result
      siderolink_api_advertised_host = var.siderolink_api_advertised_host
      github_oidc_client_id          = var.github_oidc_client_id
      github_oidc_client_secret      = var.github_oidc_client_secret
      github_oidc_allowed_orgs       = var.github_oidc_allowed_orgs
      cloudflare_tunnel_token        = var.cloudflare_tunnel_token
      r2_endpoint                    = var.r2_endpoint
      r2_backup_access_key_id        = var.r2_backup_access_key_id
      r2_backup_secret_access_key    = var.r2_backup_secret_access_key
      r2_backup_bucket               = var.r2_backup_bucket
      r2_backup_prefix               = var.r2_backup_prefix
    }
  )
}

resource "contabo_instance" "this" {
  display_name = var.name
  product_id   = var.contabo_product_id
  region       = var.contabo_region
  image_id     = var.contabo_image_id
  user_data    = local.user_data

  lifecycle {
    ignore_changes = [user_data]
  }
}
```

- [ ] **Step 1.6: Write `tofu/modules/omni-host/outputs.tf`**

```hcl
output "instance_id"    { value = contabo_instance.this.id }
output "ipv4"           { value = contabo_instance.this.ip_config[0].v4[0].ip }
output "ipv6"           { value = contabo_instance.this.ip_config[0].v6[0].ip }
output "omni_account_id" {
  value     = random_uuid.omni_account_id.result
  sensitive = true
}
```

- [ ] **Step 1.7: Write `tofu/modules/omni-host/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "~> 1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 1.8: Write smoke test for cloud-init rendering**

`tofu/modules/omni-host/tests/cloud-init_test.bats`:

```bash
#!/usr/bin/env bats
# Verifies the rendered cloud-init is valid YAML and contains expected
# load-bearing markers. Run from repo root: bats tofu/modules/omni-host/tests/

setup() {
  tmp=$(mktemp -d)
  cd "$tmp"
  cat > main.tf <<'EOF'
module "h" {
  source = "../../"
  name = "test"
  contabo_image_id = "ubuntu-24.04"
  ssh_authorized_keys = ["ssh-ed25519 AAA test"]
  omni_version = "v1.4.6"
  dex_version = "v2.41.1"
  cloudflared_version = "2025.10.1"
  omni_account_name = "stawi"
  siderolink_api_advertised_host = "cp.example.com"
  github_oidc_client_id = "abc"
  github_oidc_client_secret = "def"
  cloudflare_tunnel_token = "ghi"
  r2_endpoint = "https://x.r2.cloudflarestorage.com"
  r2_backup_access_key_id = "k"
  r2_backup_secret_access_key = "s"
}
output "ud" { value = module.h.user_data sensitive = true }
EOF
  ln -s "$BATS_TEST_DIRNAME/../../" .
}

teardown() { rm -rf "$tmp"; }

@test "cloud-init renders" {
  run tofu init -backend=false
  [ "$status" -eq 0 ]
  run tofu plan -no-color
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 1.9: Run the smoke test**

```bash
cd /home/j/code/stawi-org/deployment.infra
bats tofu/modules/omni-host/tests/cloud-init_test.bats
```

Expected: 1 test, 0 failures.

- [ ] **Step 1.10: Commit**

```bash
git add tofu/modules/omni-host/ tofu/shared/versions.auto.tfvars.json
git commit -m "tofu: add omni-host module (Contabo VPS + cloud-init + docker-compose)

Single-VM Omni server: Ubuntu 24.04 LTS Minimal on a Contabo VPS,
docker-compose stack of omni + dex + cloudflared, all declarative
via tofu-rendered cloud-init. SSH allowed during bootstrap only;
post-bootstrap iptables DROP all inbound except established/related.
CF Tunnel is the only ingress path. Hourly sqlite snapshot to R2.

Per docs/superpowers/specs/2026-04-28-omni-migration-design.md."
```

---

### Task 2: Bump schematic with siderolink-agent extension

**Files:**
- Modify: `tofu/shared/schematic.yaml`
- Modify: `tofu/modules/oracle-account-infra/variables.tf` (bump `force_image_generation` default)
- Modify: `tofu/layers/01-contabo-infra/main.tf` (bump Contabo image-rebuild trigger)

- [ ] **Step 2.1: Add siderolink-agent extension to the schematic**

Edit `tofu/shared/schematic.yaml`:

```yaml
customization:
  extraKernelArgs:
    - ipv6.disable=0
    - ipv6.autoconf=0
  systemExtensions:
    officialExtensions:
      - siderolabs/util-linux-tools
      - siderolabs/siderolink-agent
```

- [ ] **Step 2.2: Bump `force_image_generation` in oracle module**

In `tofu/modules/oracle-account-infra/variables.tf`, bump the default from `10` → `11`. In `tofu/layers/02-oracle-infra/terraform.tfvars`, bump `force_image_generation = 10` → `11`. New schematic ID forces fresh CreateImage in every tenancy.

- [ ] **Step 2.3: Force Contabo image rebuild**

Contabo's image lifecycle is keyed off `null_resource.ensure_image` + the schematic ID; the schematic ID change should automatically trigger rebuild on next apply. Verify by running `tofu plan` in `tofu/layers/01-contabo-infra/` — expect `null_resource.ensure_image` to be replaced for each Contabo node.

- [ ] **Step 2.4: Validate**

```bash
cd tofu/layers/02-oracle-infra
TF_VAR_account_key=bwire tofu init -backend=false -input=false
TF_VAR_account_key=bwire tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 2.5: Commit**

```bash
git add tofu/shared/schematic.yaml tofu/modules/oracle-account-infra/variables.tf tofu/layers/02-oracle-infra/terraform.tfvars
git commit -m "schematic: add siderolink-agent extension; bump force_image_generation

Talos image factory will produce a new schematic ID, forcing fresh
image builds in every Contabo + OCI account. The siderolink-agent
extension is the on-machine half of Omni's SideroLink protocol —
without it, nodes can't dial home to Omni.

Per docs/superpowers/specs/2026-04-28-omni-migration-design.md
Phase A Task 2."
```

---

### Task 3: Add `omni_siderolink_url` plumbing through node modules

**Files:**
- Modify: `tofu/modules/node-contabo/variables.tf`
- Modify: `tofu/modules/node-contabo/main.tf` (kernel cmdline injection)
- Modify: `tofu/modules/node-oracle/variables.tf`
- Modify: `tofu/modules/node-oracle/main.tf` (user_data / metadata cmdline)
- Modify: `tofu/modules/oracle-account-infra/nodes.tf` (pass through)
- Modify: `tofu/layers/01-contabo-infra/main.tf` (pass from layer var)
- Modify: `tofu/layers/02-oracle-infra/variables.tf` + `main.tf`

- [ ] **Step 3.1: Add `omni_siderolink_url` to node-contabo**

`tofu/modules/node-contabo/variables.tf`:

```hcl
variable "omni_siderolink_url" {
  type        = string
  description = "Full siderolink URL injected into the boot cmdline, e.g. https://cp.antinvestor.com?jointoken=<token>. Empty string disables (transitional)."
  default     = ""
}
```

In `tofu/modules/node-contabo/main.tf`, the kernel cmdline is built inside `null_resource.ensure_image`'s local-exec which calls `scripts/contabo-ensure-image.sh`. That script accepts a `--extra-cmdline` flag. Add the flag wiring:

```hcl
provisioner "local-exec" {
  command = "${path.module}/../../../scripts/contabo-ensure-image.sh \\
    --node ${var.name} \\
    --schematic-id ${var.schematic_id} \\
    --talos-version ${var.talos_version} \\
    %{ if var.omni_siderolink_url != "" ~}
    --extra-cmdline 'siderolink.api=${var.omni_siderolink_url}' \\
    %{ endif ~}
    "
}
```

Then update `scripts/contabo-ensure-image.sh` to accept `--extra-cmdline` and append it to the Talos installer cmdline written into the Contabo `user_data` field of the API call.

- [ ] **Step 3.2: Same for node-oracle**

`tofu/modules/node-oracle/variables.tf`:

```hcl
variable "omni_siderolink_url" {
  type        = string
  description = "Full siderolink URL injected into the kernel cmdline at instance launch."
  default     = ""
}
```

In `tofu/modules/node-oracle/main.tf`, the `oci_core_instance.this` resource currently has `metadata = {}`. Switch to:

```hcl
metadata = var.omni_siderolink_url == "" ? {} : {
  user_data = base64encode("kernel-cmdline-append=siderolink.api=${var.omni_siderolink_url}")
}
```

(Exact OCI convention: cloud-init reads `user_data` from instance metadata; for Talos this gets parsed at first boot.)

- [ ] **Step 3.3: Plumb from oracle-account-infra**

`tofu/modules/oracle-account-infra/nodes.tf`:

```hcl
module "node" {
  ...
  omni_siderolink_url = var.omni_siderolink_url
}
```

And add the variable to `tofu/modules/oracle-account-infra/variables.tf`.

- [ ] **Step 3.4: Plumb from layers**

`tofu/layers/01-contabo-infra/variables.tf` and `tofu/layers/02-oracle-infra/variables.tf` gain:

```hcl
variable "omni_siderolink_url" {
  type    = string
  default = ""
}
```

`main.tf` in each layer passes it through to the module instantiation.

- [ ] **Step 3.5: Validate**

```bash
cd tofu/layers/01-contabo-infra && tofu init -backend=false -input=false && tofu validate
cd ../02-oracle-infra && TF_VAR_account_key=bwire tofu init -backend=false -input=false && tofu validate
```

Expected: both `Success! The configuration is valid.`

- [ ] **Step 3.6: Commit**

```bash
git add tofu/modules/node-contabo/ tofu/modules/node-oracle/ tofu/modules/oracle-account-infra/ tofu/layers/01-contabo-infra/ tofu/layers/02-oracle-infra/
git commit -m "node modules: plumb omni_siderolink_url into kernel cmdline

When set, every node's first-boot cmdline contains
\"siderolink.api=https://cp.antinvestor.com?jointoken=<token>\".
The siderolink-agent extension (added in the previous commit)
reads this and dials home to Omni for registration. Empty string
default keeps the existing path until cutover.

Per docs/superpowers/specs/2026-04-28-omni-migration-design.md
Phase A Task 3."
```

---

### Task 4: New tofu layer `00-omni-server`

**Files:**
- Create: `tofu/layers/00-omni-server/main.tf`
- Create: `tofu/layers/00-omni-server/variables.tf`
- Create: `tofu/layers/00-omni-server/outputs.tf`
- Create: `tofu/layers/00-omni-server/backend.tf`
- Create: `tofu/layers/00-omni-server/versions.tf`
- Create: `tofu/layers/00-omni-server/sops-check.tf` (synced from template)

- [ ] **Step 4.1: Backend + versions**

`tofu/layers/00-omni-server/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-omni-server.tfstate"
    region                      = "auto"
    encrypt                     = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
```

`tofu/layers/00-omni-server/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "~> 1.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
  }
}
```

- [ ] **Step 4.2: Variables**

`tofu/layers/00-omni-server/variables.tf` declares all the inputs the omni-host module needs (mostly TF_VAR_* secrets). Mirror the module's variable signature.

- [ ] **Step 4.3: Sync the sops-check fixture**

```bash
./scripts/sync-sops-check.sh tofu/layers/00-omni-server/
```

- [ ] **Step 4.4: Main**

`tofu/layers/00-omni-server/main.tf`:

```hcl
data "aws_s3_object" "tunnel_secrets" {
  bucket = "cluster-tofu-state"
  key    = "production/inventory/cloudflare/omni-tunnel.sops.json"
}

data "sops_external" "tunnel" {
  source = data.aws_s3_object.tunnel_secrets.body
  input_type = "json"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "omni" {
  account_id = var.cloudflare_account_id
  name       = "omni"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "omni" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.omni.id
  config = {
    ingress = [
      { hostname = "cp.antinvestor.com", service = "http://127.0.0.1:8090" },
      { hostname = "cp.stawi.org",       service = "http://127.0.0.1:8090" },
      { service = "http_status:404" }
    ]
  }
}

module "omni_host" {
  source = "../../modules/omni-host"

  name = "cluster-omni-contabo"
  contabo_image_id = var.contabo_ubuntu_24_04_image_id
  ssh_authorized_keys = var.ssh_authorized_keys

  omni_version        = var.omni_version
  dex_version         = var.dex_version
  cloudflared_version = var.cloudflared_version
  omni_account_name   = "stawi"
  siderolink_api_advertised_host = "cp.antinvestor.com"
  extra_dns_aliases              = ["cp.stawi.org"]

  github_oidc_client_id     = var.github_oidc_client_id
  github_oidc_client_secret = var.github_oidc_client_secret
  cloudflare_tunnel_token   = cloudflare_zero_trust_tunnel_cloudflared.omni.tunnel_token

  r2_endpoint                 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  r2_backup_access_key_id     = var.etcd_backup_r2_access_key_id
  r2_backup_secret_access_key = var.etcd_backup_r2_secret_access_key
}

resource "cloudflare_dns_record" "cp_antinvestor" {
  for_each = toset(["A", "AAAA"])
  zone_id  = var.cloudflare_zone_id_antinvestor
  name     = "cp"
  type     = each.value
  content  = each.value == "A" ? cloudflare_zero_trust_tunnel_cloudflared.omni.cname : cloudflare_zero_trust_tunnel_cloudflared.omni.cname
  proxied  = true
  ttl      = 1
}

resource "cloudflare_dns_record" "cp_stawi" {
  for_each = toset(["A", "AAAA"])
  zone_id  = var.cloudflare_zone_id_stawi
  name     = "cp"
  type     = each.value
  content  = each.value == "A" ? cloudflare_zero_trust_tunnel_cloudflared.omni.cname : cloudflare_zero_trust_tunnel_cloudflared.omni.cname
  proxied  = true
  ttl      = 1
}
```

(Note: CF Tunnel CNAME convention — DNS records become CNAMEs to `<tunnel-id>.cfargotunnel.com` with proxied=true. Adjust syntax to provider 5.x.)

- [ ] **Step 4.5: Outputs**

```hcl
output "omni_url" { value = "https://cp.antinvestor.com" }
output "omni_host_ipv4" { value = module.omni_host.ipv4 }
output "tunnel_id" { value = cloudflare_zero_trust_tunnel_cloudflared.omni.id }
```

- [ ] **Step 4.6: Validate locally**

```bash
cd tofu/layers/00-omni-server
tofu init -backend=false -input=false
tofu validate
rm -rf .terraform .terraform.lock.hcl
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4.7: Commit**

```bash
git add tofu/layers/00-omni-server/
git commit -m "tofu: add 00-omni-server layer (CF Tunnel + omni-host module)

Provisions cluster-omni-contabo via the omni-host module, registers
the Cloudflare Tunnel that fronts cp.{antinvestor.com,stawi.org},
sets the orange-cloud DNS records pointing at the tunnel.
Apply runs after the existing antinvestor-cluster is torn down
(see Phase B in the migration plan)."
```

---

### Task 5: New tofu layer `03-omni-cluster`

**Files:**
- Create: `tofu/layers/03-omni-cluster/main.tf`
- Create: `tofu/layers/03-omni-cluster/backend.tf`
- Create: `tofu/layers/03-omni-cluster/versions.tf`
- Create: `tofu/layers/03-omni-cluster/outputs.tf`
- Create: `tofu/layers/03-omni-cluster/sops-check.tf`

- [ ] **Step 5.1: Backend + versions**

`tofu/layers/03-omni-cluster/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/03-omni-cluster.tfstate"
    region                      = "auto"
    encrypt                     = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
```

`tofu/layers/03-omni-cluster/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    omni = {
      source  = "siderolabs/omni"
      version = "~> 0.5"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
  }
}
```

- [ ] **Step 5.2: Cluster template**

`tofu/layers/03-omni-cluster/main.tf`:

```hcl
data "terraform_remote_state" "omni_server" {
  backend = "s3"
  config = {
    bucket   = "cluster-tofu-state"
    key      = "production/00-omni-server.tfstate"
    endpoint = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
    ...
  }
}

provider "omni" {
  endpoint = "https://cp.antinvestor.com"
  service_account_key = var.omni_service_account_key
}

resource "omni_cluster" "stawi" {
  name               = "stawi-cluster"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  features {
    enable_workload_proxy = true
  }
}

resource "omni_machine_class" "controlplane" {
  name = "controlplane"
  match_labels = ["role=controlplane"]
}

resource "omni_machine_class" "worker" {
  name = "worker"
  match_labels = ["role=worker"]
}

resource "omni_cluster_machine_class" "stawi_cp" {
  cluster_name        = omni_cluster.stawi.name
  machine_class_name  = omni_machine_class.controlplane.name
  role                = "controlplane"
  machine_count       = 3
}

resource "omni_cluster_machine_class" "stawi_workers" {
  cluster_name        = omni_cluster.stawi.name
  machine_class_name  = omni_machine_class.worker.name
  role                = "worker"
  machine_count       = -1  # all available
}
```

- [ ] **Step 5.3: Outputs**

```hcl
output "siderolink_url" {
  value = omni_cluster.stawi.siderolink_join_url
  sensitive = true
}

output "kubeconfig" {
  value = omni_cluster.stawi.kubeconfig
  sensitive = true
}

output "talosconfig" {
  value = omni_cluster.stawi.talosconfig
  sensitive = true
}
```

- [ ] **Step 5.4: Validate**

```bash
cd tofu/layers/03-omni-cluster
tofu init -backend=false -input=false
tofu validate
```

Expected: `Success!`. (Apply waits until Omni is reachable — Phase B step.)

- [ ] **Step 5.5: Commit**

```bash
git add tofu/layers/03-omni-cluster/
git commit -m "tofu: add 03-omni-cluster layer (defines stawi-cluster in Omni)

Uses terraform-provider-omni to declare stawi-cluster's template:
talos version, k8s version, machine classes (controlplane/worker),
auto-assignment rules. Apply depends on 00-omni-server's tofu
state (Omni endpoint must be reachable)."
```

---

## Phase B — Cutover (DESTRUCTIVE; cluster down for 30–90 min)

> ⚠ **Operator-driven, not automated.** Each step verified manually before proceeding to the next. The repo's existing CI workflows are paused for the duration (manual `gh workflow disable tofu-apply.yml`).

### Task 6: Tear down antinvestor-cluster + provision omni-host

- [ ] **Step 6.1: Pause CI**

```bash
gh workflow disable tofu-apply.yml
gh workflow disable cluster-reset.yml
gh workflow disable cluster-reinstall.yml
```

- [ ] **Step 6.2: Pre-flip Cloudflare DNS**

In Cloudflare dashboard, set `cp.antinvestor.com` and `cp.stawi.org` to orange-cloud, target = the Tunnel CNAME (which doesn't exist yet → temporary 502 from CF, expected). Or wait until step 6.5 which lets tofu manage this.

- [ ] **Step 6.3: Drop tofu state for old talos layers**

```bash
aws s3 rm s3://cluster-tofu-state/production/03-talos.tfstate \
  --endpoint-url https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
aws s3 rm s3://cluster-tofu-state/production/00-talos-secrets.tfstate \
  --endpoint-url https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
```

This makes the old cluster unmanaged but doesn't touch the running VMs.

- [ ] **Step 6.4: Reimage contabo-bwire-node-3 → cluster-omni-contabo**

Edit `production/inventory/contabo/bwire/nodes.yaml`:
- Remove `contabo-bwire-node-3` entry.
- (Don't yet add `cluster-omni-contabo` here; it lives in `00-omni-server` state, separate from the cluster nodes inventory.)

Push and merge. Then in Contabo dashboard or via API: reinstall node-3 with the Ubuntu 24.04 LTS Minimal image. Note its instance ID; that becomes the omni-host instance.

- [ ] **Step 6.5: Apply 00-omni-server**

```bash
gh workflow run tofu-apply.yml --ref main \
  -f layer=00-omni-server -f mode=apply
```

(May need to `gh workflow enable` first.) Expected output: omni-host provisioned (or imported, if you re-used node-3's instance ID), CF Tunnel created, DNS records set to orange-cloud → tunnel.

- [ ] **Step 6.6: Verify Omni reachable**

```bash
curl -fsSL https://cp.antinvestor.com/healthz
# Expected: 200 OK with {"status":"ok"}

# Browser: https://cp.antinvestor.com — Dex login page → GitHub OIDC login.
```

If TLS, OIDC, or tunnel routing has issues, tail logs: `ssh opadmin@<vm-ip> "journalctl -u omni-stack -f"`.

- [ ] **Step 6.7: Generate stawi-cluster join token**

```bash
omnictl --insecure login https://cp.antinvestor.com
omnictl serviceaccount create tofu-omni-sa
# Copy the token; store as TF_VAR_omni_service_account_key.

omnictl cluster template generate --name stawi-cluster > /tmp/stawi-template.yaml
# Inspect, adjust if needed.

# Get the siderolink join URL for the cluster
omnictl cluster siderolink-url stawi-cluster
# This URL is what nodes' kernel cmdlines reference.
```

Save the service-account key + siderolink URL into the inventory's sopsed config so subsequent applies pick them up.

---

### Task 7: Apply 03-omni-cluster + reimage cluster nodes

- [ ] **Step 7.1: Apply 03-omni-cluster**

```bash
gh workflow run tofu-apply.yml --ref main \
  -f layer=03-omni-cluster -f mode=apply
```

Expected: Omni now has a `stawi-cluster` template registered, awaiting machines.

- [ ] **Step 7.2: Set TF_VAR_omni_siderolink_url cluster-wide**

Add to `tofu/shared/versions.auto.tfvars.json` (or a new sopsed inventory file):

```json
{
  "omni_siderolink_url": "https://cp.antinvestor.com?jointoken=<token>"
}
```

(Encrypt with sops; the layer pulls this from R2.)

- [ ] **Step 7.3: Trigger cluster-wide reinstall via reconstruction request**

```bash
gh workflow run tofu-reconstruct.yml --ref main \
  -f operation=reinstall -f scope=all \
  -f confirm=REINSTALL-DISKS \
  -f reason="Migrate to Omni / stawi-cluster"
```

Merge the resulting PR. cluster-reinstall.yml fires → tofu-apply runs across layers 01/02 → instances destroy+create with the new schematic and the omni-siderolink kernel cmdline.

- [ ] **Step 7.4: Watch nodes register in Omni**

```bash
watch -n 5 'omnictl machine list --output table'
```

Expected: 5 (or however many) machines transition to `Connected` over ~5 min as each VM finishes reinstalling and dials home.

- [ ] **Step 7.5: Watch cluster bootstrap**

```bash
omnictl cluster status stawi-cluster
```

Expected: nodes auto-allocate to roles per the machine classes; etcd bootstraps; kube-apiserver Ready. Total time from first node registration to Ready cluster: ~10 min.

- [ ] **Step 7.6: Pull kubeconfig**

```bash
omnictl kubeconfig --cluster stawi-cluster > ~/.kube/stawi.yaml
KUBECONFIG=~/.kube/stawi.yaml kubectl get nodes -o wide
```

Expected: all nodes Ready.

---

### Task 8: Migrate Flux to stawi-cluster

- [ ] **Step 8.1: Bootstrap Flux on the new cluster**

```bash
cd tofu/layers/04-flux
gh workflow run tofu-apply.yml --ref main -f layer=04-flux -f mode=apply
```

The 04-flux layer reads kubeconfig from 03-omni-cluster's outputs (replacing the 03-talos lookup). Flux deploys the same `deployment.manifests` repo state to the new cluster.

- [ ] **Step 8.2: Verify workloads landed**

```bash
flux check
flux get all
```

Expected: same workloads as the old cluster (the hello-world workload at minimum), all reconciled.

---

## Phase C — Cleanup

### Task 9: Delete dead code

- [ ] **Step 9.1: Delete retired tofu layers**

```bash
git rm -r tofu/layers/00-talos-secrets/ tofu/layers/03-talos/
git rm -r tofu/modules/talos-node-config/  # if no longer referenced
```

- [ ] **Step 9.2: Delete retired workflows**

```bash
git rm .github/workflows/cluster-reset.yml
git rm .github/workflows/cluster-reinstall.yml
git rm .github/workflows/tofu-reconstruct.yml
git rm .github/workflows/node-recovery.yml
```

- [ ] **Step 9.3: Replace cluster-health.yml with a one-liner**

`scripts/cluster-health.sh` becomes a 5-line bash script that curls `cp.antinvestor.com/healthz` and runs `omnictl cluster status stawi-cluster`. The workflow becomes an `on: schedule` cron firing the script.

- [ ] **Step 9.4: Delete reconstruction request files + archive**

```bash
git rm -r .github/reconstruction/
```

- [ ] **Step 9.5: Delete retired scripts**

```bash
git rm scripts/talos-apply-or-upgrade.sh
git rm scripts/oci-image-create-or-find.sh  # already gone
git rm scripts/sync-sops-check.sh  # if no layers reference the template anymore
```

- [ ] **Step 9.6: Drop deleted-layer R2 state**

```bash
for k in production/00-talos-secrets.tfstate production/03-talos.tfstate; do
  aws s3 rm "s3://cluster-tofu-state/$k" \
    --endpoint-url https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
done
```

- [ ] **Step 9.7: Run tofu fmt + validate across remaining layers**

```bash
tofu fmt -recursive tofu/
for l in 00-omni-server 01-contabo-infra 02-oracle-infra 02-onprem-infra 03-omni-cluster 04-flux; do
  cd "tofu/layers/$l"
  tofu init -backend=false -input=false 2>&1 | tail -3
  tofu validate
  cd -
done
```

Expected: every layer reports Success.

- [ ] **Step 9.8: Commit and merge**

```bash
git add -A
git commit -m "cleanup: remove pre-Omni tofu layers, scripts, workflows

Per the omni-migration cutover. tofu/layers/00-talos-secrets/,
tofu/layers/03-talos/, scripts/talos-apply-or-upgrade.sh, the
.github/reconstruction/ request-file machinery, and the
cluster-{reset,reinstall} / tofu-reconstruct / node-recovery
workflows all retire.

stawi-cluster is now exclusively managed by Omni; node lifecycle
flows through the dashboard or omnictl. Adding a node = edit
production/inventory/<provider>/<account>/nodes.yaml, push, and
the new VM auto-registers with Omni.

Per docs/superpowers/specs/2026-04-28-omni-migration-design.md
Phase C Task 9."
```

---

## Self-review checklist (run before opening any PR)

1. **`tofu fmt -recursive tofu/` is clean.**
2. **`tofu validate` passes in every remaining layer.**
3. **`bats tofu/modules/omni-host/tests/`** passes.
4. **No references to removed paths** — `grep -r 'talos-secrets\|03-talos\|cluster-reset\|tofu-reconstruct' tofu/ .github/ scripts/` returns nothing.
5. **License posture documented** — the design doc's BSL-iii note is in tree; the `omni-host` module's `main.tf` header repeats the non-prod-only caveat.

## Roll-back plan

If Phase B fails (Omni won't bootstrap, nodes can't register, kubeconfig doesn't work):

1. Restore antinvestor-cluster: `aws s3 cp s3://.../production/03-talos.tfstate.bak ...` (take a backup before step 6.3).
2. Re-apply old layers: `gh workflow run tofu-apply.yml -f layer=00-talos-secrets -f mode=apply`, then 03-talos, etc.
3. Reset OCI nodes via the reinstall request flow (which still exists pre-Phase-C).
4. The old cluster comes back as it was (Talos v1.13.0, 3 Contabo nodes Ready, OCI in maintenance — same broken state as today, but at least no regression).

Phase C is purely additive deletes; safe to revert via `git revert`.
