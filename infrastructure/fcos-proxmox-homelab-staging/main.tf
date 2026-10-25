terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.96.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true # Set false if you have valid TLS certs
}

locals {
  ignition_configs = [for i in range(var.vm_count) : file("${path.module}/ignition-node-${i + 1}.json")]
}

# Upload ignition configs as snippets to Proxmox
resource "proxmox_virtual_environment_file" "ignition" {
  count        = var.vm_count
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.ignition_configs[count.index]
    file_name = "ignition-node-${count.index + 1}.json"
  }
}

resource "proxmox_virtual_environment_vm" "fcos" {
  count     = var.vm_count
  name      = "fcos-cp-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = 721 + count.index
  on_boot   = true
  timeout_clone = 36000

  clone {
    vm_id = 9002
    full  = true
  }

  agent {
    enabled = var.agent_enabled
    trim    = true
  }

  lifecycle {
    ignore_changes = [clone, agent]
  }

  cpu {
    cores      = 16
    type       = "host"
    hotplugged = 0
    numa       = true
  }

  memory {
    dedicated = 20480
    floating  = 20480
  }

  disk {
    datastore_id = var.osd_datastores[count.index]
    interface    = "virtio0"
    size         = 200
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "none"      # avoid host page cache for Ceph OSD block device
    file_format  = "raw"       # required — thick LVM only supports raw
  }

  disk {
    datastore_id = var.osd_datastores[count.index]
    interface    = "virtio1"
    size         = var.osd_disk_size_gb[count.index]
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "none"      # avoid host page cache for Ceph OSD block device
    file_format  = "raw"       # required — thick LVM only supports raw
  }

  hotplug = "cpu,memory,disk,network,usb"

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Physical disk passthrough via kvm_arguments
  kvm_arguments = "-fw_cfg name=opt/com.coreos/config,file=/var/lib/vz/snippets/ignition-node-${count.index + 1}.json"
  
  operating_system {
    type = "l26"
  }

  serial_device {}
}
