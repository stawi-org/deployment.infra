# scripts/

Operator tooling for the deployments repo. Each script is self-contained and
prints usage when run with `-h` / `--help` or with no arguments.

| Script | Purpose | Who runs it |
|---|---|---|
| [`bootstrap-oci-oidc.sh`](#bootstrap-oci-oidcsh) | Idempotently configure an OCI Identity Domain and print an inventory-ready OCI account stanza to stdout. | Operator, once per OCI tenancy, usually in OCI Cloud Shell. |
| [`get-kubeconfig.sh`](#get-kubeconfigsh) | Dispatch the `dispatch-kubeconfig` workflow and get a short-lived, per-user cluster-admin kubeconfig, encrypted to your SSH keys. | Any collaborator who needs ad-hoc cluster access from their workstation. |
| [`create-cluster-user.sh`](#create-cluster-usersh) | Mint a long-lived x509 client cert + kubeconfig for a stable Kubernetes user, optionally scoped to namespaces. | Cluster-admin (already holds a kubeconfig), for onboarding collaborators. |
| [`get-talos-configs.sh`](#get-talos-configssh) | Download the rendered Talos machine-config bundle published by the last apply. Use to onboard non-cloud machines as workers (laptops, on-prem, home labs). | Operator, when joining a new off-cloud node. |
| [`check-quota-fit.sh`](#check-quota-fitsh) | (Existing) sanity-check that configured workloads fit in the provisioned node quotas. | Operator, pre-apply sanity check. |

---

## Shared context

All scripts assume the repo root as working directory unless specifically
noted. Invoke from there:

```bash
./scripts/<name>.sh [flags ...]
```

### Common prerequisites

| Tool | Why | Install |
|---|---|---|
| `gh` | Talks to GitHub Actions for the workflow-dispatch scripts. | `brew install gh` / `apt install gh` |
| `kubectl` | Talks to the cluster. | https://kubernetes.io/docs/tasks/tools/ |
| `jq` | JSON mangling in several scripts. | `apt install jq` / `brew install jq` |
| `age` | Decrypts the kubeconfig artifact. | `brew install age` / `apt install age` |
| `openssl` | CSR and keypair generation for `create-cluster-user.sh`. | Usually already present |
| `aws` CLI | R2 state reads (only inside workflows — not needed locally). | — |
| `oci` CLI | Used by `bootstrap-oci-oidc.sh`. Pre-installed in OCI Cloud Shell. | `brew install oci-cli` |

### Security notes

- **`credentials/<name>/` is gitignored.** All scripts that emit
  keys/certs/kubeconfigs write there by default.
- **Don't commit a kubeconfig**: `.gitignore` already excludes
  `credentials/`, but the same applies if you `--out` to somewhere else.
- **Short-lived access first**. Prefer `get-kubeconfig.sh` (8 h default
  token) for day-to-day work. `create-cluster-user.sh` produces a 1-year
  cert — only use for people whose identity you want to persist in-cluster.

---

## `bootstrap-oci-oidc.sh`

Idempotently sets up OCI Identity Domain resources so GitHub Actions can
federate into the tenancy with OIDC + UPST — no long-lived OCI keys.

**What it configures** (per OCI tenancy):

1. Service user `cluster-provisioner` (with `serviceUser: true`).
2. Group `cluster-provisioners` + IAM policy granting compute, network, and
   bastion permissions in the compartment.
3. Confidential OAuth application `github-actions-cluster`.
4. Identity Propagation Trust `github-actions-antinvestor` that recognises
   GitHub's OIDC JWTs and impersonates the service user.

At the end it prints an OCI account stanza to stdout. It does **not** write a
file or push anything to R2 for you.

**Prereqs:**

- `oci` CLI installed + authed (or running in OCI Cloud Shell, which has
  both pre-configured).
- `jq`, `curl`, `python3`.

**Usage:**

```bash
# Single tenancy:
./scripts/bootstrap-oci-oidc.sh --profile DEFAULT --gh-profile stawi --suffix 0

# Multi-tenancy, one invocation per OCI account:
./scripts/bootstrap-oci-oidc.sh --profile tenantA --gh-profile stawi --suffix 0
./scripts/bootstrap-oci-oidc.sh --profile tenantB --gh-profile acctB --suffix 1
./scripts/bootstrap-oci-oidc.sh --profile tenantC --gh-profile acctC --suffix 2
```

**Flags:**

| Flag | Description | Default |
|---|---|---|
| `--profile <NAME>` | OCI CLI profile from `~/.oci/config`. | `DEFAULT` |
| `--gh-profile <NAME>` | Name written to the OCI account key in the rendered inventory stanza. | slugged form of `--profile` |
| `--suffix <N>` | Inventory export slot label for the printed example block. | `0` |
| `--tenancy <OCID>` | Tenancy OCID. Auto-detected from the OCI profile. | auto |
| `--region <REGION>` | OCI region identifier. Auto-detected. | auto |
| `--compartment <OCID>` | Compartment to scope resources to. | tenancy root |
| `--repo <owner/name>` | GitHub repo used in the informational footer. | `antinvestor/deployments` |

**Output (end of run):**

```
oci:
  accounts:
    stawi:
      tenancy_ocid: ocid1.tenancy....
      compartment_ocid: ocid1.compartment....
      region: eu-frankfurt-1
      vcn_cidr: 10.200.0.0/16
      enable_ipv6: true
      auth:
        domain_base_url: https://idcs-...
        oidc_client_identifier: "cid:secret"
      labels:
        node.antinvestor.io/capacity-pool: ampere-a1
      annotations:
        node.antinvestor.io/account-owner: platform
      nodes:
        oci-stawi-node-1:
          role: worker
          shape: VM.Standard.A1.Flex
          ocpus: 4
          memory_gb: 24
          labels:
            node.antinvestor.io/plane: control-plane
            node.antinvestor.io/role-cache: "true"
            node.antinvestor.io/role-database: "true"
            node.antinvestor.io/role-queue: "true"
            node.kubernetes.io/external-load-balancer: "true"
          annotations:
            node.antinvestor.io/operator-note: control-plane
```

Copy the printed stanza into your inventory file, add node entries under
`nodes`, then sync `providers/config/` to
`s3://cluster-tofu-state/production/config/` after you are satisfied with the
result.

The script is safe to re-run: every resource is looked up by name and either
no-op'd or patched into the correct shape. In particular it self-heals the
service user (which has an immutable `serviceUser` flag) and the propagation
trust if their fields drifted.

---

## `get-kubeconfig.sh`

One-step local fetch of a short-lived cluster-admin kubeconfig for
**yourself** — ideal for day-to-day `kubectl` work.

The workflow it dispatches (`dispatch-kubeconfig.yml`) creates a
ServiceAccount named `access-<your-github-username>` in the
`access-tokens` namespace, binds it `cluster-admin`, mints a time-boxed
token, encrypts it to every `ssh-ed25519` / `ssh-rsa` public key you
publish at `https://github.com/<you>.keys`, and uploads the ciphertext
as a GitHub Actions artifact.

Anyone with repo read access can download that artifact, but **only you
can decrypt** it — the secret bits are age-encrypted to your SSH keys.

Every API call the resulting kubeconfig makes is logged as
`system:serviceaccount:access-tokens:access-<your-github-username>`, so
even if several users dispatch the workflow the audit trail never loses
track of who did what.

**Prereqs:**

- `gh` authed against the repo.
- `age` installed locally.
- `kubectl`, `jq`.
- At least one `ssh-ed25519` or `ssh-rsa` public key on your GitHub
  account (add at https://github.com/settings/keys).

**Usage:**

```bash
# Default: 8-hour token, writes to ~/.kube/config.
./scripts/get-kubeconfig.sh

# Request a longer TTL and store the config elsewhere:
./scripts/get-kubeconfig.sh --ttl 24 --out ~/.kube/antinvestor.yaml
export KUBECONFIG=~/.kube/antinvestor.yaml

# Use a specific private SSH key for decryption:
./scripts/get-kubeconfig.sh --key ~/.ssh/id_ed25519_work

# Target a different repo (rarely needed):
./scripts/get-kubeconfig.sh --repo myorg/myrepo
```

**Flags:**

| Flag | Description | Default |
|---|---|---|
| `--ttl <N>` | Token lifetime in hours (1–24). | `8` |
| `--key <path>` | SSH private key used to decrypt the artifact. | `~/.ssh/id_ed25519` |
| `--out <path>` | Where to write the kubeconfig. Existing file is backed up to `<path>.bak`. | `~/.kube/config` |
| `--repo <owner/name>` | Override the target repo. | `antinvestor/deployments` |

**What happens step by step:**

1. `gh workflow run dispatch-kubeconfig.yml` (with your chosen TTL).
2. Polls `gh run list` for up to 40 s waiting for the new run to appear.
3. `gh run watch` until completion.
4. `gh run download -n kubeconfig` pulls `kubeconfig.age`.
5. `age -d -i $KEY` decrypts into `$OUT` (backing up any existing file).
6. `kubectl get nodes` as a smoke test.

**Rotating or revoking access:** the token auto-expires after its TTL.
To invalidate it sooner, delete the ServiceAccount in-cluster:

```bash
kubectl -n access-tokens delete sa access-<your-github-username>
kubectl delete clusterrolebinding access-<your-github-username>
```

The next `get-kubeconfig.sh` run will recreate them.

---

## `create-cluster-user.sh`

Directly mints a Kubernetes user via the `CertificateSigningRequest` API
and emits a kubeconfig they can use. Unlike `get-kubeconfig.sh` this is
for onboarding **other people** (or yourself if you want a long-lived
identity) — the cert defaults to 1-year lifetime and the kubeconfig does
not expire when you log out.

Use it when:

- A collaborator needs access for weeks/months and workflow-dispatch is
  too much friction.
- You want per-namespace RBAC rather than blanket cluster-admin.
- You want a single stable identity (`CN=alice`) in audit logs.

**Prereqs:**

- You already have a kubeconfig with rights to:
  - `certificatesigningrequests` (create, approve, get)
  - `clusterrolebindings` / `rolebindings` (create)

  The default admin kubeconfig from `get-kubeconfig.sh` satisfies both.
- `openssl`, `kubectl`.

**Usage:**

```bash
# Give alice admin in the staging + dev namespaces:
./scripts/create-cluster-user.sh alice staging dev

# Give ops cluster-admin (all namespaces) with a 90-day cert:
./scripts/create-cluster-user.sh ops --all-namespaces --ttl-days 90

# Pick a specific kubeconfig output path:
./scripts/create-cluster-user.sh bob payments --out /tmp/bob-kubeconfig
```

**Positional arg + flags:**

| Arg / flag | Description | Default |
|---|---|---|
| `<username>` (required) | Goes into `CN=<username>/O=<username>-group` on the cert. | — |
| `<namespace> [namespace ...]` | One or more namespaces to bind `admin` in. | — |
| `--all-namespaces` | Instead of per-namespace admin, bind `cluster-admin`. | `false` |
| `--ttl-days <N>` | Certificate lifetime. | `365` |
| `--out <path>` | Kubeconfig output path. | `credentials/<username>/kubeconfig` |

Either `<namespace> ...` or `--all-namespaces` must be provided; the script
errors out otherwise to prevent minting certs that grant nothing.

**What gets written** (all under `credentials/<username>/`):

- `pem.key` — private RSA 2048 key (mode 0600).
- `pem.csr` — certificate signing request.
- `pem.crt` — the x509 certificate signed by the cluster CA.
- `kubeconfig` — ready-to-use kubeconfig, `current-context` set.

Share only the `kubeconfig` with the user. The key/cert stay as a record.

**Revocation.** Kubernetes has no built-in cert revocation. To deny a user
access, delete their RoleBindings / ClusterRoleBindings:

```bash
kubectl delete clusterrolebinding <user>-admin-binding
kubectl delete rolebinding <user>-admin-binding -n <namespace>   # per namespace
```

They'll still authenticate (the cert is valid against the CA) but have
zero permissions. If that's not enough, rotate the cluster CA.

---

## `get-talos-configs.sh`

Downloads the Talos machine-config bundle published by the
[`publish-talos-configs`](../.github/workflows/publish-talos-configs.yml)
workflow. The artifact is **unencrypted** because machine configs are
boot-time cluster secrets that every workflow collaborator already has
equivalent access to via other paths — encrypting them would just get in
the way of the intended use case (onboarding a new node).

Contents of the bundle:

- `talosconfig` — root `talosctl` client config.
- `control-plane/<node>.yaml` — one per CP.
- `worker/<node>.yaml` — one per cloud worker.
- `generic-worker.yaml` — platform-neutral worker config for off-cloud
  machines (laptops, on-prem servers, home lab). No public IP required
  on the joining machine; it joins via outbound KubeSpan WireGuard.
- `schematic.yaml` — the Talos Image Factory schematic matching this
  cluster's extensions, so the boot ISO is reproducible.
- `README.md` — step-by-step join instructions.

**Prereqs:** `gh` (authed), `jq`.

**Usage:**

```bash
# Use the most recent successful publish run (automatic after each apply):
./scripts/get-talos-configs.sh

# Force a fresh render — dispatches publish-talos-configs and waits:
./scripts/get-talos-configs.sh --refresh

# Pick a different output directory:
./scripts/get-talos-configs.sh --out /tmp/talos-configs
```

**Joining a laptop / on-prem box** is documented end-to-end in the
bundle's own `README.md`. Summary:

1. POST `schematic.yaml` to Talos Image Factory to get an ISO URL.
2. Boot the machine from that ISO; note its LAN IP.
3. `talosctl apply-config --insecure --nodes <lan-ip> --file generic-worker.yaml`
4. Wait ~60s; `kubectl get nodes` shows the new machine.

---

## `check-quota-fit.sh`

Static sanity-check that configured workloads (pods, jobs, etc.) sum to
less than the provisioned node capacity across all nodes. Runs
against the committed manifests; no cluster interaction required.

See `./scripts/check-quota-fit.sh --help` for invocation details.

---

## When to use which for cluster access

```
Need kubectl access?
├── Is it me, for ad-hoc work? ──────────────────► get-kubeconfig.sh       (8 h token, audited by GH + in-cluster)
├── Am I onboarding someone else? ───────────────► create-cluster-user.sh  (365-day cert, audit by CN)
└── Building automation that runs in CI? ────────► a dedicated ServiceAccount + kubectl token in a workflow
```
