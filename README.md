# HashiCorp Vault Zero-Touch Deployment on OpenShift via Terraform (Model 1)

This repository provides a fully automated, production-ready Terraform module to deploy High-Availability (HA) HashiCorp Vault on OpenShift or Kubernetes using Helm, featuring **Model 1: Zero-Touch Auto-Initialization**, dynamic PGP key and root token persistence, automated secrets engine & GitHub authentication provisioning, Raft storage, and OpenShift `restricted-v2` Security Context Constraint (SCC) compliance.

---

## 1. Key Architectural Principles

1. **Enforced Red Hat UBI Container Images**:
   - `injector.image.tag = "1.7.6-ubi"`
   - `server.image.tag = "2.0.4-ubi"`
2. **OpenShift SCC Compliance (`global.openshift = true`)**:
   - Native Helm chart toggle strips hardcoded `runAsUser: 100` and `fsGroup: 1000`, allowing OpenShift to dynamically allocate non-root UIDs/GIDs from your namespace's range (`1000870000-1000879999`).
3. **Raft Integrated Storage Engine**:
   - Configured via `server.ha.raft.enabled = true` with 10Gi persistent volumes (`server.dataStorage.enabled = true`), eliminating external Consul cluster dependencies.
4. **Pre-Baked Sidecar Image (`Dockerfile`)**:
   - Runs a lightweight sidecar image containing `gnupg`, `wget`, `curl`, `jq`, and `gawk`, built on Red Hat UBI minimal. Because OpenShift blocks runtime package installation (`microdnf install`) under dynamic non-root UIDs (`Permission denied`), pre-baking binaries guarantees instant startup without egress network dependencies.
5. **Zero-Touch Auto-Initialization with Leader Election Guard (Model 1)**:
   - **Leader Guard**: Only `vault-0` (`*-0$`) is permitted to call `/v1/sys/init`. Follower replicas (`vault-1`, `vault-2`) wait for `vault-0` to form the cluster to avoid multi-replica init race conditions (split-brain).
   - **In-Memory Initial Unseal**: Upon initialization, `vault-0` unseals itself directly in memory using the fresh unseal shares without waiting for Kubernetes volume mount sync or reading stale files from disk.
   - **Buffer Reset**: Sends `{"reset": true}` prior to submitting shares, ensuring partial attempts never poison the unseal threshold.
6. **Automated Post-Unseal Engines, Policies & GitHub Authentication**:
   - Once `vault-0` is unsealed, the leader sidecar decrypts the root token in memory and idempotently configures:
     - **KV-v2 Secrets Engine** mounted at `/secret`.
     - **PKI Secrets Engine** mounted at `/pki` (with `max_lease_ttl = 87600h`).
     - **`admin` ACL Policy**: Full root-equivalent permissions (`create`, `read`, `update`, `delete`, `list`, `sudo` on `*`).
     - **`secret-pki` ACL Policy**: Full access to `/secret` and `/secret/*` (KV-v2) and full PKI management (`create`, `read`, `update`, `delete`, `list`, `sudo`) on `/pki` and `/pki/*`.
     - **GitHub Auth Method (`/auth/github`)**: Configured for `github_organization` so all organization members receive the `secret-pki` policy by default, while users listed in `github_admin_users` are mapped to the `admin` policy.

---

## 2. Step-by-Step Setup & Deployment

### Step 1: Build & Push the Unsealer Sidecar Image
Build the custom sidecar container image using the included `Dockerfile` and push it to your internal container registry or OpenShift ImageStream:

```bash
docker build -t your-registry.domain.com/vault/vault-unsealer:v1.0.0 .
docker push your-registry.domain.com/vault/vault-unsealer:v1.0.0
```

### Step 2: Generate or Export GPG Keypair
If you don't already have a 4096-bit RSA GPG keypair on your management workstation, generate one:

```bash
gpg --full-generate-key
```

1. **Export Base64 PGP Public Key** (used by sidecar for `/v1/sys/init`):
   ```bash
   gpg --export vault-unseal@domain.local | base64 | tr -d '\n'
   ```
2. **Export ASCII Private Key** (mounted into pod for decryption):
   ```bash
   gpg --armor --export-secret-keys vault-unseal@domain.local > ./vault-unseal-private.asc
   ```

### Step 3: Configure `terraform.tfvars`
Copy `terraform.tfvars.example` to `terraform.tfvars` and set your configuration variables:

```hcl
kubeconfig_path       = "~/.kube/config"
namespace             = "vault"
helm_chart_version    = "0.27.0"

injector_image_tag    = "1.7.6-ubi"
server_image_tag      = "2.0.4-ubi"
unsealer_image        = "your-registry.domain.com/vault/vault-unsealer:v1.0.0"

unseal_type           = "sidecar"

pgp_public_key_base64 = "<PASTE_BASE64_PUBLIC_KEY_HERE>"
gpg_private_key_path  = "./vault-unseal-private.asc"
gpg_key_passphrase    = "YourPassphraseIfAny"

github_organization   = "your-github-org"
github_admin_users    = ["octocat"]
```

### Step 4: Deploy with Terraform
```bash
terraform init
terraform plan -out /tmp/plan
terraform apply /tmp/plan
```

---

## 3. GitHub Authentication & RBAC Policies

When `github_organization` is set, the leader sidecar configures GitHub authentication automatically upon unsealing:

| Role / Group | Assigned Policy | Permissions |
| :--- | :--- | :--- |
| Users in `github_admin_users` | `admin` | Root-equivalent permissions (`create`, `read`, `update`, `delete`, `list`, `sudo`) on all paths (`*`). |
| All other members of `github_organization` | `secret-pki` | Read/write/delete/list on `/secret` and `/secret/*` (KV-v2), plus full management (`create`, `read`, `update`, `delete`, `list`, `sudo`) on `/pki` and `/pki/*`. |

### Authenticating with GitHub
Users in the configured GitHub organization can authenticate using a GitHub Personal Access Token (classic) with the `read:org` scope:

```bash
vault login -method=github token=<GITHUB_PERSONAL_ACCESS_TOKEN>
```

---

## 4. Retrieving and Decrypting the Root Token

Once Vault auto-initializes and unseals, the encrypted root token is stored directly in Kubernetes.

### Using the Included Helper Script:
```bash
chmod +x retrieve-root-token.sh
./retrieve-root-token.sh
```

Or pass custom namespace/secret names:
```bash
./retrieve-root-token.sh custom-vault-namespace custom-secret-name
```

### Manually via CLI:
```bash
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data.root_token_pgp}' \
  | base64 -d \
  | base64 -d \
  | gpg --decrypt
```

---

## 5. Resetting Storage (If Re-Initialization Is Required)

If an initial auto-init attempt failed due to missing tools or bad credentials and left Vault initialized on Raft storage without saved keys:

```bash
# 1. Delete the StatefulSet and associated Raft PersistentVolumeClaim
oc delete statefulset vault -n vault
oc delete pvc -l app.kubernetes.io/name=vault -n vault

# 2. Reset the secret keys to empty defaults
oc patch secret vault-unseal-keys -n vault --type=merge -p '{"data":{"unseal_key_1_pgp":"","unseal_key_2_pgp":"","unseal_key_3_pgp":"","root_token_pgp":""}}'

# 3. Re-apply Terraform to redeploy Vault and trigger a clean zero-touch boot
terraform apply
```

---

## 6. File Structure Reference

| File | Purpose |
| :--- | :--- |
| `versions.tf` | Terraform & provider version pins (`helm ~> 2.12.0`, `kubernetes ~> 2.26.0`). |
| `variables.tf` | Input variables, validation rules, default container image tags, and GitHub auth settings (`github_organization`, `github_admin_users`). |
| `main.tf` | Namespace, Kubernetes Secrets, RBAC Role/Binding, Raft storage, OpenShift SCC integration (`global.openshift = true`), leader-guarded auto-init, in-memory unseal, `root_token_pgp` capture, and post-unseal provisioning of `/secret` (KV-v2), `/pki`, ACL policies, and GitHub auth. |
| `outputs.tf` | Output variables for namespace, unseal strategy, container image tags, and GitHub auth configuration. |
| `terraform.tfvars.example` | Example variable configuration template with Model 1, GitHub authentication, and Model 2 / Cloud KMS sections. |
| `retrieve-root-token.sh` | Shell script to fetch and decrypt the root token from Kubernetes using GPG. |
| `Dockerfile` | Red Hat UBI minimal image pre-baked with `gnupg`, `wget`, `curl`, `jq`, and `gawk` for non-root OpenShift execution. |
| `README.md` | Comprehensive architectural principles, setup instructions, GitHub authentication details, root token retrieval, and troubleshooting commands. |
