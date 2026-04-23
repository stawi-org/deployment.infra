#!/usr/bin/env bash
set -euo pipefail
: "${OCI_COMPARTMENT_OCID:?}"
oci compute instance list --compartment-id "$OCI_COMPARTMENT_OCID" --all --auth security_token
