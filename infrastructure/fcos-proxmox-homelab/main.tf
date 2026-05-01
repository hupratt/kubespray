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

  clone {
    vm_id = 9000
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
    datastore_id = "local-lvm"
    interface    = "virtio0"
    size         = 80
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "writeback"
  }

  hotplug = "cpu,memory,disk,network,usb"

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Physical disk passthrough via kvm_arguments
  kvm_arguments = "-device virtio-blk-pci,drive=drive0 -drive file=${var.passthrough_disks[count.index]},format=raw,if=none,id=drive0 -fw_cfg name=opt/com.coreos/config,file=/var/lib/vz/snippets/ignition-node-${count.index + 1}.json"

  operating_system {
    type = "l26"
  }

  serial_device {}
}
