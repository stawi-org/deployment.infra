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

# 2. CreateImage via raw-request. The OCI CLI's `compute image
# create --from-json` silently strips launchOptions (it's not in the
# CLI's documented schema), so the API rejects with "launchOptions
# must be provided when using CUSTOM launchMode". `oci raw-request`
# POSTs the JSON verbatim — launchOptions reaches the API and pins
# UEFI_64 + paravirt virtio at image-create time.
echo "::notice::creating OCI image $DISPLAY_NAME from $SOURCE_URI" >&2

REGION=$(awk -v p="[$OCI_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f && /^region[[:space:]]*=/{sub(/.*=[[:space:]]*/, ""); print; exit}' "$HOME/.oci/config")
if [[ -z "$REGION" ]]; then
  echo "::error::could not parse region for profile $OCI_PROFILE from ~/.oci/config" >&2
  exit 1
fi

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

rc=0
created=$(oci raw-request \
  --http-method POST \
  --target-uri "https://iaas.${REGION}.oraclecloud.com/20160918/images" \
  --request-body "$payload" \
  2>&1) || rc=$?

if [[ $rc -ne 0 ]]; then
  echo "::error::oci raw-request CreateImage failed (rc=$rc)" >&2
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

# Wait for AVAILABLE — raw-request returns immediately after API
# acknowledges, but image import takes 5-10 min. Poll explicitly.
echo "::notice::waiting for image $ocid to reach AVAILABLE" >&2
for i in $(seq 1 80); do
  state=$(oci compute image get --image-id "$ocid" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
  echo "  [$i] state=$state" >&2
  case "$state" in
    AVAILABLE) break ;;
    FAILED|DELETED|DELETING)
      echo "::error::image $ocid landed in $state" >&2
      exit 1
      ;;
  esac
  sleep 15
done
state=$(oci compute image get --image-id "$ocid" --query 'data."lifecycle-state"' --raw-output)
if [[ "$state" != "AVAILABLE" ]]; then
  echo "::error::image $ocid still $state after wait" >&2
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
