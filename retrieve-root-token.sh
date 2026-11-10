#!/usr/bin/env bash
set -euo pipefail

# Configuration (overridable via arguments or environment variables)
NAMESPACE="${1:-${VAULT_NAMESPACE:-vault}}"
SECRET_NAME="${2:-${VAULT_SECRET:-vault-unseal-keys}}"

echo "Fetching PGP-encrypted root token from Secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..." >&2

ENCRYPTED_TOKEN=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.root_token_pgp}' 2>/dev/null || true)

if [ -z "$ENCRYPTED_TOKEN" ] || [ "$ENCRYPTED_TOKEN" = "null" ]; then
  echo "Error: 'root_token_pgp' is empty or missing in Secret '${SECRET_NAME}'." >&2
  echo "Ensure Vault has been auto-initialized and the secret has been populated." >&2
  exit 1
fi

# Secret .data is base64-encoded by Kubernetes.
# Vault's API also returns ciphertext as a base64 string.
# Layer 1: Decode Kubernetes secret .data layer
PAYLOAD=$(echo "$ENCRYPTED_TOKEN" | base64 -d)

# Layer 2: Decode Vault API base64 ciphertext to binary OpenPGP packets and decrypt with local GPG
GPG_ARGS=("--quiet")
if [ -n "${VAULT_GPG_PASSPHRASE:-}" ]; then
  GPG_ARGS+=("--batch" "--pinentry-mode" "loopback" "--passphrase" "$VAULT_GPG_PASSPHRASE")
fi

echo "$PAYLOAD" | base64 -d | gpg --decrypt "${GPG_ARGS[@]}"
