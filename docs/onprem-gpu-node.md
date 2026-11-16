# On-prem node install (GeForce RTX / NVIDIA GPU)

The `onprem/tindase` node is a **bare-metal** server with an NVIDIA
GeForce RTX card. Talos boots from an ISO that carries the NVIDIA
kernel modules + userspace driver as system extensions.

This doc covers: where to download the ISO, how to install it, and how
to verify GPU support.

## Where to download the ISO

The ISO is built and published by the `sync-talos-images` workflow. It
is **not** the same image as the cloud nodes — it additionally carries
the NVIDIA extensions listed in
`tofu/shared/schematics/onprem-gpu.yaml`, so it lives under its own
prefix.

### 1. Find the current URL

```bash
# The inventory file records the URL + sha256 of the published ISO.
aws s3 cp s3://cluster-tofu-state/production/inventory/talos-images.yaml - \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
```

```yaml
formats:
  onprem:
    url: "https://pkgs.stawi.org/<onprem_schematic_id>/metal-amd64-omni-<account>-<version>-<short_id>.iso"
    sha256: "<sha256>"
onprem_schematic_id: "<hash of cluster.yaml + onprem-gpu.yaml>-<talos_version>"
```

Use `formats.onprem.url` verbatim — it points at the Cloudflare
public host, so it fetches anonymously (the raw R2 S3 API endpoint
returns 400 for anonymous requests).

### 2. Download it

```bash
ISO_URL=$(yq -r '.formats.onprem.url' talos-images.yaml)
curl -fL --progress-bar -o talos-metal-amd64.iso "$ISO_URL"

# Verify against the published sha256.
echo "$(yq -r '.formats.onprem.sha256' talos-images.yaml)  talos-metal-amd64.iso" | sha256sum -c -
```

### 3. (Optional) Mirror it to the OCI bucket

The same ISO is mirrored into the `cluster-image-registry` bucket in
the `bwire` tenancy, under the on-prem schematic prefix:

```bash
aws s3 cp s3://cluster-image-registry/<onprem_schematic_id>/metal-amd64-omni-*.iso ./ \
  --endpoint-url "https://frosk7nwicev.compat.objectstorage.eu-frankfurt-1.oraclecloud.com" \
  --region eu-frankfurt-1
```

## Installing on the server

The ISO is a bootable USB image. The `tindase` server boots from
`/dev/sda` (see `tofu/shared/patches/common.yaml` — `machine.install.disk`).

1. Write the ISO to a USB stick (or attach it via IPMI virtual media):
   ```bash
   sudo dd if=talos-metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=direct
   ```
2. Boot the server from the USB.
3. Talos boots into maintenance mode and waits for a machine config.
   The config for this node is rendered by layer `03-talos` from
   `production/inventory/onprem/tindase/nodes.yaml` and pushed by
   `omnictl` once the node registers with Omni.

The node then installs Talos to `/dev/sda` and reboots into the
cluster.

### Manual config push (if auto-registration is not desired)

```bash
omnictl kubeconfig --cluster stawi > /tmp/talosconfig
talosctl --nodes <node-ip> --talosconfig /tmp/talosconfig apply-config -f machine.yaml
```

## Verifying GPU support

```bash
# Kernel modules loaded?
talosctl -n <node-ip> --talosconfig /tmp/talosconfig dmesg | grep -i nvidia

# Extension present?
talosctl -n <node-ip> --talosconfig /tmp/talosconfig ls /sys/module/nvidia

# nvidia-smi (userspace driver from nvidia-container-toolkit-*)
talosctl -n <node-ip> --talosconfig /tmp/talosconfig dmesg | grep -i nvidia
```

For a container to use the GPU, the NVIDIA container runtime must be
configured on the node. The `nvidia-container-toolkit-*` extension
ships `nvidia-container-runtime`; point containerd at it via a
`MachineConfig` patch (see `tofu/shared/patches/` for where
node-level config lives).

## Which extension set is used

`tofu/shared/schematics/onprem-gpu.yaml`:

```yaml
extensions:
  - siderolabs/nvidia-open-gpu-kernel-modules-production
  - siderolabs/nvidia-container-toolkit-production
```

| Extension | Provides |
| --- | --- |
| `nvidia-open-gpu-kernel-modules-production` | open NVIDIA kernel modules + driver (595.112.07 for Talos v1.14.6) |
| `nvidia-container-toolkit-production` | userspace driver (`nvidia-smi`), persistence daemon, container runtime hook |

Notes:

- These extensions are **amd64-only**. That is why they live in a
  separate file rather than in `tofu/shared/schematics/cluster.yaml`:
  the shared schematic also produces the **arm64** OCI image
  (A1.Flex), and the factory would reject the NVIDIA extension for
  that arch.
- The **open** kernel modules are the supported path for GeForce RTX
  (Turing / Ada / Blackwell). The proprietary build
  (`nonfree-kmod-nvidia-production`) is not used.
- Talos v1.14.6 ships two NVIDIA branches: `production` (595.112.07)
  and `lts` (580.196.07). Swap `production` → `lts` in the YAML if
  your card needs the older branch.
- The `new-feature` branch (615.x) only exists for v1.15.0-beta and is
  **not** available on v1.14.6.

## Rebuilding the image

Change `tofu/shared/schematics/onprem-gpu.yaml` (or
`cluster.yaml`) and run:

```bash
gh workflow run sync-talos-images.yml -f force=true
```

The workflow re-downloads the metal ISO with the new extension set,
uploads it under a fresh `onprem_schematic_id` prefix, and rewrites
`production/inventory/talos-images.yaml` with the new URL + sha256.
