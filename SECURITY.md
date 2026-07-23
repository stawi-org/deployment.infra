# Security notes for deployment.infra

## Current visibility

As of the last check, `stawi-org/deployment.infra` is **private**. This
document is the checklist if the repository is ever made **public**.

## What may live in git

| Artifact | Why OK |
|---|---|
| SOPS-encrypted `tofu/shared/accounts/**/auth.yaml` | Ciphertext only; encrypted with age recipients in `.sops.yaml` |
| `tofu/shared/age-recipients.txt` | **Public** age keys only |
| `.sops.yaml` | Encryption policy (public recipients) |
| `sops-fixture.plain.yaml` / `.age.yaml` | Canary string `healthy` only |
| Example OCIDs / project ids in `docs/config/**` | Placeholders (`example`, fake project ids) |
| OpenTofu HCL, workflows, non-secret tfvars | No long-lived cloud private keys |

## What must never be in git

| Artifact | Where it belongs |
|---|---|
| Age **private** key (`AGE-SECRET-KEY-1…`) | Operator machine / `SOPS_AGE_KEY` GitHub secret |
| Cloud API passwords, OAuth secrets, SA JSON | GitHub Actions secrets or SOPS-encrypted auth only |
| OpenTofu state (`*.tfstate`) | R2 `cluster-tofu-state` (private bucket) |
| Bastion SSH private keys | Sensitive outputs → R2 state only (`sensitive = true`) |
| Omni service account keys | `OMNI_SERVICE_ACCOUNT_KEY` secret |
| `credentials/` archives | Gitignored |
| Live machine configs / talosconfig | R2 audit paths or age-encrypted artifacts |
| `WORK_STATE.md`, local `.env` | Gitignored |

## Controls already in place

1. **SOPS**: all `auth.yaml` under `tofu/shared/accounts/**` match
   `encrypted_regex: '^(.*)$'` — full-file encryption of values.
2. **`.gitignore`**: `credentials/`, `providers/`, `**/.terraform/`,
   `*.tfstate*`, `terraform.tfvars.local`, apply-stage scratch.
3. **CI secrets**: Contabo/Cloudflare/R2/Omni/Flux material via Actions
   secrets, not repo files.
4. **No SA JSON for GCP**: WIF only (`bootstrap-gcp-wif.sh`).
5. **Sensitive tofu outputs**: bastion PEMs marked `sensitive = true`
   (still in remote state — protect the R2 bucket).

## Before making the repo public

- [ ] Confirm no `AGE-SECRET-KEY` or raw cloud secrets in git history
      (`git log -p -S 'AGE-SECRET-KEY'`, secret scanners).
- [ ] Confirm every `auth.yaml` is SOPS-encrypted (no plaintext reverts).
- [ ] Confirm R2 state bucket is not world-readable.
- [ ] Confirm GitHub Actions secrets are not echoed in logs.
- [ ] Rotate any credential that was ever committed in the past.
- [ ] Review PR artifacts / workflow uploads for kubeconfig/talosconfig
      (must stay age-encrypted or secret-scoped).
- [ ] Do not enable “public fork PRs write secrets” without careful
      `pull_request_target` review (prefer `pull_request` + no secrets).

## If a secret is leaked

1. Rotate the credential at the provider immediately.
2. Purge from git history if it was committed (`git filter-repo` / BFG)
   and force-push only with team agreement.
3. Invalidate related CI secrets and re-bootstrap WIF/OIDC if needed.

## Contact

Platform operators: rotate keys via the same bootstrap/onboard scripts
documented in `scripts/README.md` and `docs/gcp-onboard.md`.
