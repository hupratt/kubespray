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
  insecure = true
}

# Upload ignition config as snippet to Proxmox
resource "proxmox_virtual_environment_file" "ignition" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = file("${path.module}/ignition-node-4.json")
    file_name = "ignition-node-4.json"
  }
}

resource "proxmox_virtual_environment_vm" "fcos" {
  name      = "coreos-wk-4"
  node_name = var.proxmox_node
  vm_id     = 724
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
    datastore_id = "zfspool"
    interface    = "virtio0"
    size         = 80
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "writeback"
  }

  hotplug = "cpu,memory,disk,network,usb"

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  kvm_arguments = "-fw_cfg name=opt/com.coreos/config,file=/var/lib/vz/snippets/ignition-node-4.json"
  operating_system {
    type = "l26"
  }

  serial_device {}
}