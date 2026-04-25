age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Gen<N> is the image
# display_name suffix; bumping it forces a new CreateImage and
# replaces the in-state image. The CLI script behind data.external
# pins launchOptions to UEFI_64 + fully-paravirtualized virtio at
# image-create time (the only API path for that — see
# scripts/oci-image-create-or-find.sh).
force_image_generation = 9

# Force recreate of oci-bwire-node-1 alongside the image bump. OCI's
# instance source_id is not ForceNew in the provider, so a new image
# OCID would otherwise plan as in-place update and 400 on the
# incompatible boot volume type. Bumping forces destroy+create.
per_node_force_recreate_generation = {
  "oci-bwire-node-1" = 11
}
