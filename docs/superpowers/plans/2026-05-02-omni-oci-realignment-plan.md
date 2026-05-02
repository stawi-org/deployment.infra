# Omni-on-OCI Cluster Realignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Realign the cluster onto a new architecture in a single PR + single cutover window: omni-host moves to OCI bwire (A1.Flex Always-Free), all Contabo VPSes become workers, per-machine `node-contabo.tftpl` patch wired into the cluster template via standalone `ConfigPatches`, OCI IAM collapsed onto the existing operator user, SSH-lockdown via WG.

**Architecture:** New `tofu/modules/omni-host-oci/` replaces the deprecated Contabo `omni-host` module. `00-omni-server` reads bwire's CSK + reserved-IP outputs from `02-oracle-infra/bwire` tfstate. Per-machine ConfigPatches are rendered + applied by `sync-cluster-template.yml` from each Contabo tfstate, label-targeted by `omni.sidero.dev/cluster=stawi` + `node.antinvestor.io/name=<n>`.

**Tech Stack:** OpenTofu 1.x, Contabo provider, OCI provider, Cloudflare provider, sops/age, Omni v1.7.1, Talos v1.13, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-05-02-omni-oci-realignment-design.md` (commit 9293805).

**Branch:** `feat/omni-oci-realignment`. Final PR opens against `main`.

---

## Pre-merge operator runbook

These steps run **before** the PR is opened/merged. Bootstrap chicken-and-egg — tofu can't mint these because tofu can't auth without them.

- [ ] **PRE-1: Verify OCI bwire Always-Free quota free.**

```bash
oci limits utilization-summary list \
  --service-name compute --compartment-id "$BWIRE_COMPARTMENT_OCID" \
  --profile bwire --output table
oci limits value list \
  --service-name vcn --compartment-id "$BWIRE_TENANCY_OCID" \
  --profile bwire --output table | grep -i 'public-ip'
```
Pass: ARM A1.Flex shows ≥4 OCPUs + ≥24 GB available; reserved-IPv4 ≥2 free.

- [ ] **PRE-2: Confirm OCI WIF federation is set up for bwire.** The `02-oracle-infra` matrix already iterates `bwire` (via `tofu/shared/accounts.yaml`), so federation should already be in place from earlier work. Verify by reading `production/inventory/oracle/bwire/auth.yaml` after PRE-3 (below) and confirming the `tenancy_ocid` matches the bwire tenancy listed in `~/.oci/config`'s `[bwire]` profile.

- [ ] **PRE-3: Pre-stage R2 inventory `production/inventory/oracle/bwire/auth.yaml`** (plaintext; oracle auth is non-sensitive pointers).

```bash
cat > /tmp/bwire-auth.yaml <<EOF
auth:
  tenancy_ocid: ocid1.tenancy.oc1..<bwire-tenancy>
  region: <bwire-region>
  compartment_ocid: ocid1.compartment.oc1..<bwire-compartment>
  vcn_cidr: 10.0.0.0/16
  enable_ipv6: true
  auth_method: SecurityToken
EOF
aws s3 cp /tmp/bwire-auth.yaml \
  "s3://cluster-tofu-state/production/inventory/oracle/bwire/auth.yaml" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1
```

- [ ] **PRE-4: Pre-stage R2 inventory `production/inventory/oracle/bwire/nodes.yaml`** with both VMs.

```yaml
nodes:
  oci-bwire-omni:
    role: omni
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 90
    labels: {}
    annotations:
      node.antinvestor.io/operator-note: "omni-host (not a cluster member)"
  oci-bwire-node-1:
    role: controlplane
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 90
    labels:
      node.antinvestor.io/plane: control-plane
      node.kubernetes.io/external-load-balancer: "false"
    annotations:
      node.antinvestor.io/operator-note: "control-plane"
```
Upload via `aws s3 cp` like PRE-4.

- [ ] **PRE-5: Update R2 inventory for existing accounts** (in-place mutations):
  - `production/inventory/contabo/bwire/nodes.yaml`:
    - `bwire-1`: `role: controlplane → worker`. LB: keep `true`.
    - `bwire-2`: `role: controlplane → worker`. LB: `true → false`.
    - Add `bwire-3` entry: `role: worker`, `product_id: V94`, `region: EU`, `labels: {node.antinvestor.io/plane: worker, node.kubernetes.io/external-load-balancer: "false"}`.
  - `production/inventory/oracle/alimbacho67/nodes.yaml`: LB `false → true`. Role already worker.
  - `production/inventory/oracle/brianelvis33/nodes.yaml`: ensure LB `true` (verify on read).

Use `aws s3 cp` to fetch each, hand-edit, re-upload with same path.

- [ ] **PRE-6: Bump `force_reinstall_generation`** in:
  - `tofu/layers/01-contabo-infra/terraform.tfvars` (current 7 → 8)
  - `tofu/layers/02-oracle-infra/terraform.tfvars` (find current; +1)

This forces every Talos node onto a freshly-built image carrying the new SideroLink token after first apply post-merge.

---

## Implementation tasks

### Task 1 — Add `node.antinvestor.io/name` label to node modules

The label is the selector key for per-node ConfigPatches. Must land before the patches are applied.

**Files:**
- Modify: `tofu/modules/node-contabo/main.tf` (the `derived_labels` block ~line 92)
- Modify: `tofu/modules/node-oracle/main.tf` (the `derived_labels` block — symmetry; same selector pattern will be reused for OCI nodes later)

- [ ] **1.1 Edit `node-contabo/main.tf`** — add `"node.antinvestor.io/name" = var.name` inside the static-keys part of `derived_labels`, between `account` and the conditional role-key merge. Keep ordering alphabetical-ish (already not strictly alphabetical, just slot it in).

- [ ] **1.2 Edit `node-oracle/main.tf`** — same addition.

- [ ] **1.3 Validate**

```bash
cd tofu/layers/01-contabo-infra && tofu fmt -recursive ../../modules/node-contabo && tofu init -backend=false && tofu validate
cd ../02-oracle-infra && tofu fmt -recursive ../../modules/node-oracle && tofu init -backend=false && tofu validate
```
Expected: both `Success! The configuration is valid.`

- [ ] **1.4 Commit**

```bash
git add tofu/modules/node-contabo/main.tf tofu/modules/node-oracle/main.tf
git commit -m "node-{contabo,oracle}: add node.antinvestor.io/name to derived_labels

Selector key for per-machine ConfigPatches applied by sync-cluster-template."
```

---

### Task 2 — Create per-node ConfigPatch template

**Files:**
- Create: `tofu/shared/clusters/per-node-patches.yaml.tmpl`

- [ ] **2.1 Write the template**

Write the exact content to `tofu/shared/clusters/per-node-patches.yaml.tmpl`:

```yaml
# Per-machine ConfigPatch resource — applied via `omnictl apply` by
# the sync-cluster-template workflow, one resource per node that
# needs a machine-specific Talos patch (today: every Contabo node).
#
# `target_label_selectors` is an array of label-equality predicates;
# Omni binds the patch to whichever Machine carries ALL the listed
# labels. cluster=stawi plus per-node-name (synced by layer-03's
# machine-labels reconciler) ensures exactly one match.
#
# `data` carries the multi-doc Talos config patch verbatim. The
# rendered template is fed to `omnictl apply -f <path>` (omnictl
# rejects stdin in v1.7.x — must be a real file).
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: ${ID}
  labels:
    omni.sidero.dev/cluster: stawi
spec:
  target_label_selectors:
${TARGET_SELECTORS_BLOCK}
  data: |
${INDENTED_DATA}
```

The template is consumed by Bash (`envsubst`) in the workflow; it does NOT use OpenTofu `${...}` interpolation — Bash variable substitution suffices because the workflow runs the rendering, not tofu. The variables are (uppercase to match POSIX env-var convention; multi-line values are pre-indented by the workflow before substitution, so placeholders stay at column 0 in this template):
- `ID` — unique resource id (use `<cluster>-<nodename>-link`)
- `TARGET_SELECTORS_BLOCK` — pre-rendered YAML list-of-strings, multi-line, each line pre-indented to 4 spaces
- `INDENTED_DATA` — pre-rendered Talos patch body, multi-line, each line pre-indented to 4 spaces (so the `data: |` literal block is properly nested)

- [ ] **2.2 Commit**

```bash
git add tofu/shared/clusters/per-node-patches.yaml.tmpl
git commit -m "clusters: add per-node ConfigPatch template

Renders one ConfigPatches.omni.sidero.dev resource scoped by
cluster + node-name labels, carrying a Talos multi-doc patch."
```

---

### Task 3 — Re-add `contabo-bwire-node-3` to bootstrap instance IDs

**Files:**
- Modify: `tofu/shared/bootstrap/contabo-instance-ids.yaml`

- [ ] **3.1 Uncomment / re-add the entry**

Replace lines 15–17 (currently a comment) with:

```yaml
    contabo-bwire-node-3:
      contabo_instance_id: "202727781"
```

Result file:

```yaml
# (preserve existing header comment)
contabo:
  bwire:
    contabo-bwire-node-1:
      contabo_instance_id: "202727783"
    contabo-bwire-node-2:
      contabo_instance_id: "202727782"
    contabo-bwire-node-3:
      contabo_instance_id: "202727781"
```

- [ ] **3.2 Commit**

```bash
git add tofu/shared/bootstrap/contabo-instance-ids.yaml
git commit -m "bootstrap: re-adopt VPS 202727781 as contabo-bwire-node-3

Freed from old Contabo omni-host (now retired). 01-contabo-infra
imports the VPS via the existing imports.tf bootstrap path."
```

---

### Task 4 — Update cluster template for new topology

**Files:**
- Modify: `tofu/shared/clusters/main.yaml`

- [ ] **4.1 Update `Workers.machineClass.size`** to 5. Update inline comments to reflect the new node list (alimbacho67 + brianelvis33 + bwire-1 + bwire-2 + bwire-3) and the LB targeting (alimbacho67, brianelvis33, contabo-bwire-1).

In `tofu/shared/clusters/main.yaml`, find the `kind: Workers` block (around line 196) and change:

```yaml
machineClass:
  name: workers
  size: 3
```

to:

```yaml
machineClass:
  name: workers
  size: 5
```

Update the comment block above (lines ~177-195) to reflect the new architecture: 5 workers (3 Contabo bwire + alimbacho67 + brianelvis33), single CP at `oci-bwire-node-1` (NEW). Reference the per-node ConfigPatches that Contabo workers receive.

- [ ] **4.2 Validate by `omnictl cluster template validate`** (optional; requires omnictl + creds — can defer to CI)

```bash
omnictl cluster template validate -f tofu/shared/clusters/main.yaml
```
Expected: success.

- [ ] **4.3 Commit**

```bash
git add tofu/shared/clusters/main.yaml
git commit -m "clusters: Workers size 5 — Contabo {1,2,3} + alimbacho67 + brianelvis33

ControlPlane stays size 1; sole CP is the new oci-bwire-node-1."
```

---

### Task 5 — Scaffold `omni-host-oci` module (skeleton + variables)

The module mirrors the existing `tofu/modules/omni-host/` shape but uses OCI primitives. We split it into 6 files so each task is bite-sized.

**Files:**
- Create: `tofu/modules/omni-host-oci/versions.tf`
- Create: `tofu/modules/omni-host-oci/variables.tf`
- Create: `tofu/modules/omni-host-oci/outputs.tf` (skeleton; populated in Task 10)

- [ ] **5.1 Write `versions.tf`**

```hcl
terraform {
  required_providers {
    oci      = { source = "oracle/oci", version = "~> 6.0" }
    random   = { source = "hashicorp/random" }
  }
  required_version = ">= 1.7.0"
}
```

- [ ] **5.2 Write `variables.tf`**

Copy the existing `tofu/modules/omni-host/variables.tf` (~265 lines) verbatim, then make these substitutions in the new file:
- DELETE: `contabo_product_id`, `contabo_image_id`, `contabo_region`, `contabo_client_id`, `contabo_client_secret`, `contabo_api_user`, `contabo_api_password` variables.
- DELETE: the `force_reinstall_generation` variable (OCI's `oci_core_instance` natively replaces on `metadata.user_data` change; no equivalent of the Contabo PUT-reinstall script needed).
- ADD: OCI compute variables:

```hcl
variable "compartment_ocid" {
  type        = string
  description = "OCID of the bwire compartment that owns the omni-host VM, VCN, and reserved IP."
}

variable "availability_domain" {
  type        = string
  description = "OCI availability-domain name for the VM (e.g. 'AD-1' or full FQDN). VM.Standard.A1.Flex requires AD-with-A1-capacity."
}

variable "shape" {
  type        = string
  default     = "VM.Standard.A1.Flex"
  description = "OCI compute shape. A1.Flex is ARM Always-Free."
}

variable "ocpus" {
  type        = number
  default     = 2
}

variable "memory_gb" {
  type        = number
  default     = 12
}

variable "boot_volume_size_gb" {
  type        = number
  default     = 90
  description = "OCI Always-Free block volume budget is 200 GB per tenancy; 2 omni-host VMs at 90 GB plus the cluster CP fits."
}

variable "ubuntu_image_ocid" {
  type        = string
  description = "OCI Ubuntu 24.04 LTS Minimal aarch64 image OCID. Looked up by the caller via oci_core_images data source."
}

variable "vcn_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "Dedicated VCN CIDR for the omni-host. Separate from oracle-account-infra's cluster-node VCN to keep blast radius small."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.42.1.0/24"
}

variable "enable_ipv6" {
  type        = bool
  default     = true
}
```

- KEEP: every other variable (omni_version, dex_version, name, omni_account_name, siderolink_*, github_oidc_*, cf_dns_api_token, ssh_authorized_keys, ssh_enabled, r2_*, etcd_backup_enabled, vpn_users, eula_*, initial_users).

- [ ] **5.3 Write `outputs.tf` skeleton**

```hcl
output "instance_id" {
  value = oci_core_instance.this.id
}

output "ipv4" {
  description = "Reserved public IPv4 attached to the omni-host VNIC."
  value       = oci_core_public_ip.this.ip_address
}

output "ipv6" {
  description = "First IPv6 address assigned to the omni-host VNIC. Stable while the instance lives."
  value       = try(data.oci_core_vnic.this.ipv6addresses[0], null)
}
```

- [ ] **5.4 Validate**

```bash
cd tofu/modules/omni-host-oci
tofu fmt -recursive .
tofu init -backend=false
# tofu validate would fail without main.tf — defer to Task 7.
```

- [ ] **5.5 Commit**

```bash
git add tofu/modules/omni-host-oci/versions.tf tofu/modules/omni-host-oci/variables.tf tofu/modules/omni-host-oci/outputs.tf
git commit -m "omni-host-oci: scaffold module (versions, variables, outputs skeleton)

OCI substrate variant of omni-host. Mirrors the Contabo module's
input shape minus Contabo-only knobs; adds OCI compartment/AD/shape
+ VCN/subnet defaults inside the bwire tenancy."
```

---

### Task 6 — `omni-host-oci`: networking (VCN, subnet, security list, reserved IP)

**Files:**
- Create: `tofu/modules/omni-host-oci/network.tf`

- [ ] **6.1 Write `network.tf`**

```hcl
# Dedicated VCN for the omni-host. Separate from the cluster-node
# VCN (oracle-account-infra creates that one) so the omni-host's
# blast radius stays narrow and the security-list inbound surface
# can be tighter than what cluster nodes need.
resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name}-vcn"
  is_ipv6enabled = var.enable_ipv6
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

# Inbound: 80/443 (Omni UI via CF), 8090 (SideroLink API), 8100
# (k8s-proxy), 50180/UDP (SideroLink WG), 51820/UDP (admin WG).
# Outbound: all.
resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination = "::/0"
      protocol    = "all"
    }
  }

  # TCP ingress: 80, 443, 8090, 8100
  dynamic "ingress_security_rules" {
    for_each = toset(["80", "443", "8090", "8100"])
    content {
      protocol = "6" # TCP
      source   = "0.0.0.0/0"
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  # UDP ingress: 50180 (SideroLink WG), 51820 (admin WG)
  dynamic "ingress_security_rules" {
    for_each = toset(["50180", "51820"])
    content {
      protocol = "17" # UDP
      source   = "0.0.0.0/0"
      udp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  # IPv6 mirrors of the same rules
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? toset(["80", "443", "8090", "8100"]) : []
    content {
      protocol = "6"
      source   = "::/0"
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? toset(["50180", "51820"]) : []
    content {
      protocol = "17"
      source   = "::/0"
      udp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.this.id
  cidr_block          = var.subnet_cidr
  display_name        = "${var.name}-subnet"
  route_table_id      = oci_core_route_table.this.id
  security_list_ids   = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false

  dynamic "ipv6cidr_blocks" {
    for_each = var.enable_ipv6 ? [oci_core_vcn.this.ipv6cidr_blocks[0]] : []
    content {}
  }
  ipv6cidr_blocks = var.enable_ipv6 ? [oci_core_vcn.this.ipv6cidr_blocks[0]] : null
}

# Reserved public IPv4 — survives instance recreate. AAAA records
# point at the instance-attached IPv6 (which is stable while the
# instance lives — see spec risk table).
resource "oci_core_public_ip" "this" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.name}-pubip"
  private_ip_id  = data.oci_core_private_ips.this.private_ips[0].id
}

# Look up the VNIC's primary private IP — needed to attach the
# reserved public IP. Re-evaluated on every plan.
data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_vnic" "this" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "this" {
  vnic_id = data.oci_core_vnic.this.id
}
```

- [ ] **6.2 Validate**

```bash
cd tofu/modules/omni-host-oci
tofu fmt -recursive .
# Full validate after main.tf lands in Task 7.
```

- [ ] **6.3 Commit**

```bash
git add tofu/modules/omni-host-oci/network.tf
git commit -m "omni-host-oci: networking — dedicated VCN, security list, reserved IPv4

Inbound: 80/443/8090/8100 TCP + 50180/51820 UDP. SSH (22) NOT
exposed — admin path is via the 51820 WG VPN. Reserved IPv4 +
instance-attached IPv6."
```

---

### Task 7 — `omni-host-oci`: compute (instance + cloud-init wiring)

**Files:**
- Create: `tofu/modules/omni-host-oci/main.tf`
- Create: `tofu/modules/omni-host-oci/cloud-init.yaml.tftpl` (copy from existing, then patch)
- Create: `tofu/modules/omni-host-oci/docker-compose.yaml.tftpl` (verbatim copy from existing)

- [ ] **7.1 Copy + adapt cloud-init template**

```bash
cp tofu/modules/omni-host/cloud-init.yaml.tftpl tofu/modules/omni-host-oci/cloud-init.yaml.tftpl
```

Apply these edits in the OCI variant:
1. Remove the long Contabo-bootcmd warning comment block (the part starting "Note: Contabo's image agent appends..." through "fail2ban guards the public port. Break-glass: Contabo serial console.").
2. Update the `apt.sources.docker` source line — change `arch=amd64` to `arch=arm64` (A1.Flex is ARM):
   ```yaml
   apt:
     sources:
       docker:
         source: "deb [arch=arm64 signed-by=$KEY_FILE] https://download.docker.com/linux/ubuntu noble stable"
         keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
   ```
3. SSH lockdown — adjust the `users` / `disable_root` / sshd drop-in section to default to **public-SSH off**. The Contabo version had a toggle (`var.ssh_enabled`) for a phased lockdown; on OCI we go straight to lockdown:
   - Set `disable_root: true`
   - Drop the `ssh_authorized_keys` block on root entirely
   - Add a static sshd drop-in `/etc/ssh/sshd_config.d/99-stawi.conf` with:
     ```
     PermitRootLogin no
     PasswordAuthentication no
     # Bind only on the WG interface — admin reachable solely via WG VPN.
     ListenAddress 10.100.0.1
     ```
   - Drop the iptables/nftables OCI-firewall blob; OCI security list (Task 6) is the firewall.
4. Verify all `${var.foo}` template references still resolve — none of the deleted variables (Contabo-specific) appear in cloud-init, so no breakage.

- [ ] **7.2 Copy docker-compose template verbatim**

```bash
cp tofu/modules/omni-host/docker-compose.yaml.tftpl tofu/modules/omni-host-oci/docker-compose.yaml.tftpl
```

No edits — the docker-compose is substrate-agnostic (Omni / Dex / Caddy publish multi-arch images; arm64 vs amd64 selection is handled by Docker at pull time).

- [ ] **7.3 Write `main.tf`**

```hcl
# tofu/modules/omni-host-oci/main.tf
#
# Single OCI ARM A1.Flex VM running Omni + Dex + Caddy via
# docker-compose. All configuration declarative via cloud-init.
# OCI substrate variant of tofu/modules/omni-host (Contabo).
#
# Replacement triggers: oci_core_instance natively recreates on
# user_data change (provider-default lifecycle). No
# null_resource.ensure_image equivalent needed — the OCI provider
# does what Contabo's PUT script approximated.

resource "random_uuid" "omni_account_id" {
  lifecycle { ignore_changes = [keepers] }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle { ignore_changes = [length, special] }
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
      etcd_backup_enabled                  = var.etcd_backup_enabled
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
      r2_account_id                        = var.r2_account_id
      r2_access_key_id                     = var.r2_access_key_id
      r2_secret_access_key                 = var.r2_secret_access_key
      r2_bucket_name                       = var.r2_bucket_name
      r2_backup_prefix                     = var.r2_backup_prefix
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

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.shape
  display_name        = var.name

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = var.ubuntu_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = false  # Reserved IP attached separately (see network.tf).
    assign_ipv6ip    = var.enable_ipv6
    hostname_label   = replace(var.name, "_", "-")
  }

  metadata = {
    user_data = base64encode(local.user_data)
  }

  preserve_boot_volume = false
}

# Block downstream layers on omni stack readiness post-apply, so any
# follow-on layer that does omnictl operations doesn't race a still-
# booting Omni. Polls /healthz on the public hostname.
resource "null_resource" "wait_for_omni_ready" {
  depends_on = [oci_core_instance.this, oci_core_public_ip.this]

  triggers = {
    instance_id = oci_core_instance.this.id
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
```

- [ ] **7.4 Validate**

```bash
cd tofu/modules/omni-host-oci
tofu fmt -recursive .
tofu init -backend=false
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **7.5 Commit**

```bash
git add tofu/modules/omni-host-oci/main.tf tofu/modules/omni-host-oci/cloud-init.yaml.tftpl tofu/modules/omni-host-oci/docker-compose.yaml.tftpl
git commit -m "omni-host-oci: compute + cloud-init + docker-compose

ARM A1.Flex VM, declarative cloud-init, SSH-public-disabled
(admin via WG only), 10-minute /healthz wait-gate post-apply."
```

---

### Task 8 — Create shared `oci-operator-csk.tf`, delete old per-service IAM files

**Files:**
- Create: `tofu/layers/02-oracle-infra/oci-operator-csk.tf`
- Delete: `tofu/layers/02-oracle-infra/omni-backup-iam.tf`
- Delete: `tofu/layers/02-oracle-infra/cluster-image-uploader-iam.tf`

- [ ] **8.1 Write `oci-operator-csk.tf`**

```hcl
# tofu/layers/02-oracle-infra/oci-operator-csk.tf
#
# bwire-only Customer Secret Key, minted against the existing
# operator user (looked up by name via data.oci_identity_user). All
# OCI S3-compat consumers use this single CSK:
#   - omni-host's --etcd-backup-s3 flag (writes to omni-backup-storage)
#   - regenerate-talos-images workflow (writes Talos images to
#     cluster-image-registry)
#   - sync-cluster-template's EtcdBackupS3Configs render
#
# Replaces the per-service users (omni-backup-writer,
# cluster-image-uploader). Trade-off documented in the spec at
# docs/superpowers/specs/2026-05-02-omni-oci-realignment-design.md.

variable "oci_operator_user_name" {
  type        = string
  description = "Name of the existing OCI operator user in the bwire tenancy. CSK minted against this user."
  default     = "" # Set in terraform.tfvars per-account override.
}

data "oci_identity_users" "bwire_operator" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = var.oci_operator_user_name
}

resource "oci_identity_customer_secret_key" "bwire_operator" {
  count        = local.is_bwire ? 1 : 0
  provider     = oci.account[var.account_key]
  user_id      = data.oci_identity_users.bwire_operator[0].users[0].id
  display_name = "stawi-cluster-s3-compat"
}

# Output preserves the field shape that sync-cluster-template.yml
# already reads (omni_backup_writer_credentials), so the workflow
# needs no rename. Both `cluster-image-registry` (writes from
# regenerate-talos-images) and `omni-backup-storage` (writes from
# omni-host's --etcd-backup-s3) auth via the same CSK.
output "omni_backup_writer_credentials" {
  description = "S3-compat credentials (single CSK) for OCI bwire object storage. Used by omni-host etcd-backup, regenerate-talos-images uploads, and sync-cluster-template's EtcdBackupS3Configs render."
  sensitive   = true
  value = local.is_bwire ? {
    access_key_id     = oci_identity_customer_secret_key.bwire_operator[0].id
    secret_access_key = oci_identity_customer_secret_key.bwire_operator[0].key
    bucket            = oci_objectstorage_bucket.omni_backup_storage[0].name
    region            = local.oci_accounts_effective[var.account_key].region
    endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}
```

**Note**: the CSK is created fresh by the first apply (no manual mint, no `import` block). The `oci_identity_customer_secret_key` resource creates a NEW CSK on the operator user — OCI permits up to 2 CSKs per user, so this coexists with any pre-existing one. After apply, the CSK access_key_id + secret_access_key are in tfstate (sensitive); downstream consumers (`sync-cluster-template.yml`, `regenerate-talos-images.yml`, the omni-host module) read from tfstate directly via the same `aws s3 cp` + `jq` pattern that already exists in `sync-cluster-template.yml` for `omni_backup_writer_credentials`. No GH Actions secret update needed.

- [ ] **8.2 Delete old IAM files**

```bash
git rm tofu/layers/02-oracle-infra/omni-backup-iam.tf
git rm tofu/layers/02-oracle-infra/cluster-image-uploader-iam.tf
```

- [ ] **8.3 Update terraform.tfvars** to pass `oci_operator_user_name` for the bwire cell. The `02-oracle-infra` layer already runs as a per-account matrix; add the variable to the matrix dispatch (likely in `.github/workflows/tofu-apply.yml` or a sibling per-account tfvars file). Inspect `tofu/layers/02-oracle-infra/terraform.tfvars` and add a per-account default if the workflow auto-injects `account_key`. Operator-edit-required step: set the actual operator user name.

- [ ] **8.4 Validate**

```bash
cd tofu/layers/02-oracle-infra
tofu fmt
tofu init -backend=false
tofu validate
```
Expected: `Success!`

- [ ] **8.5 Commit**

```bash
git add tofu/layers/02-oracle-infra/oci-operator-csk.tf tofu/layers/02-oracle-infra/terraform.tfvars
git rm tofu/layers/02-oracle-infra/omni-backup-iam.tf tofu/layers/02-oracle-infra/cluster-image-uploader-iam.tf
git commit -m "02-oracle-infra: collapse OCI IAM onto operator user

Single CSK on the existing bwire operator user replaces per-service
omni-backup-writer + cluster-image-uploader users. Output shape
preserved (omni_backup_writer_credentials) so consumers don't churn.
First-apply runs an operator 'tofu import' on the manually-minted
CSK; subsequent applies are no-ops."
```

---

### Task 9 — Flip `cluster-image-registry` bucket gate alimbacho67 → bwire

**Files:**
- Modify: `tofu/layers/02-oracle-infra/image-registry.tf`

- [ ] **9.1 Edit `image-registry.tf`**

In the existing file (read it first):
- Move the `cluster_image_registry` bucket resource block (currently in the `is_alimbacho67` section) into the `is_bwire` section.
- Change every `local.is_alimbacho67` reference inside that block to `local.is_bwire`.
- Change the namespace data-source reference from `data.oci_objectstorage_namespace.alimbacho67[0].namespace` to `data.oci_objectstorage_namespace.bwire[0].namespace`.
- Update the `output "cluster_image_registry"` block likewise — gate to `is_bwire`, namespace to bwire.
- Delete the now-empty `data.oci_objectstorage_namespace.alimbacho67` block (alimbacho67 has no buckets after this).
- Update the file-header comment table:
  ```
  bwire   cluster-image-registry   public  Talos images
  bwire   cluster-state-storage    private tofu state files
  bwire   cluster-vault-storage    private SOPS-encrypted secrets
  bwire   omni-backup-storage      private Omni etcd backups
  ```

- [ ] **9.2 Validate**

```bash
cd tofu/layers/02-oracle-infra
tofu fmt
tofu init -backend=false
tofu validate
```
Expected: `Success!`

- [ ] **9.3 Commit**

```bash
git add tofu/layers/02-oracle-infra/image-registry.tf
git commit -m "image-registry: move cluster-image-registry bucket alimbacho67 → bwire

All OCI buckets now live in the bwire tenancy. alimbacho67's bucket
is destroyed by the apply (greenfield posture; regenerate-talos-images
repopulates the new bwire bucket on its next run)."
```

---

### Task 10 — Rewire `00-omni-server` onto `omni-host-oci`

**Files:**
- Modify: `tofu/layers/00-omni-server/main.tf`
- Modify: `tofu/layers/00-omni-server/variables.tf`
- Modify: `tofu/layers/00-omni-server/terraform.tfvars`
- Modify: `tofu/layers/00-omni-server/outputs.tf`

- [ ] **10.1 Add `terraform_remote_state` for bwire 02-oracle-infra**

Append to `00-omni-server/main.tf` (BEFORE the existing `module "omni_host"` block):

```hcl
# Read bwire's CSK + bucket info — minted by 02-oracle-infra/bwire's
# oci-operator-csk.tf. Crosses layer boundaries via tfstate to avoid
# leaking the secret through tfvars.
data "terraform_remote_state" "bwire_oracle" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-oracle-infra-bwire.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# Read bwire OCI auth — same R2-backed pattern 02-oracle-infra uses.
module "bwire_account_state" {
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = "bwire"
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = "/tmp/inventory"
}

provider "oci" {
  alias               = "bwire"
  tenancy_ocid        = module.bwire_account_state.auth.auth.tenancy_ocid
  region              = module.bwire_account_state.auth.auth.region
  config_file_profile = "bwire"
  auth                = "SecurityToken"
}

# Look up Ubuntu 24.04 LTS aarch64 in the bwire region — needed for
# the omni-host VM's source_id.
data "oci_core_images" "ubuntu_aarch64" {
  provider                 = oci.bwire
  compartment_id           = module.bwire_account_state.auth.auth.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}
```

- [ ] **10.2 Replace `module "omni_host"` block with `module "omni_host_oci"`**

Delete the existing Contabo `module "omni_host"` block (lines 60–115 in `00-omni-server/main.tf`) AND the `import { id = "202727781" }` block (lines 55–58). Replace both with:

```hcl
module "omni_host_oci" {
  source    = "../../modules/omni-host-oci"
  providers = { oci = oci.bwire }

  name                                 = "oci-bwire-omni"
  compartment_ocid                     = module.bwire_account_state.auth.auth.compartment_ocid
  availability_domain                  = var.bwire_availability_domain
  ubuntu_image_ocid                    = data.oci_core_images.ubuntu_aarch64.images[0].id
  enable_ipv6                          = try(module.bwire_account_state.auth.auth.enable_ipv6, true)

  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  cf_dns_api_token                     = var.cloudflare_api_token
  initial_users                        = [for e in split(",", var.omni_initial_users) : trimspace(e) if trimspace(e) != ""]
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email

  # Etcd backup credentials come from the bwire tfstate's
  # omni_backup_writer_credentials output — same field shape as
  # under the old per-service-user setup.
  r2_account_id        = var.r2_account_id
  r2_access_key_id     = var.r2_access_key_id
  r2_secret_access_key = var.r2_secret_access_key

  etcd_backup_enabled = var.etcd_backup_enabled

  vpn_users = var.vpn_users

  # SSH stays HARD off on OCI omni-host. There is no toggle — admin
  # path is the WireGuard VPN listener (UDP 51820).
  ssh_authorized_keys = []
}
```

- [ ] **10.3 Update DNS records to read from `omni_host_oci`**

In the same `00-omni-server/main.tf`, find each `cloudflare_dns_record` resource (cp_stawi, cpd_stawi, cp_stawi_v6, cpd_stawi_v6) and change `module.omni_host.ipv4` / `module.omni_host.ipv6` to `module.omni_host_oci.ipv4` / `module.omni_host_oci.ipv6`. Same for the `count = module.omni_host.ipv6 == null ? 0 : 1` predicates.

- [ ] **10.4 Update `variables.tf`**

In `00-omni-server/variables.tf`:
- DELETE: `force_reinstall_generation`, `contabo_public_ssh_key`, `omni_host_ssh_enabled`, any other Contabo-specific knobs.
- ADD:

```hcl
variable "bwire_availability_domain" {
  type        = string
  description = "OCI AD name (e.g. 'foo:US-ASHBURN-AD-1' or short-form 'AD-1') for bwire's omni-host VM. Pick an AD that has A1.Flex capacity in your region."
}
```

- [ ] **10.5 Update `terraform.tfvars`**

In `00-omni-server/terraform.tfvars`:
- DELETE: `force_reinstall_generation`, `etcd_backup_enabled` lines (etcd_backup_enabled stays as a var but moves to a different default — see below).
- ADD: `bwire_availability_domain = "<set-by-operator>"` with a comment instructing the operator to fill in the AD before merge.
- Re-add `etcd_backup_enabled = true` (default).

- [ ] **10.6 Update `outputs.tf`**

Replace any `module.omni_host.*` output references with `module.omni_host_oci.*`.

- [ ] **10.7 Validate**

```bash
cd tofu/layers/00-omni-server
tofu fmt
tofu init -backend=false
tofu validate
```
Expected: `Success!`

- [ ] **10.8 Commit**

```bash
git add tofu/layers/00-omni-server/{main.tf,variables.tf,terraform.tfvars,outputs.tf}
git commit -m "00-omni-server: switch to omni-host-oci on bwire OCI

Drop Contabo VPS import; new module creates an A1.Flex VM in the
bwire tenancy. DNS cp/cpd retarget to the OCI VM's reserved IPv4 +
instance-attached IPv6. SSH hard-off; admin via WG only."
```

---

### Task 11 — Re-adopt VPS 202727781 in `01-contabo-infra`

VPS 202727781 was managed by the Contabo `omni-host` module. After Task 10 strips that import, the VPS is unmanaged. `01-contabo-infra/imports.tf` needs to adopt it back as `contabo-bwire-node-3`.

**Files:**
- (No code changes needed if Tasks 3 + 10 are correct — `imports.tf` already reads `bootstrap-instance-ids.yaml` which Task 3 re-populates with the bwire-3 entry. Verify only.)
- Modify: `tofu/shared/clusters/main.yaml` (already done in Task 4 — verify Workers size 5)

- [ ] **11.1 Verify import path**

```bash
grep -A3 "contabo-bwire-node-3" tofu/shared/bootstrap/contabo-instance-ids.yaml
grep -A5 "for_each = local.contabo_existing_instance_ids" tofu/layers/01-contabo-infra/imports.tf
```
Expected: bwire-3 entry present in YAML; `imports.tf` for_each iterates over `local.contabo_existing_instance_ids` which merges the bootstrap file.

- [ ] **11.2 Plan-only check (sandboxed)**

```bash
cd tofu/layers/01-contabo-infra
tofu fmt
tofu validate
```
Expected: validate passes. Plan would require live R2 + Contabo creds; defer to CI.

- [ ] **11.3 Commit (only if any change made)**

If anything is touched: commit. Otherwise skip.

---

### Task 12 — Flip `talos-images.yaml` OCI URL prefix to bwire

**Files:**
- Modify: `tofu/shared/inventory/talos-images.yaml`

- [ ] **12.1 Edit URL prefixes**

Read the file. Find every `objectstorage.<region>.oraclecloud.com/n/<alimbacho67-namespace>/b/cluster-image-registry/o/...` URL and replace `<alimbacho67-namespace>` with `<bwire-namespace>`. The `<region>` may also change if bwire is in a different OCI region.

The exact namespace strings and region are operator-known (look up via `oci os ns get --profile bwire`). Document in the commit message which namespace was substituted.

- [ ] **12.2 Commit**

```bash
git add tofu/shared/inventory/talos-images.yaml
git commit -m "talos-images: flip OCI URL prefix to bwire cluster-image-registry

Source bucket moves from alimbacho67 to bwire (see Task 9 / spec).
Image objects don't yet exist in bwire — regenerate-talos-images
populates them on its next run after this PR merges."
```

---

### Task 13 — Update `regenerate-talos-images.yml` workflow

**Files:**
- Modify: `.github/workflows/regenerate-talos-images.yml`

- [ ] **13.1 Read the existing workflow**

```bash
cat .github/workflows/regenerate-talos-images.yml
```

- [ ] **13.2 Edit upload destination**

Find the OCI upload step(s). Replace any `s3://cluster-image-registry/...` endpoint pointing at alimbacho67's S3-compat URL with bwire's. CSK env vars come from the same GH secrets (`OCI_BWIRE_S3_ACCESS_KEY_ID` + `OCI_BWIRE_S3_SECRET_ACCESS_KEY`); alimbacho67-specific CSK secrets (if any) should be removed from the workflow's env block.

- [ ] **13.3 Drop alimbacho67 dual-write** (if the workflow currently dual-writes to R2 + alimbacho67 OCI per PR #148)

Remove the alimbacho67 upload steps. Keep R2 writes for now (no impact; R2 bucket can be retired later with the cluster-tofu-state migration in Track B).

- [ ] **13.4 Add SideroLink-token-readiness precondition**

Before any image-build step runs, add:

```yaml
      - name: Wait for new SideroLink token
        run: |
          set -euo pipefail
          deadline=$(( $(date +%s) + 300 ))
          while :; do
            api=$(omnictl get connectionparams -o json 2>/dev/null \
              | jq -r '.spec.api_endpoint // empty')
            if [[ "$api" == "https://cpd.stawi.org" ]]; then
              echo "::notice::SideroLink token ready, api_endpoint=$api"
              break
            fi
            if [[ $(date +%s) -ge $deadline ]]; then
              echo "::error::Timed out waiting for SideroLink api_endpoint to settle on cpd.stawi.org (last value: '$api')"
              exit 1
            fi
            sleep 10
          done
```

This guards against the spec's "regen-images runs before omni-host has token" race.

- [ ] **13.5 Validate workflow**

```bash
actionlint .github/workflows/regenerate-talos-images.yml || echo "actionlint not installed — manual review only"
```

- [ ] **13.6 Commit**

```bash
git add .github/workflows/regenerate-talos-images.yml
git commit -m "regenerate-talos-images: upload to bwire cluster-image-registry

Drop alimbacho67 dual-write. Add SideroLink-token-readiness gate
that waits for the new omni-host's api_endpoint to settle on
cpd.stawi.org before building images."
```

---

### Task 14 — Add per-node ConfigPatch render+apply step in `sync-cluster-template.yml`

**Files:**
- Modify: `.github/workflows/sync-cluster-template.yml`

- [ ] **14.1 Add new workflow step**

Insert AFTER the existing `Apply EtcdBackupS3Configs` step and BEFORE the `Validate template` step:

```yaml
      # Render + apply per-node ConfigPatches for Contabo nodes.
      # Reads each Contabo tfstate's `nodes` output, renders the
      # node-contabo.tftpl patch with that node's IPv4/IPv6/gateway/
      # hostname, wraps it in a ConfigPatches.omni.sidero.dev resource
      # label-targeted by node.antinvestor.io/name=<n>, and applies.
      #
      # Why this lives here (not in tofu): per-machine patches are
      # cluster spec, not infrastructure. Tofu owns provisioning;
      # cluster-template.yml + this workflow own everything Omni
      # consumes. Same boundary as etcd-backup-s3-configs.
      - name: Apply per-node ConfigPatches (Contabo)
        if: env.DRY_RUN != 'true'
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          AWS_EC2_METADATA_DISABLED: "true"
          R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
        run: |
          set -euo pipefail
          ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT

          # accounts.yaml lists every contabo account; iterate.
          mapfile -t accounts < <(yq -r '.contabo[]' tofu/shared/accounts.yaml)

          for acct in "${accounts[@]}"; do
            STATE_KEY="production/01-contabo-infra-${acct}.tfstate"
            if ! aws s3api head-object --bucket cluster-tofu-state --key "$STATE_KEY" \
                 --endpoint-url "$ENDPOINT" --region us-east-1 >/dev/null 2>&1; then
              echo "::notice::contabo/$acct tfstate not found — skipping per-node patches for this account."
              continue
            fi
            state="$tmp/${acct}.tfstate"
            aws s3 cp "s3://cluster-tofu-state/$STATE_KEY" "$state" \
              --endpoint-url "$ENDPOINT" --region us-east-1 >/dev/null

            # Iterate every node in this account's `nodes` output.
            mapfile -t nodes < <(jq -r '.outputs.nodes.value | keys[]' "$state")
            for n in "${nodes[@]}"; do
              ipv4=$(jq -r ".outputs.nodes.value[\"$n\"].ipv4" "$state")
              ipv6=$(jq -r ".outputs.nodes.value[\"$n\"].ipv6 // empty" "$state")
              [[ -z "$ipv4" ]] && { echo "::warning::no ipv4 for $n; skipping"; continue; }

              # Derive gateways from IP. Contabo convention: /24 for
              # IPv4 with gateway = first three octets + .1; /64 for
              # IPv6 with gateway = subnet + ::1. ipv6_subnet is the
              # /64 prefix used in kubelet.nodeIP.validSubnets.
              ipv4_gateway=$(awk -F. '{print $1"."$2"."$3".1"}' <<<"$ipv4")
              if [[ -n "$ipv6" ]]; then
                ipv6_prefix=$(awk -F: '{print $1":"$2":"$3":"$4}' <<<"$ipv6")
                ipv6_gateway="${ipv6_prefix}::1"
                ipv6_subnet="${ipv6_prefix}::/64"
              else
                ipv6_gateway=""; ipv6_subnet=""
              fi

              # Render the Talos patch body.
              patch_body=$(IPV4="$ipv4" IPV6="$ipv6" \
                IPV4_GATEWAY="$ipv4_gateway" IPV6_GATEWAY="$ipv6_gateway" \
                IPV6_SUBNET="$ipv6_subnet" HOSTNAME="$n" \
                envsubst < tofu/shared/patches/node-contabo.tftpl)

              # Wrap in ConfigPatch resource.
              indented_data=$(sed 's/^/    /' <<<"$patch_body")
              targets=$(printf '    - "node.antinvestor.io/name=%s"\n' "$n")

              ID="stawi-${n}-link" \
              TARGET_SELECTORS_BLOCK="$targets" \
              INDENTED_DATA="$indented_data" \
                envsubst < tofu/shared/clusters/per-node-patches.yaml.tmpl \
                > "$tmp/${n}.yaml"

              omnictl apply -f "$tmp/${n}.yaml"
            done
          done
```

The `tofu/shared/patches/node-contabo.tftpl` source file currently uses `${var}` placeholders (Bash-substitutable form via envsubst — no real OpenTofu interpolation). Verify by reading the file: variables are `${ipv4}`, `${ipv6}`, `${ipv4_gateway}`, `${ipv6_gateway}`, `${ipv6_subnet}`, `${hostname}`. The envsubst above sets matching uppercase env vars — **adjust the case** to match. Either:
- (a) Edit `node-contabo.tftpl` to use uppercase placeholders (`${IPV4}` etc.) — easier, cleaner.
- (b) Lowercase the env vars in the workflow.

Pick (a) — the template is currently never rendered at runtime by tofu, so changing the case is safe.

- [ ] **14.2 Adjust `tofu/shared/patches/node-contabo.tftpl` to uppercase placeholders**

```bash
sed -i 's/${ipv4_gateway}/${IPV4_GATEWAY}/g;
        s/${ipv6_gateway}/${IPV6_GATEWAY}/g;
        s/${ipv6_subnet}/${IPV6_SUBNET}/g;
        s/${ipv4}/${IPV4}/g;
        s/${ipv6}/${IPV6}/g;
        s/${hostname}/${HOSTNAME}/g' tofu/shared/patches/node-contabo.tftpl
```

- [ ] **14.3 Validate workflow**

```bash
actionlint .github/workflows/sync-cluster-template.yml || echo "actionlint not installed — manual review only"
```

- [ ] **14.4 Commit**

```bash
git add .github/workflows/sync-cluster-template.yml tofu/shared/patches/node-contabo.tftpl
git commit -m "sync-cluster-template: render+apply per-node ConfigPatches for Contabo

Reads each Contabo tfstate's nodes output, renders the
node-contabo.tftpl Talos patch with that node's IPv4/IPv6/
gateway/hostname, wraps in ConfigPatches.omni.sidero.dev with
per-node label selector, and applies via omnictl. Fixes the apid
bind issue that's been blocking Contabo workers."
```

---

### Task 15 — Delete `tofu/modules/omni-host/`

**Files:**
- Delete: `tofu/modules/omni-host/` (entire directory)

- [ ] **15.1 Verify nothing references the old module**

```bash
grep -rn "modules/omni-host\b" tofu/ | grep -v "modules/omni-host-oci\|modules/omni-host/" || echo "no remaining references"
grep -rn 'source.*= *"\.\./\.\./modules/omni-host"' tofu/ || echo "no remaining sources"
```
Expected: no remaining references (Task 10 should have flipped them all).

- [ ] **15.2 Delete the directory**

```bash
git rm -r tofu/modules/omni-host
```

- [ ] **15.3 Commit**

```bash
git commit -m "modules: drop omni-host (Contabo substrate retired)

Replaced by tofu/modules/omni-host-oci. Contabo VPS 202727781
freed; 01-contabo-infra re-adopts it as contabo-bwire-node-3."
```

---

### Task 16 — Spec / plan housekeeping + open PR

- [ ] **16.1 Run final repo-wide validate**

```bash
for layer in tofu/layers/*/; do
  echo "=== $layer ==="
  (cd "$layer" && tofu init -backend=false >/dev/null && tofu validate)
done
```
Expected: every layer passes.

- [ ] **16.2 Lint every workflow**

```bash
find .github/workflows -name '*.yml' -exec actionlint {} + 2>&1 || true
```

- [ ] **16.3 Push branch + open PR**

```bash
git push -u origin feat/omni-oci-realignment
gh pr create --title "Realign cluster: omni-host on OCI bwire, all Contabo as workers, single CP at oci-bwire-node-1" \
  --body "$(cat <<'EOF'
## Summary
Single-PR realignment per spec at `docs/superpowers/specs/2026-05-02-omni-oci-realignment-design.md` (commit 9293805).

- omni-host moves to OCI bwire (A1.Flex Always-Free; 2 OCPU / 12 GB / 90 GB)
- new sole CP `oci-bwire-node-1` (same shape) replaces the old single-CP-on-alimbacho67 placement
- Contabo bwire-{1,2,3} all become workers (bwire-3 freed from old omni-host)
- alimbacho67 / brianelvis33 already workers; LB labels updated per spec
- per-machine ConfigPatches wire `node-contabo.tftpl` into the cluster template via sync-cluster-template (fixes the apid bind issue)
- OCI IAM collapses onto the existing operator user; per-service IAM users deleted
- SSH lockdown on omni-host — admin reachable only via WG (UDP 51820)

## Pre-merge checklist (operator)
See `docs/superpowers/plans/2026-05-02-omni-oci-realignment-plan.md` runbook section. Critical:
- [ ] PRE-1: OCI bwire Always-Free quota verified
- [ ] PRE-2: bwire OCI WIF federation confirmed
- [ ] PRE-3/4: R2 inventory `oracle/bwire/{auth,nodes}.yaml` pre-staged
- [ ] PRE-5: existing-account R2 inventory mutated (Contabo bwire roles + LB labels; alimbacho67 + brianelvis33 LB labels)
- [ ] PRE-6: force_reinstall_generation bumped in {01,02} tfvars

## Test plan
Per spec `§5 Test plan / verification gates` (G1–G15). Highlights:
- post-apply: `curl -fsSL https://cp.stawi.org/healthz` returns 200
- `omnictl get machineset` shows cp 1/1, workers 5/5 healthy
- `kubectl get nodes` shows 6 nodes Ready
- WG admin path works; public SSH refused

EOF
)"
```

- [ ] **16.4 Update task list to track open PR.**

---

## Self-review checklist (run before PR)

- [ ] Every spec section maps to ≥1 task. Crosswalk:
  - §1 Architecture / Compute → Tasks 5–7 (omni-host-oci) + Tasks 10–11 + PRE-3/4
  - §1 Storage → Task 9 (cluster-image-registry flip)
  - §1 IAM → Task 8 (oci-operator-csk + deletion of per-service IAM)
  - §1 Network → Task 6 (security list)
  - §1 Cluster spec → Task 4 (Workers size 5) + Tasks 1, 14 (per-node patches)
  - §1 LB targets → PRE-5
  - §2 Components diff → covered by tasks 1–15
  - §3 Data flow → mapped to apply ordering implicit in tofu-apply.yml + workflow triggers
  - §4 Risks → mitigations baked into individual tasks (e.g., Task 13.4 = SideroLink-token-readiness gate)
  - §5 Test plan → Task 16.1/16.2/16.3 (PR description includes G1–G15 reference)

- [ ] No "TBD" / "implement later" left in any task. (If you find one, fix inline.)

- [ ] Type / signature consistency between tasks: variable names match (`omni_backup_writer_credentials` is the output name shared between Task 8 and Task 13's workflow consumer).

---

## Out of scope (deferred to follow-up plans)

- Track B — R2 → OCI tofu state migration (`cluster-tofu-state` → `cluster-state-storage`).
- On-prem tindase node — left alone.
- HA Omni / multi-CP.
- Cloudflare Worker for `pkgs.stawi.org`.
