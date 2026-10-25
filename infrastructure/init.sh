
for disk in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
    umount $disk 2>/dev/null
    echo "=== Wiping $disk ==="

    # Zero the first 100 MiB
    dd if=/dev/zero of="$disk" bs=1M count=100 status=progress

    # Zero the last 100 MiB
    end_seek=$(( $(blockdev --getsz "$disk") / 2048 - 100 ))
    dd if=/dev/zero of="$disk" bs=1M seek="$end_seek" count=100 status=progress

    # Remove filesystem signatures
    wipefs -a "$disk"

    # Zap GPT/MBR partition tables
    sgdisk --zap-all "$disk"

    echo "=== Finished $disk ==="
    echo
done

# copy over the wwns
ls /dev/disk/by-id

# verify they are the right device blocks

for id in /dev/disk/by-id/wwn-0x644a84200ae191002e3f349a49cfdcd1 \
          /dev/disk/by-id/wwn-0x644a84200ae1910030a5e2ac0ef79d9a \
          /dev/disk/by-id/wwn-0x644a84200ae19100313dd87e0a67394d \
          /dev/disk/by-id/wwn-0x644a84200ae19100316aa1d266a3cd3a; do
  echo "$id -> $(readlink -f "$id")"
done


# Map: by-id disk -> desired VG name -> Proxmox storage name
declare -A DISKS=(
  ["wwn-0x644a84200ae191002e3f349a49cfdcd1"]="vg-osd1"
  ["wwn-0x644a84200ae1910030a5e2ac0ef79d9a"]="vg-osd2"
  ["wwn-0x644a84200ae19100313dd87e0a67394d"]="vg-osd3"
  ["wwn-0x644a84200ae19100316aa1d266a3cd3a"]="vg-osd4" 
)

for wwn in "${!DISKS[@]}"; do
  vg="${DISKS[$wwn]}"
  dev="/dev/disk/by-id/${wwn}"

  if [[ ! -e "$dev" ]]; then
    echo "!! $dev not found, skipping"
    continue
  fi

  real=$(readlink -f "$dev")
  echo "== $wwn -> $real -> $vg =="

  if vgs "$vg" &>/dev/null; then
    echo "   VG $vg already exists, skipping wipe/create"
  else
    echo "   wiping $real"
    blkdiscard "$real" 2>/dev/null || dd if=/dev/zero of="$real" bs=1M count=100 status=progress
    wipefs -a "$real"
    sgdisk --zap-all "$real"

    echo "   pvcreate + vgcreate"
    pvcreate "$dev"
    vgcreate "$vg" "$dev"
  fi

  if pvesm status | grep -q "^${vg}\b"; then
    echo "   Proxmox storage $vg already registered, skipping"
  else
    echo "   registering $vg with Proxmox"
    pvesm add lvm "$vg" --vgname "$vg" --content images
  fi
done
