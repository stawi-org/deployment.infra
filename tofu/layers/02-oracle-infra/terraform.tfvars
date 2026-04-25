#
# cluster_endpoint is the Talos/Kubernetes API endpoint that nodes embed in
# their generated machine config. Uses kubernetes-controlplane-api-1's public
# IPv4 (same IP preserved across PR #9's reinstall).
cluster_endpoint = "https://cp.antinvestor.com:6443"

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Gen<N> is the image
# display_name suffix; bumping replaces the resource. The image
# now uses launch_mode = "PARAVIRTUALIZED" to pin bootVolumeType /
# networkType / remoteDataVolumeType — confirmed via serial console
# that gen4 (which omitted launch_mode) had bootVolumeType=ISCSI and
# Talos couldn't find /dev/sda.
force_image_generation = 8

# Force recreate of oci-bwire-node-1 alongside the image bump. The
# instance's `source_id` is not ForceNew in the OCI provider, so a
# new image OCID would otherwise plan as in-place update and OCI 400s
# on incompatible boot volume types between old and new image.
per_node_force_recreate_generation = {
  "oci-bwire-node-1" = 9
}

# Layer 03 publishes cp-3.<zone> A records pointing at the OCI CP's
# public IPv4. The OCI node's API serving cert must include these
# DNS names so layer 03's talos_machine_configuration_apply (which
# we configure to connect by DNS) can pass TLS verification.
extra_cert_sans = [
  "cp-3.antinvestor.com",
  "cp-3.stawi.org",
  "cp.antinvestor.com",
  "cp.stawi.org",
]
