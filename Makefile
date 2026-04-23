.SHELLFLAGS := -eu -o pipefail -c
SHELL := /usr/bin/env bash

.PHONY: verify lint render validate

VERIFY_LAYERS := \
	tofu/layers/01-contabo-infra \
	tofu/layers/02-oracle-infra \
	tofu/layers/02-onprem-infra \
	tofu/layers/03-talos \
	tofu/layers/04-flux

verify: lint render validate

lint:
	pre-commit run -a
	bash -n scripts/bootstrap-oci-oidc.sh
	python3 -m py_compile scripts/render-cluster-config.py

render:
	python3 scripts/render-cluster-config.py cluster \
		--input docs/config \
		--out-contabo-accounts /tmp/contabo.json \
		--out-oci-accounts /tmp/oci.json \
		--out-retained-oci-accounts /tmp/oci-retained.json \
		--out-oci-auth-accounts /tmp/oci-auth.json \
		--out-onprem-locations /tmp/onprem.json

validate:
	@set -euo pipefail; \
	for layer in $(VERIFY_LAYERS); do \
		( cd "$$layer" && tofu validate ); \
	done
