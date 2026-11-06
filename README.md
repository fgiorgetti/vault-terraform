# HashiCorp Vault Helm Deployment via Terraform

This repository provides a modular, production-ready Terraform setup to deploy HashiCorp Vault into a Kubernetes cluster using Helm, supporting dynamic auto-unseal mechanisms and enforced UBI container tags.

## Key Features

1. **Enforced Red Hat UBI Images**:
   - `injector.image.tag`: `1.7.6-ubi`
   - `server.image.tag`: `2.0.4-ubi`
2. **Flexible Auto-Unseal Strategies**:
   - **`sidecar`**: Deploys an Alpine-based sidecar container (`alpine:3.19`) that automatically decrypts PGP-encrypted unseal key shares using a mounted GPG private key (supporting optional passphrase protection via loopback pinentry) and unseals Vault via loopback API (`127.0.0.1:8200`).
   - **`awskms`**: Configures native AWS KMS auto-unseal block.
   - **`gcpckms`**: Configures native GCP Cloud KMS auto-unseal block.
3. **Automated Secret Seeding**:
   - Creates Kubernetes Secrets (`vault-unseal-keys` and `vault-gpg-key`) conditionally when operating in `sidecar` mode.

## GPG & PGP Key Setup Guide

When running in `sidecar` mode, Vault unseal key shares must be encrypted with a PGP public key, and the corresponding GPG private key must be supplied so the sidecar container can decrypt them dynamically.

### 1. Generating a New GPG Keypair

If you do not already have a GPG keypair for Vault unsealing, generate one using GnuPG:

```bash
gpg --full-generate-key
```
- Select **RSA and RSA (default)**.
- Choose key size (e.g., **4096** bits).
- Specify key validity (e.g., `0` for non-expiring or custom duration).
- Enter Real Name (e.g., `Vault Unseal Key`) and Email.
- Set a strong **passphrase** (or leave empty if passphrase-less).

Note your GPG Key ID or email (e.g., `vault-unseal@domain.local` or Key ID `0x123456789ABCDEF0`).

### 2. Exporting PGP Public Keys for Vault Initialization

During Vault initialization (`vault operator init -pgp-keys=...`), Vault requires **base64-encoded binary PGP public keys**.

Export your public key in binary format and encode it to base64:

```bash
gpg --export vault-unseal@domain.local | base64 | tr -d '\n'
```

If initializing Vault via PGP keys, pass these base64 strings into the Vault operator init call or Terraform variable `pgp_encrypted_keys`.

### 3. Exporting the GPG Private Key for the Sidecar

Export the ASCII-armored private key to a local file (e.g., `vault-unseal-private.asc`):

```bash
gpg --armor --export-secret-keys vault-unseal@domain.local > vault-unseal-private.asc
```

Set the path to this file in `terraform.tfvars`:
```hcl
gpg_private_key_path = "./vault-unseal-private.asc"
```

### 4. Configuring Passphrase Protection

- **Passphrase-Protected Private Keys**: If your GPG private key is encrypted with a passphrase, specify it in `terraform.tfvars`:
  ```hcl
  gpg_key_passphrase = "YourStrongPassphraseHere"
  ```
  The sidecar container script automatically uses `--pinentry-mode loopback` and `--passphrase-file /vault/gpg/passphrase` to decrypt keys non-interactively.
- **Unpassphrased Private Keys**: Leave `gpg_key_passphrase = ""` in `terraform.tfvars`. The script detects the empty file and executes standard `gpg --decrypt --batch`.

### 5. Using Existing GPG Keys

If using an existing GPG key from your keyring:
1. List keys: `gpg --list-secret-keys --keyid-format LONG`
2. Export public key: `gpg --export <KEY-ID> | base64 | tr -d '\n'`
3. Export private key: `gpg --armor --export-secret-keys <KEY-ID> > ./vault-unseal-private.asc`

## Project Structure

- `versions.tf`: Provider requirements (`helm`, `kubernetes`).
- `variables.tf`: Input variable definitions and validation rules.
- `main.tf`: Kubernetes namespace, secrets, Helm release, dynamic local variables, and sidecar script.
- `outputs.tf`: Deployment metadata outputs.
- `terraform.tfvars.example`: Example variable configuration.

## Quick Start

1. **Clone or Extract Archive**:
   Extract all files into a directory.

2. **Configure Variables**:
   Copy `terraform.tfvars.example` to `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. **Initialize & Deploy**:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Verify Deployment**:
   ```bash
   kubectl get pods -n vault
   kubectl logs -n vault pod/vault-0 -c vault-auto-unsealer
   ```
