# HashiCorp Vault Zero-Touch Deployment on OpenShift via Terraform (Model 1)

This repository provides a fully automated, production-ready Terraform module to deploy HashiCorp Vault on OpenShift or Kubernetes using Helm, featuring **Model 1: Zero-Touch Auto-Initialization**, dynamic PGP key storage, and OpenShift `restricted-v2` Security Context Constraint (SCC) compliance.

---

## 1. Key Architectural Principles

1. **Enforced Red Hat UBI Images**:
   - `injector.image.tag = "1.7.6-ubi"`
   - `server.image.tag = "2.0.4-ubi"`
2. **OpenShift SCC Compliance (`global.openshift = true`)**:
   - Native Helm chart toggle strips hardcoded `runAsUser: 100` and `fsGroup: 1000`, allowing OpenShift to dynamically allocate non-root UIDs/GIDs (`1000870000-1000879999`).
3. **Raft Integrated Storage Engine**:
   - Uses `server.ha.raft.enabled = true` and 10Gi PVCs per pod (`server.dataStorage.enabled = true`), eliminating external Consul dependencies.
4. **Pre-Baked Sidecar Image**:
   - Runs a lightweight sidecar image (`Dockerfile`) containing `gnupg` and `busybox`. Because OpenShift blocks runtime `apk add` under dynamic non-root UIDs, pre-baking binaries guarantees instant startup without egress network dependencies.
5. **Zero-Touch Auto-Initialization & Auto-Unsealing (Model 1)**:
   - **HTTP 501 (Uninitialized)**: Sidecar detects uninitialized state, reads your mounted base64 PGP public key, calls `/v1/sys/init`, receives the 3 PGP-encrypted key shares, and patches `vault-unseal-keys` Secret via Kubernetes REST API using RBAC permissions.
   - **HTTP 500 (Sealed)**: Sidecar decrypts the unseal key shares in memory via GPG (with loopback passphrase support) and posts unseal shares to `/v1/sys/unseal`.

---

## 2. Step-by-Step Setup Guide

### Step 1: Build & Push the Unsealer Sidecar Image
Build the custom sidecar container image using the included `Dockerfile` and push it to your internal image registry (or OpenShift ImageStream):

```bash
docker build -t your-registry.domain.com/vault/vault-unsealer:v1.0.0 .
docker push your-registry.domain.com/vault/vault-unsealer:v1.0.0
```

### Step 2: Generate or Export GPG Keypair
Generate a 4096-bit RSA GPG keypair on your management workstation if you don't already have one:

```bash
gpg --full-generate-key
```

1. **Export Base64 PGP Public Key** (used by sidecar for `/v1/sys/init`):
   ```bash
   gpg --export vault-unseal@domain.local | base64 | tr -d '
'
   ```
2. **Export ASCII Private Key** (mounted into pod for decryption):
   ```bash
   gpg --armor --export-secret-keys vault-unseal@domain.local > ./vault-unseal-private.asc
   ```

### Step 3: Configure `terraform.tfvars`
Copy `terraform.tfvars.example` to `terraform.tfvars` and populate the keys:

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
```

### Step 4: Deploy with Terraform
```bash
terraform init
terraform plan -out /tmp/plan
terraform apply /tmp/plan
```

---

## 3. Verification & Troubleshooting

### Check Pod Status
```bash
oc get pods -n vault
```
Both `vault-0` and `vault-agent-injector` will show `1/1 Running` (or `2/2 Running` with sidecar container).

### Check Sidecar Execution Logs
```bash
oc logs -n vault pod/vault-0 -c vault-auto-unsealer
```

*Expected Log Output:*
```text
Starting Vault Zero-Touch Auto-Init & Auto-Unseal daemon (pre-baked GPG)...
Vault is uninitialized (HTTP 501). Executing auto-initialization...
Vault initialized successfully. Saving unseal keys to Kubernetes secret 'vault-unseal-keys'...
Secret updated. Proceeding to unseal...
Vault is sealed! Decrypting keys and submitting...
```

### Check Persisted Unseal Keys Secret
```bash
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data}'
```
Keys `unseal_key_1_pgp`, `unseal_key_2_pgp`, and `unseal_key_3_pgp` will be populated with the base64 PGP ciphertext key shares.

---

## 4. File Structure

- **`versions.tf`**: Terraform & provider version constraints.
- **`variables.tf`**: Input variable declarations & validations.
- **`main.tf`**: Namespace, secrets, RBAC role/binding, Raft storage, OpenShift SCC integration, and sidecar script.
- **`outputs.tf`**: Deployment outputs.
- **`terraform.tfvars.example`**: Example variable file.
- **`Dockerfile`**: Lightweight Alpine image with pre-baked `gnupg` and `busybox`.
- **`README.md`**: Complete architecture & deployment instructions.
