#!/bin/bash
# shellcheck disable=SC2015,SC2016,SC2034

# Shellcheck issue descriptions:
#
# - SC2015: <condition> && <operation> || true
# - SC2016: annoying warning about using single quoted strings with characters used for interpolation;
# - SC2034: triggers a bug on the `-v` test (see https://git.io/Jenyu).

set -o errexit
set -o pipefail
set -o nounset

# VARIABLES/CONSTANTS ##########################################################

v_bpool_name=
v_bpool_tweaks=              # see defaults below for format
v_encrypt_rpool=             # 0=false, 1=true
v_os_temp_installation_dir=
v_passphrase=
v_rpool_name=
v_rpool_tweaks=              # see defaults below for format
declare -a v_selected_disks  # (/dev/by-id/disk_id, ...)
v_swap_size=                 # integer
declare -A v_system_disks    # [sdX]=disk_id
v_temp_volume_device=        # /dev/zdN

c_default_bpool_tweaks="-o ashift=12"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_mount_dir=/mnt

# HELPER FUNCTIONS #############################################################

# shellcheck disable=SC2120 # allow parameters passing even if no calls pass any
function print_step_info_header {
  echo -n "
###############################################################################
# ${FUNCNAME[1]}"

  [[ "${1:-}" != "" ]] && echo -n " $1" || true

  echo "
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

function chroot_execute {
  chroot $c_mount_dir bash -c "$1"
}

# PROCEDURE STEP FUNCTIONS #####################################################

function display_help_and_exit {
  local help
  help='Usage: install-zfs.sh [-h|--help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_SELECTED_DISKS         : base name of the devices to create the pool on (eg. `sda,sdc`)
- ZFS_ENCRYPT_RPOOL          : set 1 to encrypt the pool
- ZFS_PASSPHRASE
- ZFS_BPOOL_NAME
- ZFS_RPOOL_NAME
- ZFS_BPOOL_TWEAKS           : boot pool options to set on creation (defaults to `'"$c_default_bpool_tweaks"'`)
- ZFS_RPOOL_TWEAKS           : root pool options to set on creation (defaults to `'"$c_default_rpool_tweaks"'`)
- ZFS_NO_INFO_MESSAGES       : set 1 to skip informational messages
- ZFS_SWAP_SIZE              : swap size (integer number); set 0 for no swap

Note that the pools are created using the disk ids, also when $ZFS_SELECTED_DISKS is set.

When installing the O/S via $ZFS_OS_INSTALLATION_SCRIPT, the script will prepare an ext4 partition on a ZFS volume, to install the O/S on, and execute the script with administrative permissions.
The requisites are:

- the O/S must be installed on the ext4 partition (`/dev/zd16`);
- the partition must be dismountable (e.g. no file locks, no swap etc.);
- at the end of the O/S installation, the script must print a line to stdout (`echo` will do) with the mountpoint where the O/S has been installed.
'

  echo "$help"

  exit 0
}

function activate_debug {
  print_step_info_header

  exec 5> "$(dirname "$(mktemp)")/install-zfs.log"
  BASH_XTRACEFD="5"
  set -x
}

function check_prerequisites {
  print_step_info_header

  if [[ ! -d /sys/firmware/efi ]]; then
    echo 'System firmware directory not found; make sure to boot in EFI mode!'
    exit 1
  elif [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  elif [[ "${ZFS_OS_INSTALLATION_SCRIPT:-}" != "" && ! -x "$ZFS_OS_INSTALLATION_SCRIPT" ]]; then
    echo "The custom O/S installation script provided doesn't exist or is not executable!"
    exit 1
  fi
}

function display_intro_banner {
  print_step_info_header

  local dialog_message='Hello!

This script will prepare the ZFS pools on the system, install Ubuntu, and configure the boot.

In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi
}

function find_disks {
  print_step_info_header

  declare -A removable_devices # [sdX]=1

  for device in /sys/block/sd*; do
    if [[ -e "$device" ]]; then
      (udevadm info --query=property --path="$device" | grep -q "^ID_BUS=usb") && removable_devices["$(basename "$device")"]=1
    fi
  done

  for disk_id in /dev/disk/by-id/*; do
    local device_symlink
    local device_basename

    device_symlink="$(readlink "$disk_id")"
    device_basename="$(basename "$device_symlink")"

    # Multiple entries can be present for each device; this is acceptables; only the last of each
    # is retained.
    #
    if [[ $device_basename =~ ^(sd[a-z]+|nvme[0-9]n[0-9])$ ]] && [[ ! -v removable_devices["$device_basename"] ]]; then
      v_system_disks["$device_basename"]=$disk_id
    fi
  done

  print_variables v_system_disks
}

function select_disks {
  print_step_info_header

  local selected_devices

  if [[ "${ZFS_SELECTED_DISKS:-}" != "" ]]; then
    selected_devices="${ZFS_SELECTED_DISKS//,/$'\n'}"
  else
    local menu_entries_option=()
    local sorted_device_names # sdX ...
    declare -A mounted_devices # [sdX]=1

    sorted_device_names="$(echo "${!v_system_disks[@]}" | perl -ane 'print join(" ", sort(@F))')" # ugly :,-(

    for filesystem in $(df | tail -n +2 | awk '{print $1}'); do
      local mounted_device
      mounted_device="$(lsblk -no pkname "$filesystem" 2> /dev/null || true)"

      [[ "$mounted_device" != "" ]] && mounted_devices["$mounted_device"]=1
    done

    for device_name in $sorted_device_names; do
      if [[ ! -v mounted_devices["$device_name"] ]]; then
        menu_entries_option+=("$device_name")
        menu_entries_option+=("${v_system_disks[$device_name]}")
        menu_entries_option+=(OFF)
      fi
    done

    local dialog_message="Select the ZFS devices (multiple selections will be in mirror).

Devices with mounted partitions are not displayed!
"
    selected_devices=$(
      whiptail --checklist --separate-output "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3
    )
  fi

  while read -r device_name; do
    v_selected_disks+=("/dev/disk/by-id/${v_system_disks[$device_name]}")
  done <<< "$selected_devices"

  print_variables v_selected_disks
}

function ask_encryption {
  print_step_info_header

  if [[ "${ZFS_ENCRYPT_RPOOL:-}" == "" ]]; then
    if whiptail --yesno 'Do you want to encrypt the root pool?' 30 100; then
      v_encrypt_rpool=1
    fi
  elif [[ "${ZFS_ENCRYPT_RPOOL:-}" != "0" ]]; then
    v_encrypt_rpool=1
  fi

  if [[ $v_encrypt_rpool == "1" ]]; then
    if [[ ${ZFS_PASSPHRASE:-} != "" ]]; then
      v_passphrase="$ZFS_PASSPHRASE"
    else
      local passphrase_invalid_message=
      local passphrase_repeat=-

      while [[ "$v_passphrase" != "$passphrase_repeat" || ${#v_passphrase} -lt 8 ]]; do
        v_passphrase=$(whiptail --passwordbox "${passphrase_invalid_message}Please enter the passphrase (8 chars min.):" 30 100 3>&1 1>&2 2>&3)
        passphrase_repeat=$(whiptail --passwordbox "Please repeat the passphrase:" 30 100 3>&1 1>&2 2>&3)

        passphrase_invalid_message="Passphrase too short, or not matching! "
      done
    fi
  fi

  print_variables v_passphrase
}

function ask_swap_size {
  print_step_info_header

  if [[ ${ZFS_SWAP_SIZE:-} != "" ]]; then
    v_swap_size=$ZFS_SWAP_SIZE
  else
   local swap_size_invalid_message=

    while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
      v_swap_size=$(whiptail --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):" 30 100 2 3>&1 1>&2 2>&3)

      swap_size_invalid_message="Invalid swap size! "
    done
  fi

  print_variables v_swap_size
}

function ask_pool_names {
  print_step_info_header

  if [[ ${ZFS_BPOOL_NAME:-} != "" ]]; then
    v_bpool_name=$ZFS_BPOOL_NAME
  else
    local bpool_name_invalid_message=

    while [[ ! $v_bpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
      v_bpool_name=$(whiptail --inputbox "${bpool_name_invalid_message}Insert the name for the boot pool" 30 100 bpool 3>&1 1>&2 2>&3)

      bpool_name_invalid_message="Invalid pool name! "
    done
  fi

  if [[ ${ZFS_RPOOL_NAME:-} != "" ]]; then
    v_rpool_name=$ZFS_RPOOL_NAME
  else
    local rpool_name_invalid_message=

    while [[ ! $v_rpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
      v_rpool_name=$(whiptail --inputbox "${rpool_name_invalid_message}Insert the name for the root pool" 30 100 rpool 3>&1 1>&2 2>&3)

      rpool_name_invalid_message="Invalid pool name! "
    done
  fi

  print_variables v_bpool_name v_rpool_name
}

function ask_pool_tweaks {
  print_step_info_header

  if [[ ${ZFS_BPOOL_TWEAKS:-} != "" ]]; then
    v_bpool_tweaks=$ZFS_BPOOL_TWEAKS
  else
    v_bpool_tweaks=$(whiptail --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)
  fi

  if [[ ${ZFS_RPOOL_TWEAKS:-} != "" ]]; then
    v_rpool_tweaks=$ZFS_RPOOL_TWEAKS
  else
    v_rpool_tweaks=$(whiptail --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)
  fi

  print_variables v_bpool_tweaks v_rpool_tweaks
}

function install_zfs_module {
  print_step_info_header

  echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

  add-apt-repository --yes ppa:jonathonf/zfs
  apt install --yes zfs-dkms

  systemctl stop zfs-zed
  modprobe -r zfs
  modprobe zfs
  systemctl start zfs-zed
}

function prepare_disks {
  print_step_info_header

  # PARTITIONS #########################

  for selected_disk in "${v_selected_disks[@]}"; do
    # More thorough than `sgdisk --zap-all`.
    #
    wipefs --all "$selected_disk"

    sgdisk -n1:1M:+512M   -t1:EF00 "$selected_disk" # EFI boot
    sgdisk -n2:0:+512M    -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:0        -t3:BF01 "$selected_disk" # Root pool
  done

  # The partition symlinks are not immediately created, so we wait.
  #
  # There is still a hard to reproduce issue where `zpool create rpool` fails with:
  #
  #   cannot resolve path '/dev/disk/by-id/<disk_id>-part2'
  #
  # It's a race condition (waiting more solves the problem), but it's not clear which exact event
  # to wait on.
  # There's no relation to the missing symlinks - the issue also happened for partitions that
  # didn't need a `sleep`.
  #
  # Using `partprobe` doesn't solve the problem.
  #
  # Replacing the `-L` test with `-e` is a potential solution, but couldn't check on the
  # destination files, due to the nondeterministic nature of the problem.
  #
  # Current attempt: `udevadm`, which should be the cleanest approach.
  #
  udevadm settle

  # for disk in "${v_selected_disks[@]}"; do
  #   part_indexes=(1 2 3)
  #
  #   for part_i in "${part_indexes[@]}"; do
  #     while [[ ! -L "${disk}-part${part_i}" ]]; do sleep 0.25; done
  #   done
  # done

  for selected_disk in "${v_selected_disks[@]}"; do
    mkfs.fat -F 32 -n EFI "${selected_disk}-part1"
  done

  # POOL OPTIONS #######################

  local encryption_options=()
  local rpool_disks_partitions=()
  local bpool_disks_partitions=()

  if [[ $v_encrypt_rpool == "1" ]]; then
    encryption_options=(-O "encryption=on" -O "keylocation=prompt" -O "keyformat=passphrase")
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    rpool_disks_partitions+=("${selected_disk}-part3")
    bpool_disks_partitions+=("${selected_disk}-part2")
  done

  if [[ ${#v_selected_disks[@]} -gt 1 ]]; then
    local pools_mirror_option=mirror
  else
    local pools_mirror_option=
  fi

  # POOLS CREATION #####################

  # See https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS for the details.
  #
  # `-R` creates an "Alternate Root Point", which is lost on unmount; it's just a convenience for a temporary mountpoint;
  # `-f` force overwrite partitions is existing - in some cases, even after wipefs, a filesystem is mistakenly recognized
  # `-O` set filesystem properties on a pool (pools and filesystems are distincted entities, however, a pool includes an FS by default).
  #
  # Stdin is ignored if the encryption is not set (and set via prompt).
  #
  # shellcheck disable=SC2086 # unquoted tweaks variable (splitting is expected)
  echo -n "$v_passphrase" | zpool create \
    "${encryption_options[@]}" \
    $v_rpool_tweaks \
    -O devices=off -O mountpoint=/ -R "$c_mount_dir" -f \
    "$v_rpool_name" $pools_mirror_option "${rpool_disks_partitions[@]}"

  # `-d` disable all the pool features (not used here);
  #
  # shellcheck disable=SC2086 # see previous command
  zpool create \
    $v_bpool_tweaks \
    -O devices=off -O mountpoint=/boot -R "$c_mount_dir" -f \
    "$v_bpool_name" $pools_mirror_option "${bpool_disks_partitions[@]}"

  # SWAP ###############################

  if [[ $v_swap_size -gt 0 ]]; then
    zfs create \
      -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
      -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
      "$v_rpool_name/swap"

    mkswap -f "/dev/zvol/$v_rpool_name/swap"
  fi
}

function create_temp_volume {
  zfs create -V 10G "$v_rpool_name/os-install-temp"

  v_temp_volume_device=$(readlink -f "/dev/zvol/$v_rpool_name/os-install-temp")

  sgdisk -n1:0:0 -t1:8300 "$v_temp_volume_device"
}

function install_operating_system {
  print_step_info_header

  local dialog_message='The Ubuntu GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Something Else` -> `Continue`
- select `'"$v_temp_volume_device"'` -> `Change`
  - set `Use as:` to `Ext4`
  - check `Format the partition:`
  - set `Mount point` to `/` -> `OK`
- `Install Now` -> `Continue`
- at the end, choose `Continue Testing`
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  ubiquity --no-bootloader

  swapoff -a

  v_os_temp_installation_dir=/target
}

function custom_install_operating_system {
  print_step_info_header

  v_os_temp_installation_dir="$(sudo "$ZFS_OS_INSTALLATION_SCRIPT" | tail -n 1)"
}

function sync_os_temp_installation_dir_to_rpool {
  # Extended attributes are not used on a standard Ubuntu installation, however, this needs to be generic.
  # There isn't an exact way to filter out filenames in the rsync output, so we just use a good enough heuristic.
  # ❤️ Perl ❤️
  #
  rsync -avX --exclude=/swapfile --info=progress2 --no-inc-recursive --human-readable "$v_os_temp_installation_dir/" "$c_mount_dir" |
    perl -lane 'BEGIN { $/ = "\r"; $|++ } $F[1] =~ /(\d+)%$/ && print $1' |
    whiptail --gauge "Syncing the installed O/S to the root pool FS..." 30 100 0

  umount "$v_os_temp_installation_dir"
}

function destroy_temp_volume {
  zfs destroy "$v_rpool_name/os-install-temp"
}

function prepare_jail {
  print_step_info_header

  for virtual_fs_dir in proc sys dev; do
    mount --rbind "/$virtual_fs_dir" "$c_mount_dir/$virtual_fs_dir"
  done

  chroot_execute 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
}

function install_zfs_0.8_packages {
  print_step_info_header

  chroot_execute "add-apt-repository --yes ppa:jonathonf/zfs"
  chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
  chroot_execute "apt install --yes zfs-initramfs zfs-dkms grub-efi-amd64-signed shim-signed"
}

function install_and_configure_bootloader {
  print_step_info_header

  chroot_execute "echo PARTUUID=$(blkid -s PARTUUID -o value "${v_selected_disks[0]}-part1") /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 > /etc/fstab"

  chroot_execute "mkdir -p /boot/efi"
  chroot_execute "mount /boot/efi"

  chroot_execute "grub-install"

  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX=\")/\${1}root=ZFS=$v_rpool_name /'    /etc/default/grub"
  chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'                                    >> /etc/default/grub"

  # Simplify debugging, but most importantly, disable the boot graphical interface: text mode is
  # required for the passphrase to be asked, otherwise, the boot stops with a confusing error
  # "filesystem [...] can't be mounted: Permission Denied".
  #
  chroot_execute "perl -i -pe 's/(GRUB_TIMEOUT_STYLE=hidden)/#\$1/'                        /etc/default/grub"
  chroot_execute "perl -i -pe 's/^(GRUB_HIDDEN_.*)/#\$1/'                                  /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_TIMEOUT=)0/\${1}5/'                                 /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX_DEFAULT=.*)quiet/\$1/'                /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX_DEFAULT=.*)splash/\$1/'               /etc/default/grub"
  chroot_execute "perl -i -pe 's/#(GRUB_TERMINAL=console)/\$1/'                            /etc/default/grub"
  chroot_execute 'echo "GRUB_RECORDFAIL_TIMEOUT=5"                                      >> /etc/default/grub'

  # A gist on GitHub (https://git.io/JenXF) manipulates `/etc/grub.d/10_linux` in order to allow
  # GRUB support encrypted ZFS partitions. This hasn't been a requirement in all the tests
  # performed on 18.04, but it's better to keep this reference just in case.

  chroot_execute "update-grub"

  chroot_execute "umount /boot/efi"
}

function clone_efi_partition {
  print_step_info_header

  local selected_disk_i=2

  for selected_disk in "${v_selected_disks[@]:1}"; do
    dd if="${v_selected_disks[0]}-part2" of="${selected_disk}-part2"
    efibootmgr --create --disk "${selected_disk}" --part 2 --label "ubuntu-$selected_disk_i" --loader '\EFI\ubuntu\grubx64.efi'
    ((selected_disk_i += 1))
  done
}

function configure_boot_pool_import {
  print_step_info_header

  chroot_execute "cat > /etc/systemd/system/zfs-import-$v_bpool_name.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none $v_bpool_name

[Install]
WantedBy=zfs-import.target
UNIT"

  chroot_execute "systemctl enable zfs-import-$v_bpool_name.service"

  chroot_execute "zfs set mountpoint=legacy $v_bpool_name"
  chroot_execute "echo $v_bpool_name /boot zfs nodev,relatime,x-systemd.requires=zfs-import-$v_bpool_name.service 0 0 >> /etc/fstab"
}

function configure_remaining_settings {
  print_step_info_header

  [[ $v_swap_size -gt 0 ]] && chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab" || true
  chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"
}

function prepare_for_system_exit {
  print_step_info_header

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_mount_dir/$virtual_fs_dir"
  done

  # In one case, a second unmount was required. In this contenxt, bind mounts are not safe, so,
  # expecting unclean behaviors, we perform a second unmount if the mounts are still present.
  #
  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_mount_dir/$virtual_fs_dir"
    fi
  done

  zpool export -a
}

function display_exit_banner {
  print_step_info_header

  local dialog_message="The system has been successfully prepared and installed.

You now need to perform a hard reset, then enjoy your ZFS system :-)"

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi
}

# MAIN #########################################################################

if [[ $# -ne 0 ]]; then
  display_help_and_exit
fi

activate_debug
check_prerequisites
display_intro_banner
find_disks

select_disks
ask_encryption
ask_swap_size
ask_pool_names
ask_pool_tweaks

install_zfs_module
prepare_disks

create_temp_volume
if [[ "${ZFS_OS_INSTALLATION_SCRIPT:-}" == "" ]]; then
  install_operating_system
else
  custom_install_operating_system
fi
sync_os_temp_installation_dir_to_rpool
destroy_temp_volume

prepare_jail
install_zfs_0.8_packages
install_and_configure_bootloader
clone_efi_partition
configure_boot_pool_import
configure_remaining_settings

prepare_for_system_exit
display_exit_banner
