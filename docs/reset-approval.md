# Reset Approval Flow

Cluster resets are split into a request phase and an execution phase.

## Request phase

Run the `tofu-reinstall` workflow with:

- `confirm=REINSTALL`
- a short `reason`

That workflow writes a request file under `.github/reset-requests/` and opens a pull request. The PR is the approval gate.

## Approval phase

Review the PR like any other change:

- confirm the reason is correct
- confirm the reset is actually needed
- approve the PR
- merge it to `main`

No cluster reset happens before the merge.

## Execution phase

When the PR merge lands on `main`, the `reset-cluster` workflow triggers automatically from the `.github/reset-requests/**` path filter and runs the destructive reset steps.

`reset-cluster` can still be run manually via `workflow_dispatch` as a break-glass path, but the normal path is the approved PR merge.

## What the reset does

The reset workflow:

1. deletes `cp*` DNS records from Cloudflare
2. wipes the R2 state objects for layers 01, 02, 03, and 04
3. removes stale Talos images from Contabo

Layer 00 is preserved so the cluster keeps the same PKI identity.

## Local verification

Before opening the request PR, run:

```bash
make verify
```

That runs the local linting, inventory rendering, and `tofu validate` checks for the active layers.
