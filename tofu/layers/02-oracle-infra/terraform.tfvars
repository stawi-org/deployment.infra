age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Gen<N> is the image
# display_name suffix; bumping triggers replace_triggered_by on
# oci_core_image.talos and forces a new CreateImage on the next
# apply. launchOptions are pinned via image_metadata.json embedded
# in the .oci archive the workflow builds (see "Stage Talos .oci
# archive" step in tofu-layer.yml) — OCI auto-detects the archive
# on import and reads externalLaunchOptions as the image's defaults.
# Bumped 9 → 10 alongside the schema-fix landing: the gen9 image
# in each tenancy was created by the previous CLI-driven flow from
# a plain qcow2 (no metadata) and boots with the wrong defaults.
force_image_generation = 12

# Per-node reinstalls happen automatically when the inventory's OCID
# changes (regenerate-talos-images workflow rolls a new image →
# oci_core_instance source_details drifts → tofu plans destroy+create).
# No request-file mechanism, no manual triggers.


# See 01-contabo-infra/terraform.tfvars for the full bump-history
# story. Mirror in lock-step so a single fleet-wide reinstall rolls
# every node together.
#   8 — 2026-05-01: post-image_change-sentinel introduction. The
#                   sentinel was freshly created in the previous
#                   apply (PR #120), so its first appearance was
#                   creation-not-replacement and replace_triggered_by
#                   didn't fire. This bump rolls every OCI instance
#                   once via the existing force_reinstall path so all
#                   nodes land on the new-token Talos image; from now
#                   on any var.image_id change naturally REPLACES
#                   image_change and propagates to instance replace.
#  10 — 2026-05-02: paired with the omni-host migration off Contabo
#                   onto OCI bwire (PR #156). The new omni-host mints
#                   a fresh SideroLink token at first boot; bumping
#                   here rolls every OCI Talos node onto an image
#                   carrying that token (otherwise the existing
#                   nodes still hold the old token and Omni rejects
#                   their joins with `has_valid_join_token: false`).
#  13 — 2026-05-04: post cluster delete + recreate (omni-on-Contabo
#                   cutover). Two OCI nodes (bwire, brianelvis33) had
#                   stale SideroLink tokens for the destroyed cluster
#                   and never re-registered. Forcing fleet reinstall
#                   pulls the fresh-token image baked by the
#                   regenerate-talos-images PR #176 merge.
#  14 — 2026-05-07: storage volume layout (EPHEMERAL maxSize=20GB +
#                   topolvm-data UserVolumeConfig grow=true) was
#                   wired into cluster.yaml on 2026-05-06 but Talos
#                   only partitions the disk at INSTALL time. Old
#                   nodes had EPHEMERAL consume the whole disk
#                   (105GB on a 107GB disk; verified via
#                   talosctl get volumestatuses), leaving zero free
#                   space for topolvm-data. Forcing OCI VMs to
#                   destroy+create gets them onto fresh disks
#                   partitioned per the new VolumeConfig. Pairs
#                   with 01-contabo-infra gen=19 PUT-reinstall in
#                   the same apply.
#  15 — 2026-05-07: rename UserVolumeConfig topolvm-data → local-
#                   path-provisioner to match Sidero's documented
#                   layout (mount path becomes
#                   /var/mnt/local-path-provisioner). Existing
#                   partitions still claim the disk under the old
#                   name; force destroy+create gets every OCI node
#                   onto a fresh disk repartitioned under the new
#                   name. Pairs with 01-contabo-infra gen=20
#                   PUT-reinstall.
#  16 — 2026-05-07: pin Flannel inter-node iface to KubeSpan
#                   (cluster.network.cni.flannel.extraArgs:
#                    [--iface=kubespan]) so pod MTU = 1370
#                   instead of the host's 8950 jumbo-derived
#                   value. Cross-node TCP/TLS handshakes were
#                   blackholing on cert-chain reply because the
#                   8950-byte VXLAN packets didn't fit through
#                   the 1420-byte WG path. Pairs with
#                   01-contabo-infra gen=21 PUT-reinstall.
#  17 — 2026-05-24: post 2026-05-23 omni-host flip (Contabo → OCI
#                   bwire) + cluster wipe. The first roll embedded
#                   the new-Omni siderolink token in fresh images,
#                   but every machine briefly registered and then
#                   stuck at `connected: false` (token consumed at
#                   join but no persistent identity established).
#                   Bumping forces a clean destroy+create cycle on
#                   every OCI Talos node with a fresh download token
#                   from the now-stable new Omni. Pairs with
#                   01-contabo-infra gen=22 PUT-reinstall.
#  18 — 2026-05-24: after the OCI Omni VM was again recreated via
#                   -replace= (PR-less manual apply at 03:35 to get
#                   a clean /var/lib/omni and fresh WG server keys),
#                   the gen-17 fleet images still embedded the
#                   previous Omni's WG pubkey. Re-syncing images
#                   post-latest-Omni-recreate then bumping pulls
#                   every node onto an image carrying the current
#                   WG server pubkey + token. Pairs with
#                   01-contabo-infra gen=23 PUT-reinstall.
force_reinstall_generation = 19
