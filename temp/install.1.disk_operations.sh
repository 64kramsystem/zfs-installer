#!/bin/bash

set -o errexit

# USER
#
disk1=/dev/disk/by-id/ata-WDC_WD82PURZ-85TEUY0_VDHVK11K
disk2=/dev/disk/by-id/ata-WDC_WD82PURZ-85TEUY0_VDHW2GKK
disk3=/dev/disk/by-id/ata-WDC_WD82PURZ-85TEUY0_VDHWN7YK

# VBOX
#
# disk1=/dev/disk/by-id/ata-VBOX_HARDDISK_VB0b1879ed-59cd65c6
# disk2=/dev/disk/by-id/ata-VBOX_HARDDISK_VB6c779716-dca795c1
# disk3=/dev/disk/by-id/ata-VBOX_HARDDISK_VBfdbfa1f1-56b96b14

zpool export -a || true

for disk in "$disk1" "$disk2" "$disk3"; do
  for diskpart in "$disk"-part*; do
    zpool labelclear -f "$diskpart" 2> /dev/null || true
  done
done

echo "##################################################################################"
echo "# Wiping disk (labels) and creating partitions..."
echo "##################################################################################"

for disk in "$disk1" "$disk2" "$disk3"; do
  wipefs --all "$disk"

  sgdisk -n1:1M:+768M -t1:EF00 "$disk"
  sgdisk -n2:0:+768M -t2:BF01 "$disk"
  sgdisk -n3:0:-12G -t3:BF01 "$disk"
  sgdisk -n4:0:0 -t4:8300 "$disk"
done

udevadm settle --timeout 10

echo "##################################################################################"
echo "# Creating EFI filesystems..."
echo "##################################################################################"

for disk in "$disk1" "$disk2" "$disk3"; do
  mkfs.fat -F 32 -n EFI "$disk"-part1
done

echo "##################################################################################"
echo "# O/S is installed here..."
echo "# Simulating the partition formatting..."
echo "##################################################################################"

mkfs.ext4 -F /dev/sda4

echo "##################################################################################"
echo "# Creating pools..."
echo "##################################################################################"

zpool create \
  -o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD -O devices=off -O mountpoint=/ \
  -R /mnt -f rpool raidz2 "$disk1"-part3 "$disk2"-part3 "$disk3"-part3

zpool create \
  -o ashift=12 -O devices=off -O mountpoint=/boot \
  -R /mnt -f bpool raidz2 "$disk1"-part2 "$disk2"-part2 "$disk3"-part2

echo "##################################################################################"
echo "# Resizing pools..."
echo "##################################################################################"

for disk in "$disk1" "$disk2" "$disk3"; do
  parted -s "$disk" rm 4
  parted -s "$disk" unit s resizepart 3 -- 100%
  udevadm settle --timeout 10
  zpool online -e rpool "$disk"-part3
done
