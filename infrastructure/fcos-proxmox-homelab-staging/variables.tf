variable "proxmox_endpoint" {
  description = "Proxmox API endpoint (e.g. https://192.168.1.10:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox username (e.g. root@pam)"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "vm_count" {
  description = "Number of Fedora CoreOS VMs to create"
  type        = number
  default     = 3
}

variable "passthrough_disks" {
  type    = list(string)
  default = [
    "/dev/disk/by-id/wwn-0x500a0751e9c3c256",  # VM1 disk
    "/dev/disk/by-id/wwn-0x500a0751e9c200c6",  # VM2 disk
    "/dev/disk/by-id/wwn-0x500a0751e9c0b7a6",  # VM3 disk
  ]
}

variable "agent_enabled" {
  description = "Enable QEMU guest agent (set false for initial provisioning)"
  type        = bool
  default     = true
}

variable "osd_datastores" {
  description = "Thick-LVM Proxmox storage IDs, one per node, each backed by a dedicated physical disk"
  type    = list(string)
  default = ["vg-osd1", "vg-osd2", "vg-osd3"]
}

variable "osd_disk_size_gb" {
  description = "Size in GB for each node's OSD disk (match actual physical capacity)"
  type    = list(number)
  default = [1500, 1500, 1500]
}