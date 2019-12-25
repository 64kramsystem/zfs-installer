#!/bin/bash
# shellcheck disable=SC2015,SC2016,SC2034

# Shellcheck issue descriptions:
#
# - SC2015: <condition> && <operation> || true
# - SC2016: annoying warning about using single quoted strings with characters used for interpolation
# - SC2034: triggers a bug on the `-v` test (see https://git.io/Jenyu)

set -o errexit
set -o pipefail
set -o nounset

# VARIABLES/CONSTANTS ##########################################################

# Variables set (indirectly) by the user

v_bpool_name=
v_bpool_tweaks=              # see defaults below for format
v_linux_distribution=        # Debian, Ubuntu, ...
v_linux_distribution_version=
v_encrypt_rpool=             # 0=false, 1=true
v_passphrase=
v_root_password=             # Debian-only
v_rpool_name=
v_rpool_tweaks=              # see defaults below for format
declare -a v_selected_disks  # (/dev/by-id/disk_id, ...)
v_swap_size=                 # integer
v_free_tail_space=           # integer

# Variables set during execution

v_temp_volume_device=        # /dev/zdN; scope: create_temp_volume -> install_operating_system
declare -a v_system_disks    # (/dev/by-id/disk_id, ...); scope: find_disks -> select_disk

# Constants

c_default_bpool_tweaks="-o ashift=12"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_zfs_mount_dir=/mnt
c_installed_os_data_mount_dir=/target
declare -A c_supported_linux_distributions=([Ubuntu]=18.04 [LinuxMint]=19 [Debian]=10 [elementary]=5.1)
c_temporary_volume_size=12G  # large enough; Debian, for example, takes ~8 GiB.

# HELPER FUNCTIONS #############################################################

# Chooses a function and invokes it depending on the O/S distribution.
#
# Example:
#
#   $ function install_jail_zfs_packages { :; }
#   $ function install_jail_zfs_packages_Debian { :; }
#   $ distro_dependent_invoke "install_jail_zfs_packages"
#
# If the distribution is `Debian`, the second will be invoked, otherwise, the
# first.
#
# If the function is invoked with `--noforce` as second parameter, and there is
# no matching function:
#
#   $ function update_zed_cache_Ubuntu { :; }
#   $ distro_dependent_invoke "install_jail_zfs_packages" --noforce
#
# then nothing happens. Without `--noforce`, this invocation will cause an
# error.
#
function distro_dependent_invoke {
  local distro_specific_fx_name="$1_$v_linux_distribution"

  if declare -f "$distro_specific_fx_name" > /dev/null; then
    "$distro_specific_fx_name"
  else
    if ! declare -f "$1" > /dev/null && [[ "${2:-}" == "--noforce" ]]; then
      : # do nothing
    else
      "$1"
    fi
  fi
}

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
  chroot $c_zfs_mount_dir bash -c "$1"
}

# PROCEDURE STEP FUNCTIONS #####################################################

function display_help_and_exit {
  local help
  help='Usage: install-zfs.sh [-h|--help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_SELECTED_DISKS         : full path of the devices to create the pool on, comma-separated
- ZFS_ENCRYPT_RPOOL          : set 1 to encrypt the pool
- ZFS_PASSPHRASE
- ZFS_DEBIAN_ROOT_PASSWORD
- ZFS_BPOOL_NAME
- ZFS_RPOOL_NAME
- ZFS_BPOOL_TWEAKS           : boot pool options to set on creation (defaults to `'$c_default_bpool_tweaks'`)
- ZFS_RPOOL_TWEAKS           : root pool options to set on creation (defaults to `'$c_default_rpool_tweaks'`)
- ZFS_NO_INFO_MESSAGES       : set 1 to skip informational messages
- ZFS_SWAP_SIZE              : swap size (integer); set 0 for no swap
- ZFS_FREE_TAIL_SPACE        : leave free space at the end of each disk (integer), for example, for a swap partition

- ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL : (debug) set 1 to skip installing the ZFS package on the live system; speeds up installation on preset machines

When installing the O/S via $ZFS_OS_INSTALLATION_SCRIPT, the root pool is mounted as `'$c_zfs_mount_dir'`; the requisites are:

1. the virtual filesystems must be mounted in `'$c_zfs_mount_dir'` (ie. `for vfs in proc sys dev; do mount --rbind /$vfs '$c_zfs_mount_dir'/$vfs; done`)
2. internet must be accessible while chrooting in `'$c_zfs_mount_dir'` (ie. `echo nameserver 8.8.8.8 >> '$c_zfs_mount_dir'/etc/resolv.conf`)
3. `'$c_zfs_mount_dir'` must be left in a dismountable state (e.g. no file locks, no swap etc.);
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

function print_preset_variables {
  cat <<SHELL
# Preset variables for rerun:

ZFS_SELECTED_DISKS=$(printf "%s," "${v_selected_disks[@]}" | sed 's/.$//') \\
ZFS_ENCRYPT_RPOOL=$v_encrypt_rpool ZFS_PASSPHRASE=$v_passphrase \\
ZFS_BPOOL_NAME=$v_bpool_name ZFS_RPOOL_NAME=$v_rpool_name \\
ZFS_BPOOL_TWEAKS="$v_bpool_tweaks" ZFS_RPOOL_TWEAKS="$v_rpool_tweaks" \\
ZFS_SWAP_SIZE=$v_swap_size ZFS_FREE_TAIL_SPACE=$v_free_tail_space
SHELL
}

function set_distribution_data {
  v_linux_distribution="$(lsb_release --id --short)"
  v_linux_version="$(lsb_release --release --short)"
}

function check_prerequisites {
  print_step_info_header

  # shellcheck disable=SC2116 # `=~ $(echo ...)` causes a warning; see https://git.io/Je2QP.
  #
  if [[ ! -d /sys/firmware/efi ]]; then
    echo 'System firmware directory not found; make sure to boot in EFI mode!'
    exit 1
  elif [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  elif [[ "${ZFS_OS_INSTALLATION_SCRIPT:-}" != "" && ! -x "$ZFS_OS_INSTALLATION_SCRIPT" ]]; then
    echo "The custom O/S installation script provided doesn't exist or is not executable!"
    exit 1
  elif [[ ! -v c_supported_linux_distributions["$v_linux_distribution"] ]]; then
    echo "This Linux distribution ($v_linux_distribution) is not supported!"
    exit 1
  elif [[ ! $v_linux_version =~ $(echo "^${c_supported_linux_distributions["$v_linux_distribution"]}\\b") ]]; then
    echo "This Linux distribution version ($v_linux_version) is not supported; version supported: ${c_supported_linux_distributions["$v_linux_distribution"]}"
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

  # In some freaky cases, `/dev/disk/by-id` is not up to date, so we refresh. One case is after
  # starting a VirtualBox VM that is a full clone of a suspended VM with snapshots.
  #
  udevadm trigger

  while read -r disk_id; do
    local device_info
    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"

    # The USB test may be redundant, due to `/dev/disk/by-id` prefixing removable devices with
    # `usb`, however, until certain, this is kept.
    #
    if echo "$device_info" | grep -q '^ID_TYPE=disk$' && ! echo "$device_info" | grep -q '^ID_BUS=usb$'; then
      v_system_disks+=("$disk_id")
    fi
  done <<< "$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi)-.+' -not -regex '.+-part[0-9]+$' | sort)"

  print_variables v_system_disks
}

function select_disks {
  print_step_info_header

  if [[ "${ZFS_SELECTED_DISKS:-}" != "" ]]; then
    mapfile -d, -t v_selected_disks < <(echo -n "$ZFS_SELECTED_DISKS")
  else
    local menu_entries_option=()
    local mounted_devices

    mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

    for disk_id in "${v_system_disks[@]}"; do
      local block_device_name
      block_device_basename="$(basename "$(readlink -f "$disk_id")")"

      if ! echo "$mounted_devices" | grep -q "^$block_device_basename\$"; then
        menu_entries_option+=("$disk_id" "($block_device_basename)" OFF)
      fi
    done

    local dialog_message="Select the ZFS devices (multiple selections will be in mirror).

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
    mapfile -t v_selected_disks < <(whiptail --checklist --separate-output "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)
  fi

  print_variables v_selected_disks
}

function ask_root_password_Debian {
  print_step_info_header

  set +x
  if [[ ${ZFS_DEBIAN_ROOT_PASSWORD:-} != "" ]]; then
    v_root_password="$ZFS_DEBIAN_ROOT_PASSWORD"
  else
    local password_invalid_message=
    local password_repeat=-

    while [[ "$v_root_password" != "$password_repeat" || "$v_root_password" == "" ]]; do
      v_root_password=$(whiptail --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
      password_repeat=$(whiptail --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

      password_invalid_message="Passphrase empty, or not matching! "
    done
  fi
  set -x
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
  set +x
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
  set -x
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

function ask_free_tail_space {
  print_step_info_header

  if [[ ${ZFS_FREE_TAIL_SPACE:-} != "" ]]; then
    v_free_tail_space=$ZFS_FREE_TAIL_SPACE
  else
   local tail_space_invalid_message=

    while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
      v_free_tail_space=$(whiptail --inputbox "${tail_space_invalid_message}Enter the space to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

      tail_space_invalid_message="Invalid size! "
    done
  fi

  print_variables v_free_tail_space
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

function install_host_zfs_module {
  print_step_info_header

  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} == "" ]]; then
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

    add-apt-repository --yes ppa:jonathonf/zfs

    # Required only on LinuxMint, which doesn't update the apt data when invoking `add-apt-repository`.
    # With the current design, it's arguably preferrable to introduce a redundant operation (for
    # Ubuntu), rather than adding an almost entirely duplicated function.
    #
    apt update

    # Libelf-dev allows `CONFIG_STACK_VALIDATION` to be set - it's optional, but good to have.
    # Module compilation log: `/var/lib/dkms/zfs/0.8.2/build/make.log` (adjust according to version).
    #
    apt install --yes libelf-dev zfs-dkms

    systemctl stop zfs-zed
    modprobe -r zfs
    modprobe zfs
    systemctl start zfs-zed
  fi
}

function install_host_zfs_module_Debian {
  print_step_info_header

  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} == "" ]]; then
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

    echo "deb http://deb.debian.org/debian buster contrib" >> /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian buster-backports main contrib" >> /etc/apt/sources.list
    apt update

    apt install --yes -t buster-backports zfs-dkms

    modprobe zfs
  fi
}

function install_host_zfs_module_elementary {
  print_step_info_header

  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} == "" ]]; then
    apt update
    apt install -y software-properties-common
  fi

  install_host_zfs_module
}

function prepare_disks {
  print_step_info_header

  # PARTITIONS #########################

  if [[ $v_free_tail_space -eq 0 ]]; then
    local tail_space_parameter=0
  else
    local tail_space_parameter="-${v_free_tail_space}G"
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    # More thorough than `sgdisk --zap-all`.
    #
    wipefs --all "$selected_disk"

    sgdisk -n1:1M:+512M                  -t1:EF00 "$selected_disk" # EFI boot
    sgdisk -n2:0:+512M                   -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:"$tail_space_parameter" -t3:BF01 "$selected_disk" # Root pool
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
    -O devices=off -O mountpoint=/ -R "$c_zfs_mount_dir" -f \
    "$v_rpool_name" $pools_mirror_option "${rpool_disks_partitions[@]}"

  # `-d` disable all the pool features (not used here);
  #
  # shellcheck disable=SC2086 # see previous command
  zpool create \
    $v_bpool_tweaks \
    -O devices=off -O mountpoint=/boot -R "$c_zfs_mount_dir" -f \
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
  print_step_info_header

  zfs create -V "$c_temporary_volume_size" "$v_rpool_name/os-install-temp"

  # The volume may not be immediately available; for reference, "/dev/zvol/.../os-install-temp"
  # is a standard file, which turns into symlink once the volume is available. See #8.
  #
  udevadm settle

  v_temp_volume_device=$(readlink -f "/dev/zvol/$v_rpool_name/os-install-temp")

  sgdisk -n1:0:0 -t1:8300 "$v_temp_volume_device"

  udevadm settle
}

# Differently from Ubuntu, the installer (Calamares) requires a filesystem to be ready.
#
function create_temp_volume_Debian {
  print_step_info_header

  create_temp_volume

  mkfs.ext4 -F "$v_temp_volume_device"
}

function install_operating_system {
  print_step_info_header

  local dialog_message='The Ubuntu GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Something Else` -> `Continue`
- select `'"$v_temp_volume_device"p1'` -> `Change`
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

  # /target is not always unmounted; the reason is unclear. A possibility is that if there is an
  # active swapfile under `/target` and ubiquity fails to unmount /target, it fails silently,
  # leaving `/target` mounted.
  # For this reason, if it's not mounted, we remount it.
  #
  # Note that we assume that the user created only one partition on the temp volume, as expected.
  #
  if ! mountpoint -q "$c_installed_os_data_mount_dir"; then
    mount "${v_temp_volume_device}p1" "$c_installed_os_data_mount_dir"
  fi
}

function install_operating_system_Debian {
  print_step_info_header

  local dialog_message='The Debian GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Manual partitioning` -> `Next`
- set `Storage device` to `Unknown - 10.0 GB '"${v_temp_volume_device}"'`
- click on `'"${v_temp_volume_device}"'` in the filesystems panel -> `Edit`
  - set `Mount Point` to `/` -> `OK`
- `Next`
- follow through the installation (ignore the EFI partition warning)
- at the end, uncheck `Restart now`, and click `Done`
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  calamares

  mkdir -p "$c_installed_os_data_mount_dir"

  # Note how in Debian, for reasons currenly unclear, the mount fails if the partition is passed;
  # it requires the device to be passed.
  #
  mount "${v_temp_volume_device}" "$c_installed_os_data_mount_dir"

  chroot_execute "echo root:$(printf "%q" "$v_root_password") | chpasswd"

  # The installer doesn't set the network interfaces, so, for convenience, we do it.
  #
  for interface in $(ip addr show | perl -lne '/^\d+: (?!lo:)(\w+)/ && print $1' ); do
    cat > "$c_installed_os_data_mount_dir/etc/network/interfaces.d/$interface" <<CONF
  auto $interface
  iface $interface inet dhcp
CONF
  done
}

function sync_os_temp_installation_dir_to_rpool {
  # Extended attributes are not used on a standard Ubuntu installation, however, this needs to be generic.
  # There isn't an exact way to filter out filenames in the rsync output, so we just use a good enough heuristic.
  # ❤️ Perl ❤️
  #
  rsync -avX --exclude=/swapfile --info=progress2 --no-inc-recursive --human-readable "$c_installed_os_data_mount_dir/" "$c_zfs_mount_dir" |
    perl -lane 'BEGIN { $/ = "\r"; $|++ } $F[1] =~ /(\d+)%$/ && print $1' |
    whiptail --gauge "Syncing the installed O/S to the root pool FS..." 30 100 0

  umount "$c_installed_os_data_mount_dir"
}

function destroy_temp_volume {
  zfs destroy "$v_rpool_name/os-install-temp"
}

function prepare_jail {
  print_step_info_header

  for virtual_fs_dir in proc sys dev; do
    mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  chroot_execute 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
}

function custom_install_operating_system {
  print_step_info_header

  sudo "$ZFS_OS_INSTALLATION_SCRIPT"
}

# See install_host_zfs_module() for some comments.
#
function install_jail_zfs_packages {
  print_step_info_header

  chroot_execute "add-apt-repository --yes ppa:jonathonf/zfs"

  chroot_execute "apt update"

  chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'

  chroot_execute "apt install --yes libelf-dev zfs-initramfs zfs-dkms grub-efi-amd64-signed shim-signed"
}

function install_jail_zfs_packages_Debian {
  print_step_info_header

  chroot_execute 'echo "deb http://deb.debian.org/debian buster main contrib"     >> /etc/apt/sources.list'
  chroot_execute 'echo "deb-src http://deb.debian.org/debian buster main contrib" >> /etc/apt/sources.list'

  chroot_execute 'echo "deb http://deb.debian.org/debian buster-backports main contrib"     >> /etc/apt/sources.list.d/buster-backports.list'
  chroot_execute 'echo "deb-src http://deb.debian.org/debian buster-backports main contrib" >> /etc/apt/sources.list.d/buster-backports.list'

  chroot_execute 'cat > /etc/apt/preferences.d/90_zfs <<APT
Package: libnvpair1linux libuutil1linux libzfs2linux libzpool2linux zfs-dkms zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
APT'

  chroot_execute "apt update"

  chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
  chroot_execute "apt install --yes zfs-initramfs zfs-dkms grub-efi-amd64-signed shim-signed"
}

function install_jail_zfs_packages_elementary {
  print_step_info_header

  chroot_execute "apt install -y software-properties-common"

  install_jail_zfs_packages
}

function install_and_configure_bootloader {
  print_step_info_header

  chroot_execute "echo PARTUUID=$(blkid -s PARTUUID -o value "${v_selected_disks[0]}-part1") /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 > /etc/fstab"

  chroot_execute "mkdir -p /boot/efi"
  chroot_execute "mount /boot/efi"

  chroot_execute "grub-install"

  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX=\")/\${1}root=ZFS=$v_rpool_name /'    /etc/default/grub"

  # Silence warning during the grub probe (source: https://git.io/JenXF).
  #
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

function install_and_configure_bootloader_Debian {
  print_step_info_header

  chroot_execute "echo PARTUUID=$(blkid -s PARTUUID -o value "${v_selected_disks[0]}-part1") /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 > /etc/fstab"

  chroot_execute "mkdir -p /boot/efi"
  chroot_execute "mount /boot/efi"

  chroot_execute "grub-install"

  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX=\")/\${1}root=ZFS=$v_rpool_name /' /etc/default/grub"
  chroot_execute "perl -i -pe 's/(GRUB_CMDLINE_LINUX_DEFAULT=.*)quiet/\$1/'             /etc/default/grub"
  chroot_execute "perl -i -pe 's/#(GRUB_TERMINAL=console)/\$1/'                         /etc/default/grub"

  chroot_execute "update-grub"

  chroot_execute "umount /boot/efi"
}

function clone_efi_partition {
  print_step_info_header

  for ((i = 1; i < ${#v_selected_disks[@]}; i++)); do
    dd if="${v_selected_disks[0]}-part1" of="${v_selected_disks[i]}-part1"
    efibootmgr --create --disk "${v_selected_disks[i]}" --label "ubuntu-$((i + 1))" --loader '\EFI\ubuntu\grubx64.efi'
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

function update_zed_cache_Debian {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/$v_rpool_name"
  chroot_execute "ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  chroot_execute "zed -F &"
  chroot_execute "[[ ! -s /etc/zfs/zfs-list.cache/$v_rpool_name ]] && zfs set canmount=noauto $v_rpool_name || true"
  chroot_execute "[[ ! -s /etc/zfs/zfs-list.cache/$v_rpool_name ]] && false"
  chroot_execute "pkill zed"

  chroot_execute "sed -Ei 's|$c_installed_os_data_mount_dir/?|/|' /etc/zfs/zfs-list.cache/$v_rpool_name"
}

function configure_remaining_settings {
  print_step_info_header

  [[ $v_swap_size -gt 0 ]] && chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab" || true
  chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"
}

function prepare_for_system_exit {
  print_step_info_header

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  # In one case, a second unmount was required. In this contenxt, bind mounts are not safe, so,
  # expecting unclean behaviors, we perform a second unmount if the mounts are still present.
  #
  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
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
trap print_preset_variables ERR
set_distribution_data
check_prerequisites
display_intro_banner
find_disks

select_disks
distro_dependent_invoke "ask_root_password" --noforce
ask_encryption
ask_swap_size
ask_free_tail_space
ask_pool_names
ask_pool_tweaks

distro_dependent_invoke "install_host_zfs_module"
prepare_disks

if [[ "${ZFS_OS_INSTALLATION_SCRIPT:-}" == "" ]]; then
  distro_dependent_invoke "create_temp_volume"

  # Includes the O/S extra configuration, if necessary (network, root pwd, etc.)
  distro_dependent_invoke "install_operating_system"

  sync_os_temp_installation_dir_to_rpool
  destroy_temp_volume
  prepare_jail
else
  custom_install_operating_system
fi

distro_dependent_invoke "install_jail_zfs_packages"
distro_dependent_invoke "install_and_configure_bootloader"
clone_efi_partition
configure_boot_pool_import
distro_dependent_invoke "update_zed_cache" --noforce
configure_remaining_settings

prepare_for_system_exit
display_exit_banner
