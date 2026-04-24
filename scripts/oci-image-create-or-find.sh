#!/usr/bin/env bash
# Find-or-create an OCI custom image by display_name, with the exact
# launch_options Talos arm64 needs on A1.Flex. Driven by tofu's
# `external` data source — reads a JSON query from stdin, writes one
# line of JSON to stdout.
#
# Input (stdin, JSON):
#   { "compartment_ocid": "...", "display_name": "...", "source_uri": "..." }
#
# Output (stdout, JSON):
#   { "image_ocid": "<ocid>" }
#
# OCI CLI auth comes from ~/.oci/config, populated by
# scripts/configure-oci-wif.sh at workflow start (UPST from GH OIDC).
#
# Why not the tofu oci_core_image resource: its launch_options field
# is marked Computed-only in the provider schema (8.11.0), so we can't
# set bootVolumeType=PARAVIRTUALIZED + firmware=UEFI_64 there. OCI
# UpdateImage doesn't accept launch_options either — the values lock
# at CreateImage time. Talos factory's oracle-arm64.qcow2 ships
# without image_metadata.json, so OCI's own defaults are wrong on
# every launch_mode preset (ISCSI, BIOS, or emulated — see image.tf).
# This script is the path that lets us pass the full set OCI accepts.

set -euo pipefail

input=$(cat)
COMPARTMENT=$(jq -r '.compartment_ocid' <<<"$input")
DISPLAY_NAME=$(jq -r '.display_name' <<<"$input")
SOURCE_URI=$(jq -r '.source_uri' <<<"$input")
OCI_PROFILE=$(jq -r '.oci_profile' <<<"$input")

for v in COMPARTMENT DISPLAY_NAME SOURCE_URI OCI_PROFILE; do
  if [[ -z "${!v}" || "${!v}" == "null" ]]; then
    echo "::error::missing input: $v" >&2
    exit 1
  fi
done

oci() { command oci --profile "$OCI_PROFILE" "$@"; }

# Capture oci CLI stderr into a file we can dump on failure — otherwise
# tofu's external data source wraps stderr in its own Error Message and
# the raw OCI error gets truncated.
ERR_LOG=$(mktemp)
trap '[[ -s "$ERR_LOG" ]] && cat "$ERR_LOG" >&2; rm -f "$ERR_LOG"' EXIT

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

# --------- 2. Create a fresh one with the CUSTOM launch_options -----
echo "::notice::creating OCI image $DISPLAY_NAME from $SOURCE_URI" >&2

source_details=$(jq -nc \
  --arg uri "$SOURCE_URI" \
  '{sourceType: "objectStorageUri", sourceUri: $uri, sourceImageType: "QCOW2"}')

launch_options=$(jq -nc '{
  bootVolumeType:                 "PARAVIRTUALIZED",
  firmware:                       "UEFI_64",
  networkType:                    "PARAVIRTUALIZED",
  remoteDataVolumeType:           "PARAVIRTUALIZED",
  isPvEncryptionInTransitEnabled: true,
  isConsistentVolumeNamingEnabled: true
}')

# Disable OCI CLI's automatic retry + suppress the noisy API-key label
# warning; surface its own exit code directly so we can report the
# real error instead of bash set -e masking it.
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export SUPPRESS_LABEL_WARNING=True

if ! created=$(oci compute image create \
  --compartment-id         "$COMPARTMENT" \
  --display-name           "$DISPLAY_NAME" \
  --launch-mode            CUSTOM \
  --image-source-details   "$source_details" \
  --launch-options         "$launch_options" \
  --wait-for-state         AVAILABLE \
  --max-wait-seconds       900 \
  2>"$ERR_LOG"); then
  cat "$ERR_LOG" >&2
  echo "::error::oci compute image create failed" >&2
  exit 1
fi

ocid=$(jq -r '.data.id' <<<"$created")
if [[ -z "$ocid" || "$ocid" == "null" ]]; then
  echo "::error::CreateImage returned no OCID. Raw response:" >&2
  echo "$created" >&2
  exit 1
fi

echo "::notice::created OCI image $ocid" >&2
jq -nc --arg ocid "$ocid" '{image_ocid: $ocid}'
