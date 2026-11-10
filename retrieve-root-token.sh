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

# Decrypt the root token using local GPG private key
echo "$ENCRYPTED_TOKEN" | base64 -d | gpg --decrypt --quiet
