# archive/

Processed reset / reinstall request files end up here after their
work is done. Two reasons we don't just delete them:

1. Audit. The merged PR title is one record; the request body
   (scope, nodes, reason, requested_by) is the other. Archiving keeps
   the body in git history for trace.
2. Avoid retriggering. tofu's
   `tofu/layers/0[12]-*-infra/reconstruction.tf` globs
   `.github/reconstruction/reinstall-*.yaml` to compute per-node
   reinstall hashes. A stale file whose request was already processed
   would silently re-fire MODE=reinstall on every node it scopes,
   re-wiping disks every apply. Moving the file under `archive/`
   removes it from the glob (the pattern doesn't recurse) without
   losing its content.
3. Workflow path filters on `cluster-reset.yml` and
   `cluster-reinstall.yml` watch the parent dir directly; archived
   files don't re-fire those workflows either.

`cluster-reset.yml` archives every existing `reset-*.yaml` and
`reinstall-*.yaml` automatically as part of the state wipe so a fresh
`tofu-apply` after a reset doesn't re-trigger reinstalls from stale
requests.
