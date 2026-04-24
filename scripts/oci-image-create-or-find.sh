#!/usr/bin/env bash
# Find-or-create an OCI custom image by display_name, with the exact
# launch_options Talos arm64 needs on A1.Flex. Driven by tofu's
# `external` data source — reads a JSON query from stdin, writes one
# line of JSON to stdout.
#
# Why not the tofu oci_core_image resource: its launch_options field
# is Computed-only in the provider schema (8.11.0). Every preset
# launch_mode lands wrong defaults on Talos factory's oracle-arm64
# image (no image_metadata.json embedded), and OCI UpdateImage
# doesn't accept launch_options post-create. The CLI is the only
# place we can declare CUSTOM launch_mode + the full Talos-prescribed
# launchOptions block at CreateImage time.
#
# Input (stdin, JSON):
#   {
#     "compartment_ocid": "...",
#     "display_name":     "Talos vX.Y.Z arm64 gen<gen>",
#     "source_uri":       "https://objectstorage.../*.qcow2",
#     "oci_profile":      "<account_key>",
#     "shape":            "VM.Standard.A1.Flex"
#   }
# Output (stdout, JSON):
#   { "image_ocid": "<ocid>" }
set -euo pipefail

input=$(cat)
COMPARTMENT=$(jq -r '.compartment_ocid' <<<"$input")
DISPLAY_NAME=$(jq -r '.display_name'     <<<"$input")
SOURCE_URI=$(jq -r '.source_uri'         <<<"$input")
OCI_PROFILE=$(jq -r '.oci_profile'       <<<"$input")
SHAPE=$(jq -r '.shape'                   <<<"$input")

for v in COMPARTMENT DISPLAY_NAME SOURCE_URI OCI_PROFILE SHAPE; do
  if [[ -z "${!v}" || "${!v}" == "null" ]]; then
    echo "::error::missing input: $v" >&2
    exit 1
  fi
done

# Suppress nonsense OCI CLI warnings that blow stderr without affecting
# behaviour — they confuse tofu's external data source error reporting.
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export SUPPRESS_LABEL_WARNING=True

oci() { command oci --profile "$OCI_PROFILE" "$@"; }

ERR_LOG=$(mktemp)
trap 'rm -f "$ERR_LOG"' EXIT

dump_err() { [[ -s "$ERR_LOG" ]] && cat "$ERR_LOG" >&2; }

# --------- 1. Find existing AVAILABLE image by display_name ---------
existing=$(oci compute image list \
  --compartment-id "$COMPARTMENT" \
  --display-name   "$DISPLAY_NAME" \
  --lifecycle-state AVAILABLE \
  --all \
  --query 'data[0].id' \
  --raw-output 2>"$ERR_LOG" || true)

if [[ -n "$existing" && "$existing" != "null" ]]; then
  jq -nc --arg ocid "$existing" '{image_ocid: $ocid}'
  exit 0
fi

# --------- 2. Create with the CUSTOM launch_options -----------------
echo "::notice::creating OCI image $DISPLAY_NAME from $SOURCE_URI" >&2

source_details=$(jq -nc --arg uri "$SOURCE_URI" \
  '{sourceType: "objectStorageUri", sourceUri: $uri, sourceImageType: "QCOW2"}')
launch_options=$(jq -nc '{
  bootVolumeType:                  "PARAVIRTUALIZED",
  firmware:                        "UEFI_64",
  networkType:                     "PARAVIRTUALIZED",
  remoteDataVolumeType:            "PARAVIRTUALIZED",
  isPvEncryptionInTransitEnabled:  true,
  isConsistentVolumeNamingEnabled: true
}')

if ! created=$(oci compute image create \
    --compartment-id        "$COMPARTMENT" \
    --display-name          "$DISPLAY_NAME" \
    --launch-mode           CUSTOM \
    --image-source-details  "$source_details" \
    --launch-options        "$launch_options" \
    --wait-for-state        AVAILABLE \
    --max-wait-seconds      900 \
    2>"$ERR_LOG"); then
  dump_err
  echo "::error::oci compute image create failed for $DISPLAY_NAME" >&2
  exit 1
fi

ocid=$(jq -r '.data.id' <<<"$created")
if [[ -z "$ocid" || "$ocid" == "null" ]]; then
  echo "::error::CreateImage returned no OCID. Response was:" >&2
  echo "$created" >&2
  exit 1
fi

# --------- 3. Register shape compatibility (idempotent PUT) ---------
# OCI defaults compatible_shapes to an empty list for imported images.
# Without this, LaunchInstance 400s with
#   "Shape <X> is not valid for image <...>"
oci compute image-shape-compatibility-entry add \
  --image-id   "$ocid" \
  --shape-name "$SHAPE" \
  >/dev/null 2>"$ERR_LOG" || { dump_err; exit 1; }

echo "::notice::created OCI image $ocid (shape compat: $SHAPE)" >&2
jq -nc --arg ocid "$ocid" '{image_ocid: $ocid}'
