variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to the kubeconfig file."
}

variable "namespace" {
  type        = string
  default     = "vault"
  description = "Kubernetes namespace where Vault will be deployed."
}

variable "helm_chart_version" {
  type        = string
  default     = "0.27.0"
  description = "Version of the HashiCorp Vault Helm chart."
}

variable "injector_image_tag" {
  type        = string
  default     = "1.7.6-ubi"
  description = "Vault Agent Injector container image tag."
}

variable "server_image_tag" {
  type        = string
  default     = "2.0.4-ubi"
  description = "Vault Server container image tag."
}

variable "unsealer_image" {
  type        = string
  default     = "your-registry.domain.com/vault/vault-unsealer:v1.0.0"
  description = "Custom sidecar container image with pre-installed GPG, BusyBox, curl, and jq for OpenShift SCC dynamic non-root UIDs."
}

variable "unseal_type" {
  type        = string
  default     = "sidecar"
  description = "Unseal strategy: 'sidecar', 'awskms', or 'gcpckms'."

  validation {
    condition     = contains(["sidecar", "awskms", "gcpckms"], var.unseal_type)
    error_message = "unseal_type must be one of: sidecar, awskms, gcpckms."
  }
}

variable "pgp_public_key_base64" {
  type        = string
  default     = ""
  description = "Base64-encoded PGP public key used by sidecar daemon to encrypt generated Vault unseal keys during auto-init."
}

variable "pgp_encrypted_keys" {
  type        = list(string)
  sensitive   = true
  default     = []
  description = "Optional pre-existing list of base64 PGP-encrypted unseal keys."
}

variable "gpg_private_key_path" {
  type        = string
  default     = ""
  description = "Path to local GPG private key file (.asc) used by sidecar daemon to decrypt PGP keys during auto-unseal."
}

variable "gpg_key_passphrase" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Passphrase protecting the GPG private key."
}

variable "aws_kms_config" {
  type = object({
    region     = string
    kms_key_id = string
  })
  default     = null
  description = "AWS KMS configuration parameters (required if unseal_type = 'awskms')."
}

variable "gcp_kms_config" {
  type = object({
    project    = string
    region     = string
    key_ring   = string
    crypto_key = string
  })
  default     = null
  description = "GCP Cloud KMS configuration parameters (required if unseal_type = 'gcpckms')."
}
