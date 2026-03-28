variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token (https://console.hetzner.cloud → Security → API tokens)."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Path to the public key to install for root SSH (~ is expanded)."
}

variable "ssh_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Source CIDRs for SSH (port 22). Empty allows any IPv4/IPv6 (not recommended for production)."
}

variable "allow_public_http" {
  type        = bool
  default     = false
  description = "If true, allow inbound TCP 80 and 443 from the internet. Default false: use Cloudflare Tunnel (cloudflared) so the host does not need a public HTTP/S surface."
}

variable "server_name" {
  type        = string
  default     = "home-server"
  description = "Hetzner server and related resource name prefix."
}

variable "server_image" {
  type        = string
  default     = "ubuntu-24.04"
  description = "Hetzner image slug for the server OS."
}

variable "server_location" {
  type        = string
  default     = "hel1"
  description = "Hetzner location (datacenter)."

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil", "sin"], var.server_location)
    error_message = "server_location must be a supported Hetzner location slug."
  }
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Label applied to resources."

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be production, staging, or development."
  }
}

variable "attach_data_volume" {
  type        = bool
  default     = false
  description = "Attach a separate Hetzner volume and auto-mount it on the server."
}

variable "data_volume_gb" {
  type        = number
  default     = 50
  description = "Size of the data volume in GB when attach_data_volume is true."
}
