#!/usr/bin/env bash
# Ensure the Talos QCOW2 for <version>+<schematic> is present in an OCI
# Object Storage bucket for the given profile, and echo its public HTTPS
# URL. OCI's CreateImage API refuses external HTTPS sources — it only
# accepts OCI Object Storage URLs — so the workflow pre-stages the image
# here and passes the resulting URL to tofu via TF_VAR_talos_image_source_uris.
#
# Idempotent: bucket is created once, object upload is skipped when the
# head call finds a matching object. Re-running is a no-op after the
# first successful upload.
#
# Usage:
#   ensure-oci-talos-image.sh <profile> <region> <compartment_ocid> <schematic_id> <talos_version>
#
# Stdout: the public HTTPS URL of the object (ready to pass to OCI CreateImage).
# Stderr: diagnostic progress messages.

set -euo pipefail

PROFILE="${1:?profile required}"
REGION="${2:?region required}"
COMPARTMENT="${3:?compartment_ocid required}"
SCHEMATIC="${4:?schematic_id required}"
VERSION="${5:?talos_version required}"

FACTORY_URL="https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/oracle-arm64.qcow2"
BUCKET="talos-images-${PROFILE}"
OBJECT="talos-${VERSION}-${SCHEMATIC}-oracle-arm64.qcow2"

echo "ensure-oci-talos-image: profile=$PROFILE region=$REGION bucket=$BUCKET object=$OBJECT" >&2

NS=$(oci --profile "$PROFILE" os ns get --raw-output --query 'data')
if [[ -z "$NS" || "$NS" == "null" ]]; then
  echo "::error::failed to resolve OCI Object Storage namespace for profile $PROFILE" >&2
  exit 1
fi

if ! oci --profile "$PROFILE" os bucket get --namespace "$NS" --name "$BUCKET" >/dev/null 2>&1; then
  echo "creating bucket $BUCKET (public-read)" >&2
  oci --profile "$PROFILE" os bucket create \
    --namespace "$NS" --name "$BUCKET" \
    --compartment-id "$COMPARTMENT" \
    --public-access-type ObjectRead >/dev/null
else
  echo "bucket $BUCKET already exists" >&2
fi

if oci --profile "$PROFILE" os object head --namespace "$NS" \
     --bucket-name "$BUCKET" --name "$OBJECT" >/dev/null 2>&1; then
  echo "object $OBJECT already present; skipping upload" >&2
else
  echo "downloading $FACTORY_URL" >&2
  tmpfile=$(mktemp --suffix=.qcow2)
  trap 'rm -f "$tmpfile"' EXIT
  curl -fsSL -o "$tmpfile" "$FACTORY_URL"
  echo "uploading to $BUCKET/$OBJECT" >&2
  oci --profile "$PROFILE" os object put --namespace "$NS" \
    --bucket-name "$BUCKET" --name "$OBJECT" \
    --file "$tmpfile" --force >/dev/null
fi

# Public URL format for a bucket with --public-access-type ObjectRead.
echo "https://objectstorage.${REGION}.oraclecloud.com/n/${NS}/b/${BUCKET}/o/${OBJECT}"
