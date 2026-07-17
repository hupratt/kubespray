output "vm_ids" {
  description = "VM IDs of the created Fedora CoreOS VMs"
  value       = proxmox_virtual_environment_vm.fcos[*].vm_id
}

output "vm_names" {
  description = "Names of the created Fedora CoreOS VMs"
  value       = proxmox_virtual_environment_vm.fcos[*].name
}
