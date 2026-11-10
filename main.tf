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

  # Sidecar Helm values using pre-baked custom image (GPG, BusyBox, curl, jq)
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

            echo "Starting Vault Zero-Touch Auto-Init & Auto-Unseal daemon..."

            K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)

            while true; do
              STATUS=$(wget -S --spider http://127.0.0.1:8200/v1/sys/health 2>&1 | awk '/HTTP\// {print $2}' | head -n 1)

              if [ "$STATUS" = "501" ]; then
                echo "Vault is uninitialized (HTTP 501). Executing auto-initialization with PGP root token encryption..."
                PUBKEY=$(cat /vault/pgp/pubkey.b64 | tr -d '\n\r')

                INIT_RESP=$(curl -s -X POST -H "Content-Type: application/json" \
                                 -d "{\"secret_shares\": 3, \"secret_threshold\": 3, \"pgp_keys\": [\"$PUBKEY\", \"$PUBKEY\", \"$PUBKEY\"], \"root_token_pgp_key\": \"$PUBKEY\"}" \
                                 http://127.0.0.1:8200/v1/sys/init)

                KEY1=$(echo "$INIT_RESP" | jq -r '.keys_base64[0]')
                KEY2=$(echo "$INIT_RESP" | jq -r '.keys_base64[1]')
                KEY3=$(echo "$INIT_RESP" | jq -r '.keys_base64[2]')
                ROOT_TOKEN_PGP=$(echo "$INIT_RESP" | jq -r '.root_token')

                echo "Vault initialized. Extracted keys and root token (length: $${#ROOT_TOKEN_PGP}). Saving to secret 'vault-unseal-keys'..."

                PATCH_PAYLOAD="{\"stringData\":{\"unseal_key_1_pgp\":\"$KEY1\",\"unseal_key_2_pgp\":\"$KEY2\",\"unseal_key_3_pgp\":\"$KEY3\",\"root_token_pgp\":\"$ROOT_TOKEN_PGP\"}}"
                curl -s -k \
                     -X PATCH \
                     -H "Authorization: Bearer $K8S_TOKEN" \
                     -H "Content-Type: application/strategic-merge-patch+json" \
                     -d "$PATCH_PAYLOAD" \
                     "https://kubernetes.default.svc/api/v1/namespaces/$NAMESPACE/secrets/vault-unseal-keys" > /dev/null 2>&1

                echo "Secret updated successfully with unseal keys and root token. Proceeding to unseal..."
                STATUS="500"
              fi

              if [ "$STATUS" = "500" ]; then
                echo "Vault is sealed! Decrypting keys and submitting..."

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
