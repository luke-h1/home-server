output "server_id" {
  value       = hcloud_server.main.id
  description = "Hetzner server ID."
}

output "server_ipv4" {
  value       = hcloud_server.main.ipv4_address
  description = "Public IPv4 address."
}

output "server_ipv6" {
  value       = hcloud_server.main.ipv6_address
  description = "Public IPv6 address."
}

output "server_status" {
  value       = hcloud_server.main.status
  description = "Server status from Hetzner API."
}

output "server_type" {
  value       = hcloud_server.main.server_type
  description = "Hetzner server type (fixed to CX23 / cx23)."
}

output "ssh_command" {
  value       = "ssh root@${hcloud_server.main.ipv4_address}"
  description = "Example SSH command as root using the default SSH key on the server."
}

output "data_volume_id" {
  value       = var.attach_data_volume ? hcloud_volume.data[0].id : null
  description = "Volume ID when attach_data_volume is enabled."
}
