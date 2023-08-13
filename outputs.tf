output "network_interface_id" {
  value = var.ha_enabled ? aws_network_interface.this[0].id : aws_instance.this[0].primary_network_interface_id
}
