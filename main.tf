resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.namespace
  }
}

# 1. Kubernetes Secret for PGP-encrypted Unseal Keys
resource "kubernetes_secret" "vault_unseal_keys" {
  count = var.unseal_type == "sidecar" && length(var.pgp_encrypted_keys) >= 3 ? 1 : 0

  metadata {
    name      = "vault-unseal-keys"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "unseal_key_1_pgp" = var.pgp_encrypted_keys[0]
    "unseal_key_2_pgp" = var.pgp_encrypted_keys[1]
    "unseal_key_3_pgp" = var.pgp_encrypted_keys[2]
  }

  type = "Opaque"
}

# 2. Kubernetes Secret for GPG Private Key & Passphrase
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

locals {
  # Base Helm configuration with enforced UBI tags
  base_values = {
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
      }
    }
  }

  # Sidecar Unseal Configuration
  sidecar_values = var.unseal_type == "sidecar" ? {
    server = {
      extraVolumes = [
        {
          name   = "unseal-keys"
          secret = { secretName = "vault-unseal-keys" }
        },
        {
          name   = "gpg-key"
          secret = { secretName = "vault-gpg-key" }
        }
      ]
      extraContainers = [
        {
          name            = "vault-auto-unsealer"
          image           = "alpine:3.19"
          imagePullPolicy = "IfNotPresent"
          volumeMounts = [
            {
              name      = "unseal-keys"
              mountPath = "/vault/unseal"
              readOnly  = true
            },
            {
              name      = "gpg-key"
              mountPath = "/vault/gpg"
              readOnly  = true
            }
          ]
          command = [
            "/bin/sh",
            "-c",
            <<-EOF
            # Install runtime dependencies
            apk add --no-cache gnupg curl > /dev/null 2>&1

            # Setup GPG home directory
            export GNUPGHOME=/tmp/gnupg
            mkdir -p -m 700 "$GNUPGHOME"

            # Import passphrase-protected GPG private key using loopback pinentry
            if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
              gpg --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --import /vault/gpg/private.key > /dev/null 2>&1
            else
              gpg --batch --import /vault/gpg/private.key > /dev/null 2>&1
            fi

            echo "GPG key imported successfully. Starting Vault auto-unseal loop..."

            while true; do
              STATUS=$(curl -s -o /dev/null -w "%%{http_code}" http://127.0.0.1:8200/v1/sys/health)
              if [ "$STATUS" -eq 500 ]; then
                echo "Vault is sealed! Decrypting keys and submitting..."

                for file in /vault/unseal/unseal_key_*_pgp; do
                  if [ -f "$file" ]; then
                    if [ -f /vault/gpg/passphrase ] && [ -s /vault/gpg/passphrase ]; then
                      UNSEAL_KEY=$(cat "$file" | base64 -d | gpg --decrypt --batch --pinentry-mode loopback --passphrase-file /vault/gpg/passphrase --quiet 2>/dev/null)
                    else
                      UNSEAL_KEY=$(cat "$file" | base64 -d | gpg --decrypt --batch --quiet 2>/dev/null)
                    fi

                    if [ -n "$UNSEAL_KEY" ]; then
                      curl -s --request PUT --data "{"key": "$UNSEAL_KEY"}" http://127.0.0.1:8200/v1/sys/unseal > /dev/null
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
  } : {}

  # AWS KMS Configuration
  aws_kms_values = var.unseal_type == "awskms" ? {
    server = {
      ha = {
        config = <<-EOT
          seal "awskms" {
            region     = "${var.aws_kms_config != null ? var.aws_kms_config.region : ""}"
            kms_key_id = "${var.aws_kms_config != null ? var.aws_kms_config.kms_key_id : ""}"
          }
        EOT
      }
    }
  } : {}

  # GCP KMS Configuration
  gcp_kms_values = var.unseal_type == "gcpckms" ? {
    server = {
      ha = {
        config = <<-EOT
          seal "gcpckms" {
            project    = "${var.gcp_kms_config != null ? var.gcp_kms_config.project : ""}"
            region     = "${var.gcp_kms_config != null ? var.gcp_kms_config.region : ""}"
            key_ring   = "${var.gcp_kms_config != null ? var.gcp_kms_config.key_ring : ""}"
            crypto_key = "${var.gcp_kms_config != null ? var.gcp_kms_config.crypto_key : ""}"
          }
        EOT
      }
    }
  } : {}
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = var.helm_chart_version

  values = [
    yamlencode(
      merge(
        local.base_values,
        local.sidecar_values,
        local.aws_kms_values,
        local.gcp_kms_values
      )
    )
  ]

  depends_on = [
    kubernetes_secret.vault_unseal_keys,
    kubernetes_secret.vault_gpg_key
  ]
}
