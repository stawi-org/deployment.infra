#!/usr/bin/env bash
# Find-or-create an OCI custom image with the exact launchOptions
# Talos arm64 needs (UEFI_64 + fully-paravirtualized virtio). Driven
# by tofu's `external` data source — reads JSON from stdin, writes
# one line of JSON to stdout.
#
# Why CLI not native tofu: the OCI provider's oci_core_image
# resource exposes `launch_mode` but NOT `launch_options` (the
# field is Computed-only in provider 8.11.0). With launch_mode=
# CUSTOM the OCI API requires launchOptions in the CreateImage body,
# which only the CLI's --from-json payload can deliver. None of the
# other launch_mode presets give the right combo for Talos arm64:
#   * NATIVE          → firmware=UEFI_64 (good) but bootVolumeType=
#                       ISCSI fixed (bad — Talos can't find /dev/sda)
#   * PARAVIRTUALIZED → bootVolumeType=PARAVIRT (good) but firmware=
#                       BIOS fixed (bad — arm64 can't boot from BIOS)
#
# Input (stdin, JSON):
#   {
#     "compartment_ocid": "...",
#     "display_name":     "Talos vX.Y.Z arm64 gen<gen>",
#     "source_uri":       "https://objectstorage.../*.qcow2",
#     "oci_profile":      "<account_key>",
#     "shape":            "VM.Standard.A1.Flex"
#   }
# Output (stdout, JSON): { "image_ocid": "<ocid>" }
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

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_AUTH=security_token

OCI_BIN=$(command -v oci || true)
for candidate in /usr/local/bin/oci /usr/bin/oci "$HOME/.local/bin/oci"; do
  [[ -n "$OCI_BIN" ]] && break
  [[ -x "$candidate" ]] && OCI_BIN="$candidate"
done
if [[ -z "$OCI_BIN" ]]; then
  echo "::error::oci CLI not found on PATH (PATH=$PATH)" >&2
  exit 1
fi
oci() { "$OCI_BIN" --profile "$OCI_PROFILE" "$@"; }

# 1. Find existing AVAILABLE image by display_name
existing=$(oci compute image list \
  --compartment-id "$COMPARTMENT" \
  --display-name   "$DISPLAY_NAME" \
  --lifecycle-state AVAILABLE \
  --all \
  --query 'data[0].id' \
  --raw-output 2>&1) || {
  echo "::error::oci compute image list failed: $existing" >&2
  exit 1
}

if [[ -n "$existing" && "$existing" != "null" ]]; then
  echo "::notice::reusing OCI image $existing" >&2
  jq -nc --arg ocid "$existing" '{image_ocid: $ocid}'
  exit 0
fi

# 2. CreateImage via --from-json. The CreateImageDetails body
# accepts launchOptions when launchMode=CUSTOM, even though it's
# not in the published API reference — the API errors with
# "launchOptions must be provided" if you set CUSTOM without it.
echo "::notice::creating OCI image $DISPLAY_NAME from $SOURCE_URI" >&2

payload=$(jq -nc \
  --arg comp "$COMPARTMENT" \
  --arg disp "$DISPLAY_NAME" \
  --arg uri  "$SOURCE_URI" \
  '{
    compartmentId: $comp,
    displayName:   $disp,
    launchMode:    "CUSTOM",
    launchOptions: {
      bootVolumeType:                  "PARAVIRTUALIZED",
      firmware:                        "UEFI_64",
      networkType:                     "PARAVIRTUALIZED",
      remoteDataVolumeType:            "PARAVIRTUALIZED",
      isPvEncryptionInTransitEnabled:  true,
      isConsistentVolumeNamingEnabled: true
    },
    imageSourceDetails: {
      sourceType:      "objectStorageUri",
      sourceUri:       $uri,
      sourceImageType: "QCOW2"
    }
  }')

tmp=$(mktemp --suffix=.json)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$payload" > "$tmp"

rc=0
created=$(oci compute image create \
  --from-json "file://$tmp" \
  --wait-for-state   AVAILABLE \
  --max-wait-seconds 1200 \
  2>&1) || rc=$?

if [[ $rc -ne 0 ]]; then
  echo "::error::oci compute image create failed (rc=$rc)" >&2
  echo "--- payload ---" >&2
  printf '%s\n' "$payload" >&2
  echo "--- CLI output ---" >&2
  printf '%s\n' "$created" >&2
  exit 1
fi

ocid=$(jq -r '.data.id' <<<"$created")
if [[ -z "$ocid" || "$ocid" == "null" ]]; then
  echo "::error::CreateImage returned no OCID. Response was:" >&2
  printf '%s\n' "$created" >&2
  exit 1
fi

# 3. Register shape compatibility (idempotent PUT)
if ! oci compute image-shape-compatibility-entry add \
    --image-id   "$ocid" \
    --shape-name "$SHAPE" \
    >/dev/null 2>&1; then
  echo "::error::shape compatibility registration failed ($SHAPE on $ocid)" >&2
  exit 1
fi

echo "::notice::created OCI image $ocid (shape compat: $SHAPE)" >&2
jq -nc --arg ocid "$ocid" '{image_ocid: $ocid}'
