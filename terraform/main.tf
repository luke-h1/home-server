provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "deploy" {
  name       = "${var.server_name}-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

locals {
  ssh_source_ips = length(var.ssh_allowed_cidrs) > 0 ? var.ssh_allowed_cidrs : ["0.0.0.0/0", "::/0"]
}

resource "hcloud_firewall" "main" {
  name = "${var.server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = local.ssh_source_ips
  }

  dynamic "rule" {
    for_each = var.allow_public_http ? ["80", "443"] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_server" "main" {
  name         = var.server_name
  image        = var.server_image
  server_type  = "cx23"
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.deploy.id]
  firewall_ids = [hcloud_firewall.main.id]

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "hcloud_volume" "data" {
  count     = var.attach_data_volume ? 1 : 0
  name      = "${var.server_name}-data"
  size      = var.data_volume_gb
  server_id = hcloud_server.main.id
  automount = true
  format    = "ext4"

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
