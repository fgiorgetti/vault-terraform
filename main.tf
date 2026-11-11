resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.namespace
  }
}

# 1. RBAC Role enabling Sidecar to update vault-unseal-keys Secret via Kubernetes API
resource "kubernetes_role" "vault_secret_writer" {
  metadata {
    name      = "vault-secret-writer"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["vault-unseal-keys"]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding" "vault_secret_writer_binding" {
  metadata {
    name      = "vault-secret-writer-binding"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.vault_secret_writer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

# 2. Kubernetes Secret for PGP-encrypted Unseal Keys & Root Token (Dynamic runtime persistence)
resource "kubernetes_secret" "vault_unseal_keys" {
  metadata {
    name      = "vault-unseal-keys"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "unseal_key_1_pgp" = length(var.pgp_encrypted_keys) >= 1 ? var.pgp_encrypted_keys[0] : ""
    "unseal_key_2_pgp" = length(var.pgp_encrypted_keys) >= 2 ? var.pgp_encrypted_keys[1] : ""
    "unseal_key_3_pgp" = length(var.pgp_encrypted_keys) >= 3 ? var.pgp_encrypted_keys[2] : ""
    "root_token_pgp"   = ""
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }
}

# 3. Kubernetes Secret for GPG Private Key & Passphrase
resource "kubernetes_secret" "vault_gpg_key" {
  count = var.unseal_type == "sidecar" && var.gpg_private_key_path != "" ? 1 : 0

  metadata {
    name      = "vault-gpg-key"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "private.key" = file(var.gpg_private_key_path)
    "passphrase"  = var.gpg_key_passphrase
  }

  type = "Opaque"
}

# 4. Kubernetes Secret for Base64 PGP Public Key used during auto-init
resource "kubernetes_secret" "vault_pgp_pubkey" {
  count = var.unseal_type == "sidecar" && var.pgp_public_key_base64 != "" ? 1 : 0

  metadata {
    name      = "vault-pgp-pubkey"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "pubkey.b64" = var.pgp_public_key_base64
  }

  type = "Opaque"
}

locals {
  # Base Helm configuration enabling OpenShift SCC compliance & Raft integrated HA storage
  base_values = {
    global = {
      openshift = true
    }
    injector = {
      image = {
        tag = var.injector_image_tag
      }
    }
    server = {
      image = {
        tag = var.server_image_tag
      }
      ha = {
        enabled = true
        raft = {
          enabled   = true
          setNodeId = true
        }
      }
      dataStorage = {
        enabled = true
        size    = "10Gi"
      }
    }
  }

  # Sidecar Helm values using pre-baked custom image (GPG, wget, curl, jq, gawk)
  sidecar_values = {
    server = {
      volumes = [
        {
          name   = "unseal-keys"
          secret = { secretName = "vault-unseal-keys" }
        },
        {
          name   = "gpg-key"
          secret = { secretName = "vault-gpg-key" }
        },
        {
          name   = "pgp-pubkey"
          secret = { secretName = "vault-pgp-pubkey" }
        }
      ]
      extraContainers = [
        {
          name            = "vault-auto-unsealer"
          image           = var.unsealer_image
          imagePullPolicy = "IfNotPresent"
          env = [
            {
              name  = "GITHUB_ORG"
              value = var.github_organization
            },
            {
              name  = "GITHUB_ADMIN_USERS"
              value = join(" ", var.github_admin_users)
            }
          ]
          volumeMounts = [
            {
              name      = "unseal-keys"
              mountPath = "/vault/unseal"
              readOnly  = false
            },
            {
              name      = "gpg-key"
              mountPath = "/vault/gpg"
              readOnly  = true
            },
            {
              name      = "pgp-pubkey"
              mountPath = "/vault/pgp"
              readOnly  = true
            }
          ]
          command = [
            "/bin/sh",
            "-c",
            <<-EOF
            export GNUPGHOME=/tmp/gnupg
            mkdir -p -m 700 /tmp/gnupg

            if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
              gpg --homedir /tmp/gnupg --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --import /vault/gpg/private.key || true
            else
              gpg --homedir /tmp/gnupg --batch --import /vault/gpg/private.key || true
            fi

            POD_NAME=$(hostname)
            echo "Starting Vault Zero-Touch Auto-Init & Auto-Unseal daemon on $POD_NAME..."

            K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
            CONFIGURED="false"
            ROOT_TOKEN_PGP=""

            while true; do
              STATUS=$(wget -S --spider http://127.0.0.1:8200/v1/sys/health 2>&1 | awk '/HTTP\// {print $2}' | head -n 1)

              # Only vault-0 is permitted to initialize the cluster to avoid multi-replica race conditions
              if [ "$STATUS" = "501" ]; then
                if echo "$POD_NAME" | grep -q -- '-0$'; then
                  echo "Vault is uninitialized (HTTP 501) on leader ($POD_NAME). Executing auto-initialization..."
                  PUBKEY=$(cat /vault/pgp/pubkey.b64 | tr -d '\n\r')

                  INIT_RESP=$(curl -s -X POST -H "Content-Type: application/json" \
                                   -d "{\"secret_shares\": 3, \"secret_threshold\": 3, \"pgp_keys\": [\"$PUBKEY\", \"$PUBKEY\", \"$PUBKEY\"], \"root_token_pgp_key\": \"$PUBKEY\"}" \
                                   http://127.0.0.1:8200/v1/sys/init)

                  KEY1=$(echo "$INIT_RESP" | jq -r '.keys_base64[0]')
                  KEY2=$(echo "$INIT_RESP" | jq -r '.keys_base64[1]')
                  KEY3=$(echo "$INIT_RESP" | jq -r '.keys_base64[2]')
                  ROOT_TOKEN_PGP=$(echo "$INIT_RESP" | jq -r '.root_token')

                  echo "Vault initialized. Extracted keys and root token. Saving to Kubernetes secret 'vault-unseal-keys'..."

                  PATCH_PAYLOAD="{\"stringData\":{\"unseal_key_1_pgp\":\"$KEY1\",\"unseal_key_2_pgp\":\"$KEY2\",\"unseal_key_3_pgp\":\"$KEY3\",\"root_token_pgp\":\"$ROOT_TOKEN_PGP\"}}"
                  curl -s -k \
                       -X PATCH \
                       -H "Authorization: Bearer $K8S_TOKEN" \
                       -H "Content-Type: application/strategic-merge-patch+json" \
                       -d "$PATCH_PAYLOAD" \
                       "https://kubernetes.default.svc/api/v1/namespaces/$NAMESPACE/secrets/vault-unseal-keys" > /dev/null 2>&1

                  echo "Secret updated. Unsealing immediately using fresh in-memory keys..."
                  curl -s -X PUT -H "Content-Type: application/json" -d '{"reset": true}' http://127.0.0.1:8200/v1/sys/unseal > /dev/null 2>&1

                  for K in "$KEY1" "$KEY2" "$KEY3"; do
                    if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
                      UNSEAL_KEY=$(echo "$K" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --quiet 2>/dev/null | tr -d '\n\r')
                    else
                      UNSEAL_KEY=$(echo "$K" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --quiet 2>/dev/null | tr -d '\n\r')
                    fi

                    UNSEAL_OUT=$(curl -s -X PUT -H "Content-Type: application/json" -d "{\"key\": \"$UNSEAL_KEY\"}" http://127.0.0.1:8200/v1/sys/unseal)
                    echo "Initial unseal key submitted. Response: $UNSEAL_OUT"
                  done
                  sleep 3
                else
                  LEADER_STATUS=$(wget -S --spider http://vault-0.vault-internal:8200/v1/sys/health 2>&1 | awk '/HTTP\// {print $2}' | head -n 1)
                  if [ "$LEADER_STATUS" = "200" ] || [ "$LEADER_STATUS" = "500" ]; then
                    echo "Follower replica ($POD_NAME) is HTTP 501 and leader (vault-0) is active ($LEADER_STATUS). Joining Raft cluster..."
                    JOIN_RESP=$(curl -s -X POST -H "Content-Type: application/json" \
                                     -d '{"leader_api_addr": "http://vault-0.vault-internal:8200"}' \
                                     http://127.0.0.1:8200/v1/sys/storage/raft/join)
                    echo "Raft join result for $POD_NAME: $JOIN_RESP"
                  else
                    echo "Follower replica ($POD_NAME) is HTTP 501. Waiting for leader (vault-0) to become ready (current: $LEADER_STATUS)..."
                  fi
                fi
              fi

              if [ "$STATUS" = "500" ] || [ "$STATUS" = "503" ]; then
                echo "Vault is sealed (HTTP 500). Decrypting keys from mounted secret and submitting..."
                curl -s -X PUT -H "Content-Type: application/json" -d '{"reset": true}' http://127.0.0.1:8200/v1/sys/unseal > /dev/null 2>&1

                for file in /vault/unseal/unseal_key_*_pgp; do
                  if [ -f "$file" ]; then
                    if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
                      UNSEAL_KEY=$(cat "$file" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --quiet 2>/dev/null | tr -d '\n\r')
                    else
                      UNSEAL_KEY=$(cat "$file" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --quiet 2>/dev/null | tr -d '\n\r')
                    fi

                    if [ -n "$UNSEAL_KEY" ]; then
                      UNSEAL_OUT=$(curl -s -X PUT -H "Content-Type: application/json" -d "{\"key\": \"$UNSEAL_KEY\"}" http://127.0.0.1:8200/v1/sys/unseal)
                      echo "Unseal key submitted ($file). Response: $UNSEAL_OUT"
                    fi
                  fi
                done
                sleep 3
              fi

              # Refresh health status after potential init/unseal operations
              STATUS=$(wget -S --spider http://127.0.0.1:8200/v1/sys/health 2>&1 | awk '/HTTP\// {print $2}' | head -n 1)

              # Run post-unseal configuration on vault-0 (engines, policies, GitHub auth)
              if [ "$CONFIGURED" != "true" ] && { [ "$STATUS" = "200" ] || [ "$STATUS" = "429" ]; }; then
                if echo "$POD_NAME" | grep -q -- '-0$'; then
                  echo "Vault is unsealed (HTTP $STATUS). Executing post-unseal configuration on $POD_NAME..."

                  RAW_ROOT_TOKEN_PGP=""
                  if [ -n "$ROOT_TOKEN_PGP" ] && [ "$ROOT_TOKEN_PGP" != "null" ]; then
                    RAW_ROOT_TOKEN_PGP="$ROOT_TOKEN_PGP"
                  elif [ -f /vault/unseal/root_token_pgp ] && [ -s /vault/unseal/root_token_pgp ]; then
                    RAW_ROOT_TOKEN_PGP=$(cat /vault/unseal/root_token_pgp | tr -d '\n\r')
                  else
                    RAW_ROOT_TOKEN_PGP=$(curl -s -k \
                      -H "Authorization: Bearer $K8S_TOKEN" \
                      "https://kubernetes.default.svc/api/v1/namespaces/$NAMESPACE/secrets/vault-unseal-keys" \
                      | jq -r '.data.root_token_pgp // empty' | base64 -d 2>/dev/null | tr -d '\n\r')
                  fi

                  ROOT_TOKEN=""
                  if [ -n "$RAW_ROOT_TOKEN_PGP" ]; then
                    if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
                      ROOT_TOKEN=$(echo "$RAW_ROOT_TOKEN_PGP" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --quiet 2>/dev/null | tr -d '\n\r')
                    else
                      ROOT_TOKEN=$(echo "$RAW_ROOT_TOKEN_PGP" | base64 -d | gpg --homedir /tmp/gnupg --decrypt --batch --quiet 2>/dev/null | tr -d '\n\r')
                    fi
                  fi

                  if [ -n "$ROOT_TOKEN" ]; then
                    CONFIG_OK="true"

                    # 1. Enable KV-v2 secrets engine at /secret
                    MOUNTS=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" http://127.0.0.1:8200/v1/sys/mounts)
                    if ! echo "$MOUNTS" | jq -e '.["secret/"] != null or .data["secret/"] != null' >/dev/null 2>&1; then
                      echo "Enabling KV-v2 secrets engine at secret/..."
                      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                        -H "X-Vault-Token: $ROOT_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '{"type":"kv","options":{"version":"2"},"description":"KV Version 2 secret engine"}' \
                        http://127.0.0.1:8200/v1/sys/mounts/secret)
                      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                        echo "Failed to enable KV-v2 at secret/ (HTTP $HTTP_CODE)"
                        CONFIG_OK="false"
                      fi
                    else
                      echo "KV-v2 secrets engine at secret/ is already enabled."
                    fi

                    # 2. Enable PKI secrets engine at /pki
                    if ! echo "$MOUNTS" | jq -e '.["pki/"] != null or .data["pki/"] != null' >/dev/null 2>&1; then
                      echo "Enabling PKI secrets engine at pki/..."
                      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                        -H "X-Vault-Token: $ROOT_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '{"type":"pki","description":"PKI secret engine","config":{"max_lease_ttl":"87600h"}}' \
                        http://127.0.0.1:8200/v1/sys/mounts/pki)
                      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                        echo "Failed to enable PKI at pki/ (HTTP $HTTP_CODE)"
                        CONFIG_OK="false"
                      fi
                    else
                      echo "PKI secrets engine at pki/ is already enabled."
                    fi

                    # 3. Configure 'admin' policy (same permissions as root token)
                    echo "Configuring 'admin' ACL policy..."
                    ADMIN_POLICY_PAYLOAD=$(jq -n --arg policy 'path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }' '{"policy": $policy}')
                    HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT \
                      -H "X-Vault-Token: $ROOT_TOKEN" \
                      -H "Content-Type: application/json" \
                      -d "$ADMIN_POLICY_PAYLOAD" \
                      http://127.0.0.1:8200/v1/sys/policies/acl/admin)
                    if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                      echo "Failed to configure 'admin' policy (HTTP $HTTP_CODE)"
                      CONFIG_OK="false"
                    fi

                    # 4. Configure 'secret-pki' policy for GitHub organization users
                    echo "Configuring 'secret-pki' ACL policy..."
                    USER_POLICY_HCL='path "secret" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "pki" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "pki/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }'
                    USER_POLICY_PAYLOAD=$(jq -n --arg policy "$USER_POLICY_HCL" '{"policy": $policy}')
                    HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT \
                      -H "X-Vault-Token: $ROOT_TOKEN" \
                      -H "Content-Type: application/json" \
                      -d "$USER_POLICY_PAYLOAD" \
                      http://127.0.0.1:8200/v1/sys/policies/acl/secret-pki)
                    if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                      echo "Failed to configure 'secret-pki' policy (HTTP $HTTP_CODE)"
                      CONFIG_OK="false"
                    fi

                    # 5. Enable GitHub authentication method and set as default in Vault UI (listing_visibility=unauth)
                    AUTH_METHODS=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" http://127.0.0.1:8200/v1/sys/auth)
                    if ! echo "$AUTH_METHODS" | jq -e '.["github/"] != null or .data["github/"] != null' >/dev/null 2>&1; then
                      echo "Enabling GitHub authentication method..."
                      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                        -H "X-Vault-Token: $ROOT_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '{"type":"github","description":"GitHub organization authentication","config":{"listing_visibility":"unauth"}}' \
                        http://127.0.0.1:8200/v1/sys/auth/github)
                      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                        echo "Failed to enable GitHub auth method (HTTP $HTTP_CODE)"
                        CONFIG_OK="false"
                      fi
                    else
                      echo "GitHub authentication method is already enabled. Tuning listing_visibility to 'unauth'..."
                      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                        -H "X-Vault-Token: $ROOT_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '{"listing_visibility":"unauth"}' \
                        http://127.0.0.1:8200/v1/sys/auth/github/tune)
                      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                        echo "Failed to tune GitHub auth method listing_visibility (HTTP $HTTP_CODE)"
                        CONFIG_OK="false"
                      fi
                    fi

                    # 6. Configure GitHub organization and user/admin mappings
                    if [ -n "$GITHUB_ORG" ]; then
                      echo "Configuring GitHub organization '$GITHUB_ORG' with 'secret-pki' default policy..."
                      GH_CONFIG_PAYLOAD=$(jq -n --arg org "$GITHUB_ORG" '{"organization": $org, "token_policies": ["default", "secret-pki"]}')
                      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                        -H "X-Vault-Token: $ROOT_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$GH_CONFIG_PAYLOAD" \
                        http://127.0.0.1:8200/v1/auth/github/config)
                      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                        echo "Failed to configure GitHub organization '$GITHUB_ORG' (HTTP $HTTP_CODE)"
                        CONFIG_OK="false"
                      fi

                      EXISTING_USERS=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" "http://127.0.0.1:8200/v1/auth/github/map/users?list=true" | jq -r '.data.keys[]? // empty')
                      for EXISTING_USER in $EXISTING_USERS; do
                        if ! echo " $GITHUB_ADMIN_USERS " | grep -q " $EXISTING_USER "; then
                          echo "Removing stale admin mapping for GitHub user '$EXISTING_USER'..."
                          curl -s -o /dev/null -X DELETE \
                            -H "X-Vault-Token: $ROOT_TOKEN" \
                            "http://127.0.0.1:8200/v1/auth/github/map/users/$EXISTING_USER"
                        fi
                      done

                      for ADMIN_USER in $GITHUB_ADMIN_USERS; do
                        echo "Assigning 'admin' policy to GitHub user '$ADMIN_USER'..."
                        GH_USER_PAYLOAD=$(jq -n '{"value": "admin"}')
                        HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X POST \
                          -H "X-Vault-Token: $ROOT_TOKEN" \
                          -H "Content-Type: application/json" \
                          -d "$GH_USER_PAYLOAD" \
                          "http://127.0.0.1:8200/v1/auth/github/map/users/$ADMIN_USER")
                        if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
                          echo "Failed to assign 'admin' policy to GitHub user '$ADMIN_USER' (HTTP $HTTP_CODE)"
                          CONFIG_OK="false"
                        fi
                      done
                    fi

                    unset ROOT_TOKEN

                    if [ "$CONFIG_OK" = "true" ]; then
                      echo "Vault post-unseal configuration completed successfully."
                      CONFIGURED="true"
                    else
                      echo "One or more configuration steps failed; will retry on next cycle."
                    fi
                  else
                    echo "Could not decrypt root token yet; will retry post-unseal configuration on next cycle."
                  fi
                fi
              fi

              sleep 15
            done
            EOF
          ]
        }
      ]
    }
  }

  # AWS KMS Helm values override
  aws_kms_values = {
    server = {
      ha = {
        enabled = true
        config  = <<-EOT
          seal "awskms" {
            region     = "${var.aws_kms_config != null ? var.aws_kms_config.region : ""}"
            kms_key_id = "${var.aws_kms_config != null ? var.aws_kms_config.kms_key_id : ""}"
          }
        EOT
      }
    }
  }

  # GCP KMS Helm values override
  gcp_kms_values = {
    server = {
      ha = {
        enabled = true
        config  = <<-EOT
          seal "gcpckms" {
            project    = "${var.gcp_kms_config != null ? var.gcp_kms_config.project : ""}"
            region     = "${var.gcp_kms_config != null ? var.gcp_kms_config.region : ""}"
            key_ring   = "${var.gcp_kms_config != null ? var.gcp_kms_config.key_ring : ""}"
            crypto_key = "${var.gcp_kms_config != null ? var.gcp_kms_config.crypto_key : ""}"
          }
        EOT
      }
    }
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = var.helm_chart_version

  values = compact([
    yamlencode(local.base_values),
    var.unseal_type == "sidecar" ? yamlencode(local.sidecar_values) : "",
    var.unseal_type == "awskms" ? yamlencode(local.aws_kms_values) : "",
    var.unseal_type == "gcpckms" ? yamlencode(local.gcp_kms_values) : ""
  ])

  depends_on = [
    kubernetes_secret.vault_unseal_keys,
    kubernetes_secret.vault_gpg_key,
    kubernetes_secret.vault_pgp_pubkey,
    kubernetes_role_binding.vault_secret_writer_binding
  ]
}
