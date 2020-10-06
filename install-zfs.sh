#!/bin/bash
# shellcheck disable=SC2015,SC2016

# Shellcheck issue descriptions:
#
# - SC2015: <condition> && <operation> || true
# - SC2016: annoying warning about using single quoted strings with characters used for interpolation

set -o errexit
set -o pipefail
set -o nounset

# VARIABLES/CONSTANTS ##########################################################

# Variables set by the script

v_linux_distribution=        # Debian, Ubuntu, ... WATCH OUT: not necessarily from `lsb_release` (ie. UbuntuServer)
v_zfs_08_in_repository=      # 1=true, false otherwise (applies only to Ubuntu-based)

# Variables set (indirectly) by the user
#
# The passphrase has a special workflow - it's sent to a named pipe (see create_passphrase_named_pipe()).
# The same strategy can possibly be used for `v_root_passwd` (the difference being that is used
# inside a jail); logging the ZFS commands is enough, for now.
#
# Note that `ZFS_PASSPHRASE` and `ZFS_POOLS_RAID_TYPE` consider the unset state (see help).

v_bpool_name=
v_bpool_tweaks=              # array; see defaults below for format
v_root_password=             # Debian-only
v_rpool_name=
v_rpool_tweaks=              # array; see defaults below for format
v_pools_raid_type=
declare -a v_selected_disks  # (/dev/by-id/disk_id, ...)
v_swap_size=                 # integer
v_free_tail_space=           # integer

# Variables set during execution

v_temp_volume_device=        # /dev/zdN; scope: setup_partitions -> sync_os_temp_installation_dir_to_rpool
v_suitable_disks=()          # (/dev/by-id/disk_id, ...); scope: find_suitable_disks -> select_disk

# Constants
#
# Note that Linux Mint is "Linuxmint" from v20 onwards. This actually helps, since some operations are
# specific to it.

c_default_bpool_tweaks="-o ashift=12"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_zfs_mount_dir=/mnt
c_installed_os_data_mount_dir=/target
declare -A c_supported_linux_distributions=([Debian]=10 [Ubuntu]="18.04 20.04" [UbuntuServer]="18.04 20.04" [LinuxMint]="19.1 19.2 19.3" [Linuxmint]="20" [elementary]=5.1)
c_boot_partition_size=768M   # while 512M are enough for a few kernels, the Ubuntu updater complains after a couple
c_temporary_volume_size=12G  # large enough; Debian, for example, takes ~8 GiB.
c_passphrase_named_pipe=$(dirname "$(mktemp)")/zfs-installer.pp.fifo

c_log_dir=$(dirname "$(mktemp)")/zfs-installer
c_install_log=$c_log_dir/install.log
c_os_information_log=$c_log_dir/os_information.log
c_running_processes_log=$c_log_dir/running_processes.log
c_disks_log=$c_log_dir/disks.log
c_zfs_module_version_log=$c_log_dir/updated_module_versions.log

# On a system, while installing Ubuntu 18.04(.4), all the `udevadm settle` invocations timed out.
#
# It's not clear why this happens, so we set a large enough timeout. On systems without this issue,
# the timeout won't matter, while on systems with the issue, the timeout will be enough to ensure
# that the devices are created.
#
# Note that the strategy of continuing in any case (`|| true`) is not the best, however, the exit
# codes are not documented.
#
c_udevadm_settle_timeout=10 # seconds

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
- ZFS_PASSPHRASE             : set non-blank to encrypt the pool, and blank not to. if unset, it will be asked.
- ZFS_DEBIAN_ROOT_PASSWORD
- ZFS_BPOOL_NAME
- ZFS_RPOOL_NAME
- ZFS_BPOOL_TWEAKS           : boot pool options to set on creation (defaults to `'$c_default_bpool_tweaks'`)
- ZFS_RPOOL_TWEAKS           : root pool options to set on creation (defaults to `'$c_default_rpool_tweaks'`)
- ZFS_POOLS_RAID_TYPE        : options: blank (striping), `mirror`, `raidz`, `raidz2`, `raidz3`; if unset, it will be asked.
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

  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

function set_distribution_data {
  v_linux_distribution="$(lsb_release --id --short)"

  if [[ "$v_linux_distribution" == "Ubuntu" ]] && grep -q '^Status: install ok installed$' < <(dpkg -s ubuntu-server 2> /dev/null); then
    v_linux_distribution="UbuntuServer"
  fi

  v_linux_version="$(lsb_release --release --short)"
}

function store_os_distro_information {
  print_step_info_header

  lsb_release --all > "$c_os_information_log"

  # Madness, in order not to force the user to invoke "sudo -E".
  # Assumes that the user runs exactly `sudo bash`; it's not a (current) concern if the user runs off specification.
  # Not found when running via SSH - inspect the processes for finding this information.
  #
  perl -lne 'BEGIN { $/ = "\0" } print if /^XDG_CURRENT_DESKTOP=/' /proc/"$PPID"/environ >> "$c_os_information_log"
}

function store_os_distro_information_Debian {
  store_os_distro_information

  echo "DEBIAN_VERSION=$(cat /etc/debian_version)" >> "$c_os_information_log"
}

# Simplest and most solid way to gather the desktop environment (!).
# See note in store_os_distro_information().
#
function store_running_processes {
  ps ax --forest > "$c_running_processes_log"
}

function check_prerequisites {
  print_step_info_header

  local distro_version_regex=\\b${v_linux_version//./\\.}\\b

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
  elif [[ ! ${c_supported_linux_distributions["$v_linux_distribution"]} =~ $distro_version_regex ]]; then
    echo "This Linux distribution version ($v_linux_version) is not supported; supported versions: ${c_supported_linux_distributions["$v_linux_distribution"]}"
    exit 1
  fi

  set +x

  if [[ -v ZFS_PASSPHRASE && -n $ZFS_PASSPHRASE && ${#ZFS_PASSPHRASE} -lt 8 ]]; then
    echo "The passphase provided is too short; at least 8 chars required."
    exit 1
  fi

  set -x
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

function find_suitable_disks {
  print_step_info_header

  # In some freaky cases, `/dev/disk/by-id` is not up to date, so we refresh. One case is after
  # starting a VirtualBox VM that is a full clone of a suspended VM with snapshots.
  #
  udevadm trigger

  # shellcheck disable=SC2012 # `ls` may clean the output, but in this case, it doesn't matter
  ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

  local candidate_disk_ids
  local mounted_devices

  # Iterating via here-string generates an empty line when no devices are found. The options are
  # either using this strategy, or adding a conditional.
  #
  candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi|mmc)-.+' -not -regex '.+-part[0-9]+$' | sort)
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

  while read -r disk_id || [[ -n "$disk_id" ]]; do
    local device_info
    local block_device_basename

    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
    block_device_basename="$(basename "$(readlink -f "$disk_id")")"

    # It's unclear if it's possible to establish with certainty what is an internal disk:
    #
    # - there is no (obvious) spec around
    # - pretty much everything has `DEVTYPE=disk`, e.g. LUKS devices
    # - ID_TYPE is optional
    #
    # Therefore, it's probably best to rely on the id name, and just filter out optical devices.
    #
    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
        v_suitable_disks+=("$disk_id")
      fi
    fi

    cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG

  done < <(echo -n "$candidate_disk_ids")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you'\''re running inside a VMWare virtual machine, you need to add set `disk.EnableUUID = "TRUE"` in the .vmx configuration file.

If you think this is a bug, please open an issue on https://github.com/saveriomiroddi/zfs-installer/issues, and attach the file `'"$c_disks_log"'`.
'
    whiptail --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

# REQUIREMENT: it must be ensured that, for any distro, `apt update` is invoked at this step, as
# subsequent steps rely on it.
#
# There are three parameters:
#
# 1. the tools are preinstalled (ie. Ubuntu Desktop based);
# 2. the default repository supports ZFS 0.8 (ie. Ubuntu 20.04+ based);
# 3. the distro provides the precompiled ZFS module (i.e. Ubuntu based, not Debian)
#
# Fortunately, with Debian-specific logic isolated, we need conditionals based only on #2 - see
# install_host_packages() and install_host_packages_UbuntuServer().
#
function find_zfs_package_requirements {
  print_step_info_header

  apt update

  local zfs_package_version
  zfs_package_version=$(apt show zfsutils-linux 2> /dev/null | perl -ne 'print $1 if /^Version: (\d+\.\d+)\./')

  if [[ -n $zfs_package_version ]]; then
    if [[ ! $zfs_package_version =~ ^0\. ]]; then
      >&2 echo "Unsupported ZFS version!: $zfs_package_version"
      exit 1
    elif (( $(echo "$zfs_package_version" | cut -d. -f2) >= 8 )); then
      v_zfs_08_in_repository=1
    fi
  fi
}

function find_zfs_package_requirements_Debian {
  # Only update apt; in this case, ZFS packages are handled in a specific way.

  apt update
}

# Mint 20 has the CDROM repository enabled, but apt fails when updating due to it (or possibly due
# to it being incorrectly setup).
#
function find_zfs_package_requirements_Linuxmint {
  print_step_info_header

  perl -i -pe 's/^(deb cdrom)/# $1/' /etc/apt/sources.list

  find_zfs_package_requirements
}

# By using a FIFO, we avoid having to hide statements like `echo $v_passphrase | zpoool create ...`
# from the logs.
#
# The FIFO file is left in the filesystem after the script exits. It's not worth taking care of
# removing it, since the environment is entirely ephemeral.
#
function create_passphrase_named_pipe {
  rm -f "$c_passphrase_named_pipe"
  mkfifo "$c_passphrase_named_pipe"
}

function select_disks {
  print_step_info_header

  if [[ "${ZFS_SELECTED_DISKS:-}" != "" ]]; then
    mapfile -d, -t v_selected_disks < <(echo -n "$ZFS_SELECTED_DISKS")
  else
    while true; do
      local menu_entries_option=()
      local block_device_basename

      if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
        local disk_selection_status=ON
      else
        local disk_selection_status=OFF
      fi

      for disk_id in "${v_suitable_disks[@]}"; do
        block_device_basename="$(basename "$(readlink -f "$disk_id")")"
        menu_entries_option+=("$disk_id" "($block_device_basename)" "$disk_selection_status")
      done

      local dialog_message="Select the ZFS devices.

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
      mapfile -t v_selected_disks < <(whiptail --checklist --separate-output "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

      if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
        break
      fi
    done
  fi

  print_variables v_selected_disks
}

function select_pools_raid_type {
  print_step_info_header

  if [[ -v ZFS_POOLS_RAID_TYPE ]]; then
    v_pools_raid_type=$ZFS_POOLS_RAID_TYPE
  elif [[ ${#v_selected_disks[@]} -ge 2 ]]; then
    # Entries preparation.

    local menu_entries_option=(
      ""      "Striping array" OFF
      mirror  Mirroring        OFF
      raidz   RAIDZ1           OFF
    )

    if [[ ${#v_selected_disks[@]} -ge 3 ]]; then
      menu_entries_option+=(raidz2 RAIDZ2 OFF)
    fi

    if [[ ${#v_selected_disks[@]} -ge 4 ]]; then
      menu_entries_option+=(raidz3 RAIDZ3 OFF)
    fi

    # Defaults (ultimately, arbitrary). Based on https://calomel.org/zfs_raid_speed_capacity.html.

    if [[ ${#v_selected_disks[@]} -ge 11 ]]; then
      menu_entries_option[14]=ON
    elif [[ ${#v_selected_disks[@]} -ge 6 ]]; then
      menu_entries_option[11]=ON
    elif [[ ${#v_selected_disks[@]} -ge 5 ]]; then
      menu_entries_option[8]=ON
    else
      menu_entries_option[5]=ON
    fi

    local dialog_message="Select the pools RAID type."
    v_pools_raid_type=$(whiptail --radiolist "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)
  fi
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

  local passphrase=

  set +x

  if [[ -v ZFS_PASSPHRASE ]]; then
    passphrase=$ZFS_PASSPHRASE
  else
    local passphrase_repeat=_
    local passphrase_invalid_message=

    while [[ $passphrase != "$passphrase_repeat" || ${#passphrase} -lt 8 ]]; do
      local dialog_message="${passphrase_invalid_message}Please enter the passphrase (8 chars min.):

Leave blank to keep encryption disabled.
"

      passphrase=$(whiptail --passwordbox "$dialog_message" 30 100 3>&1 1>&2 2>&3)

      if [[ -z $passphrase ]]; then
        break
      fi

      passphrase_repeat=$(whiptail --passwordbox "Please repeat the passphrase:" 30 100 3>&1 1>&2 2>&3)

      passphrase_invalid_message="Passphrase too short, or not matching! "
    done
  fi

  echo -n "$passphrase" > "$c_passphrase_named_pipe" &

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
      v_free_tail_space=$(whiptail --inputbox "${tail_space_invalid_message}Enter the space in GiB to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

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

  local bpool_tweaks_message='Insert the tweaks for the boot pool

The option `-O devices=off` is already set, and must not be specified.'

  local raw_bpool_tweaks=${ZFS_BPOOL_TWEAKS:-$(whiptail --inputbox "$bpool_tweaks_message" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)}

  mapfile -d' ' -t v_bpool_tweaks < <(echo -n "$raw_bpool_tweaks")

  local rpool_tweaks_message='Insert the tweaks for the root pool

The option `-O devices=off` is already set, and must not be specified.'

  local raw_rpool_tweaks=${ZFS_RPOOL_TWEAKS:-$(whiptail --inputbox "$rpool_tweaks_message" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)}

  mapfile -d' ' -t v_rpool_tweaks < <(echo -n "$raw_rpool_tweaks")

  print_variables v_bpool_tweaks v_rpool_tweaks
}

function install_host_packages {
  print_step_info_header

  if [[ $v_zfs_08_in_repository != "1" ]]; then
    if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
      add-apt-repository --yes ppa:jonathonf/zfs
      apt update

      # Libelf-dev allows `CONFIG_STACK_VALIDATION` to be set - it's optional, but good to have.
      # Module compilation log: `/var/lib/dkms/zfs/0.8.2/build/make.log` (adjust according to version).
      #
      echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
      apt install --yes libelf-dev zfs-dkms

      systemctl stop zfs-zed
      modprobe -r zfs
      modprobe zfs
      systemctl start zfs-zed
    fi
  fi

  apt install --yes efibootmgr

  zfs --version > "$c_zfs_module_version_log" 2>&1
}

function install_host_packages_Debian {
  print_step_info_header

  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

    echo "deb http://deb.debian.org/debian buster contrib" >> /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian buster-backports main contrib" >> /etc/apt/sources.list
    apt update

    apt install --yes -t buster-backports zfs-dkms

    modprobe zfs
  fi

  apt install --yes efibootmgr

  zfs --version > "$c_zfs_module_version_log" 2>&1
}

# Differently from Ubuntu, Mint doesn't have the package installed in the live version.
#
function install_host_packages_Linuxmint {
  print_step_info_header

  apt install --yes zfsutils-linux

  install_host_packages
}

function install_host_packages_elementary {
  print_step_info_header

  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
    apt update
    apt install -y software-properties-common
  fi

  install_host_packages
}

function install_host_packages_UbuntuServer {
  print_step_info_header

  if [[ $v_zfs_08_in_repository == "1" ]]; then
    apt install --yes zfsutils-linux efibootmgr

    zfs --version > "$c_zfs_module_version_log" 2>&1
  elif [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
    # This is not needed on UBS 20.04, which has the modules built-in - incidentally, if attempted,
    # it will cause /dev/disk/by-id changes not to be recognized.
    #
    # On Ubuntu Server, `/lib/modules` is a SquashFS mount, which is read-only.
    #
    cp -R /lib/modules /tmp/
    systemctl stop 'systemd-udevd*'
    umount /lib/modules
    rm -r /lib/modules
    ln -s /tmp/modules /lib
    systemctl start 'systemd-udevd*'

    # Additionally, the linux packages for the running kernel are not installed, at least when
    # the standard installation is performed. Didn't test on the HWE option; if it's not required,
    # this will be a no-op.
    #
    apt update
    apt install -y "linux-headers-$(uname -r)"

    install_host_packages
  else
    apt install --yes efibootmgr
  fi
}

function setup_partitions {
  print_step_info_header

  local temporary_partition_start=-$((${c_temporary_volume_size:0:-1} + v_free_tail_space))G

  if [[ $v_free_tail_space -eq 0 ]]; then
    local tail_space_start=0
  else
    local tail_space_start="-${v_free_tail_space}G"
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    # wipefs doesn't fully wipe ZFS labels.
    #
    find "$(dirname "$selected_disk")" -name "$(basename "$selected_disk")-part*" -exec bash -c '
      zpool labelclear -f "$1" 2> /dev/null || true
    ' _ {} \;

    # More thorough than `sgdisk --zap-all`.
    #
    wipefs --all "$selected_disk"

    sgdisk -n1:1M:+"$c_boot_partition_size"   -t1:EF00 "$selected_disk" # EFI boot
    sgdisk -n2:0:+"$c_boot_partition_size"    -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:"$temporary_partition_start" -t3:BF01 "$selected_disk" # Root pool
    sgdisk -n4:0:"$tail_space_start"          -t4:8300 "$selected_disk" # Temporary partition
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
  udevadm settle --timeout "$c_udevadm_settle_timeout" || true

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

  v_temp_volume_device=$(readlink -f "${v_selected_disks[0]}-part4")
}

function install_operating_system {
  print_step_info_header

  local dialog_message='The Ubuntu GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Something Else` -> `Continue`
- select `'"$v_temp_volume_device"'` -> `Change`
  - set `Use as:` to `Ext4`
  - check `Format the partition:`
  - set `Mount point` to `/` -> `OK` -> `Continue`
- `Install Now` -> `Continue`
- at the end, choose `Continue Testing`
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  # The display is restricted only to the owner (`user`), so we need to allow any user to access
  # it.
  #
  sudo -u "$SUDO_USER" env DISPLAY=:0 xhost +

  DISPLAY=:0 ubiquity --no-bootloader

  swapoff -a

  # /target is not always unmounted; the reason is unclear. A possibility is that if there is an
  # active swapfile under `/target` and ubiquity fails to unmount /target, it fails silently,
  # leaving `/target` mounted.
  # For this reason, if it's not mounted, we remount it.
  #
  # Note that we assume that the user created only one partition on the temp volume, as expected.
  #
  if ! mountpoint -q "$c_installed_os_data_mount_dir"; then
    mount "$v_temp_volume_device" "$c_installed_os_data_mount_dir"
  fi

  rm -f "$c_installed_os_data_mount_dir/swapfile"
}

function install_operating_system_Debian {
  print_step_info_header

  # The temporary volume size displayed is an approximation of the format used by the installer,
  # but it's acceptable - the complexity required is not worth (eg. converting hypothetical units,
  # etc.).
  #
  local dialog_message='The Debian GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Manual partitioning` -> `Next`
- click on `'"${v_temp_volume_device}"'` in the filesystems panel -> `Edit`
  - click on `Format`
  - set `Mount Point` to `/` -> `OK`
- `Next`
- follow through the installation (ignore the EFI partition warning)
- at the end, uncheck `Restart now`, and click `Done`
'

  if [[ ${ZFS_NO_INFO_MESSAGES:-} == "" ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  # See install_operating_system().
  #
  sudo -u "$SUDO_USER" env DISPLAY=:0 xhost +

  DISPLAY=:0 calamares

  mkdir -p "$c_installed_os_data_mount_dir"

  # Note how in Debian, for reasons currenly unclear, the mount fails if the partition is passed;
  # it requires the device to be passed.
  #
  mount "${v_temp_volume_device}" "$c_installed_os_data_mount_dir"

  # We don't use chroot()_execute here, as it works on $c_zfs_mount_dir (which is synced on a
  # later stage).
  #
  set +x
  chroot "$c_installed_os_data_mount_dir" bash -c "echo root:$(printf "%q" "$v_root_password") | chpasswd"
  set -x

  # The installer doesn't set the network interfaces, so, for convenience, we do it.
  #
  for interface in $(ip addr show | perl -lne '/^\d+: (?!lo:)(\w+)/ && print $1' ); do
    cat > "$c_installed_os_data_mount_dir/etc/network/interfaces.d/$interface" <<CONF
  auto $interface
  iface $interface inet dhcp
CONF
  done
}

function install_operating_system_UbuntuServer {
  print_step_info_header

  # O/S Installation
  #
  # Subiquity is designed to prevent the user from opening a terminal, which is (to say the least)
  # incongruent with the audience.

  local dialog_message='You'\''ll now need to run the Ubuntu Server installer (Subiquity).

Switch back to the original terminal (Ctrl+Alt+F1), then proceed with the configuration as usual.

When the update option is presented, choose to update Subiquity to the latest version.

At the partitioning stage:

- select `Custom storage layout` -> `Done`
- select `'"$v_temp_volume_device"'` -> `Edit`
  - set `Format:` to `ext4` (mountpoint will be automatically selected)
  - click `Save`
- click `Done` -> `Continue` (ignore warning)
- follow through the installation, until the end (after the updates are applied)
- switch back to this terminal (Ctrl+Alt+F2), and continue (tap Enter)

Do not continue in this terminal (tap Enter) now!

You can switch anytime to this terminal, and back, in order to read the instructions.
'

  whiptail --msgbox "$dialog_message" 30 100

  swapoff -a

  # See note in install_operating_system(). It's not clear whether this is required on Ubuntu
  # Server, but it's better not to take risks.
  #
  if ! mountpoint -q "$c_installed_os_data_mount_dir"; then
    mount "${v_temp_volume_device}p2" "$c_installed_os_data_mount_dir"
  fi

  rm -f "$c_installed_os_data_mount_dir"/swap.img
}

function custom_install_operating_system {
  print_step_info_header

  sudo "$ZFS_OS_INSTALLATION_SCRIPT"
}

function create_pools {
  # POOL OPTIONS #######################

  local passphrase
  local encryption_options=()
  local rpool_disks_partitions=()
  local bpool_disks_partitions=()

  set +x

  passphrase=$(cat "$c_passphrase_named_pipe")

  if [[ -n $passphrase ]]; then
    encryption_options=(-O "encryption=on" -O "keylocation=prompt" -O "keyformat=passphrase")
  fi

  # Push back for unlogged reuse. Minor inconvenience, but worth :-)
  #
  echo -n "$passphrase" > "$c_passphrase_named_pipe" &

  set -x

  for selected_disk in "${v_selected_disks[@]}"; do
    rpool_disks_partitions+=("${selected_disk}-part3")
    bpool_disks_partitions+=("${selected_disk}-part2")
  done

  # POOLS CREATION #####################

  # See https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS for the details.
  #
  # `-R` creates an "Alternate Root Point", which is lost on unmount; it's just a convenience for a temporary mountpoint;
  # `-f` force overwrite partitions is existing - in some cases, even after wipefs, a filesystem is mistakenly recognized
  # `-O` set filesystem properties on a pool (pools and filesystems are distincted entities, however, a pool includes an FS by default).
  #
  # Stdin is ignored if the encryption is not set (and set via prompt).
  #
  # shellcheck disable=SC2086 # TODO: convert v_pools_raid_type to array, and quote
  zpool create \
    "${encryption_options[@]}" \
    "${v_rpool_tweaks[@]}" \
    -O devices=off -O mountpoint=/ -R "$c_zfs_mount_dir" -f \
    "$v_rpool_name" $v_pools_raid_type "${rpool_disks_partitions[@]}" \
    < "$c_passphrase_named_pipe"

  # `-d` disable all the pool features (not used here);
  #
  # shellcheck disable=SC2086 # TODO: See above
  zpool create \
    "${v_bpool_tweaks[@]}" \
    -O devices=off -O mountpoint=/boot -R "$c_zfs_mount_dir" -f \
    "$v_bpool_name" $v_pools_raid_type "${bpool_disks_partitions[@]}"
}

function create_swap_volume {
  if [[ $v_swap_size -gt 0 ]]; then
    zfs create \
      -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
      -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
      "$v_rpool_name/swap"

    mkswap -f "/dev/zvol/$v_rpool_name/swap"
  fi
}

function sync_os_temp_installation_dir_to_rpool {
  print_step_info_header

  # On Ubuntu Server, `/boot/efi` and `/cdrom` (!!!) are mounted, but they're not needed.
  #
  local mount_dir_submounts
  mount_dir_submounts=$(mount | MOUNT_DIR="${c_installed_os_data_mount_dir%/}" perl -lane 'print $F[2] if $F[2] =~ /$ENV{MOUNT_DIR}\//')

  for mount_dir in $mount_dir_submounts; do
    umount "$mount_dir"
  done

  # Extended attributes are not used on a standard Ubuntu installation, however, this needs to be generic.
  # There isn't an exact way to filter out filenames in the rsync output, so we just use a good enough heuristic.
  # ❤️ Perl ❤️
  #
  # `/run` is not needed (with an exception), and in Ubuntu Server it's actually a nuisance, since
  # some files vanish while syncing. Debian is well-behaved, and `/run` is empty.
  #
  rsync -avX --exclude=/run --info=progress2 --no-inc-recursive --human-readable "$c_installed_os_data_mount_dir/" "$c_zfs_mount_dir" |
    perl -lane 'BEGIN { $/ = "\r"; $|++ } $F[1] =~ /(\d+)%$/ && print $1' |
    whiptail --gauge "Syncing the installed O/S to the root pool FS..." 30 100 0

  mkdir "$c_zfs_mount_dir/run"

  # Required destination of symlink `/etc/resolv.conf`, present in Ubuntu systems (not Debian).
  #
  if [[ -d $c_installed_os_data_mount_dir/run/systemd/resolve ]]; then
    rsync -av --relative "$c_installed_os_data_mount_dir/run/./systemd/resolve" "$c_zfs_mount_dir/run"
  fi

  umount "$c_installed_os_data_mount_dir"
}

function remove_temp_partition_and_expand_rpool {
  print_step_info_header

  if [[ $v_free_tail_space -eq 0 ]]; then
    local resize_reference=100%
  else
    local resize_reference=-${v_free_tail_space}G
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    parted -s "$selected_disk" rm 4
    parted -s "$selected_disk" unit s resizepart 3 -- "$resize_reference"
    zpool online -e "$v_rpool_name" "$selected_disk-part3"
  done
}

function prepare_jail {
  print_step_info_header

  for virtual_fs_dir in proc sys dev; do
    mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  chroot_execute 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
}

# See install_host_packages() for some comments.
#
function install_jail_zfs_packages {
  print_step_info_header

  if [[ $v_zfs_08_in_repository != "1" ]]; then
    chroot_execute "add-apt-repository --yes ppa:jonathonf/zfs"

    chroot_execute "apt update"

    chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'

    chroot_execute "apt install --yes libelf-dev zfs-initramfs zfs-dkms"
  else
    # Oddly, on a 20.04 Ubuntu Desktop live session, the zfs tools are installed, but they are not
    # associated to a package:
    #
    # - `dpkg -S $(which zpool)` -> nothing
    # - `aptitude search ~izfs | awk '{print $2}' | xargs echo` -> libzfs2linux zfs-initramfs zfs-zed zfsutils-linux
    #
    # The packages are not installed by default, so we install them.
    #
    chroot_execute "apt install --yes libzfs2linux zfs-initramfs zfs-zed zfsutils-linux"
  fi

  chroot_execute "apt install --yes grub-efi-amd64-signed shim-signed"
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
  chroot_execute "apt install --yes rsync zfs-initramfs zfs-dkms grub-efi-amd64-signed shim-signed"
}

function install_jail_zfs_packages_elementary {
  print_step_info_header

  chroot_execute "apt install -y software-properties-common"

  install_jail_zfs_packages
}

function install_jail_zfs_packages_UbuntuServer {
  print_step_info_header

  if [[ $v_zfs_08_in_repository == "1" ]]; then
    chroot_execute "apt install --yes zfsutils-linux zfs-initramfs grub-efi-amd64-signed shim-signed"
  else
    install_jail_zfs_packages
  fi
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
}

function sync_efi_partitions {
  print_step_info_header

  for ((i = 1; i < ${#v_selected_disks[@]}; i++)); do
    local synced_efi_partition_path="/boot/efi$((i + 1))"

    chroot_execute "echo PARTUUID=$(blkid -s PARTUUID -o value "${v_selected_disks[i]}-part1") $synced_efi_partition_path vfat nofail,x-systemd.device-timeout=1 0 1 >> /etc/fstab"

    chroot_execute "mkdir -p $synced_efi_partition_path"
    chroot_execute "mount $synced_efi_partition_path"

    chroot_execute "rsync --archive --delete --verbose /boot/efi/ $synced_efi_partition_path"

    efibootmgr --create --disk "${v_selected_disks[i]}" --label "ubuntu-$((i + 1))" --loader '\EFI\ubuntu\grubx64.efi'

    chroot_execute "umount $synced_efi_partition_path"
  done

  chroot_execute "umount /boot/efi"
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
ExecStartPre=/bin/sh -c '[ -f /etc/zfs/zpool.cache ] && mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache || true'
ExecStart=/sbin/zpool import -N -o cachefile=none $v_bpool_name
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

  chroot_execute "systemctl enable zfs-import-$v_bpool_name.service"

  chroot_execute "zfs set mountpoint=legacy $v_bpool_name"
  chroot_execute "echo $v_bpool_name /boot zfs nodev,relatime,x-systemd.requires=zfs-import-$v_bpool_name.service 0 0 >> /etc/fstab"
}

# This step is important in cases where the keyboard layout is not the standard one.
# See issue https://github.com/saveriomiroddi/zfs-installer/issues/110.
#
function update_initramfs {
  print_step_info_header

  chroot_execute "update-initramfs -u"
}

function update_zed_cache_Debian {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/$v_rpool_name"
  chroot_execute "ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  # Assumed to be present by the zedlet above, but missing.
  # Filed issue: https://github.com/zfsonlinux/zfs/issues/9945.
  #
  chroot_execute "mkdir /run/lock"

  chroot_execute "zed -F &"

  # We could pool the events via `zpool events -v`, but it's much simpler to just check on the file.
  #
  local success=

  if [[ ! -s "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" ]]; then
    # Takes around half second on a test VM.
    #
    chroot_execute "zfs set canmount=noauto $v_rpool_name"

    SECONDS=0

    while [[ $SECONDS -lt 5 ]]; do
      if [[ -s "$c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name" ]]; then
        success=1
        break
      else
        sleep 0.25
      fi
    done
  fi

  if [[ $success -ne 1 ]]; then
    echo "Error: The ZFS cache hasn't been updated by ZED!"
    exit 1
  fi

  chroot_execute "pkill zed"

  chroot_execute "sed -Ei 's|$c_installed_os_data_mount_dir/?|/|' /etc/zfs/zfs-list.cache/$v_rpool_name"
}

# We don't care about synchronizing with the `fstrim` service for two reasons:
#
# - we assume that there are no other (significantly) large filesystems;
# - trimming is fast (takes minutes on a 1 TB disk).
#
# The code is a straight copy of the `fstrim` service.
#
function configure_pools_trimming {
  print_step_info_header

  chroot_execute "cat > /lib/systemd/system/zfs-trim.service << UNIT
[Unit]
Description=Discard unused ZFS blocks
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=/sbin/zpool trim $v_bpool_name
ExecStart=/sbin/zpool trim $v_rpool_name
UNIT"

  chroot_execute "  cat > /lib/systemd/system/zfs-trim.timer << TIMER
[Unit]
Description=Discard unused ZFS blocks once a week
ConditionVirtualization=!container

[Timer]
OnCalendar=weekly
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER"

  chroot_execute "systemctl daemon-reload"
  chroot_execute "systemctl enable zfs-trim.timer"
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
set_distribution_data
distro_dependent_invoke "store_os_distro_information"
store_running_processes
check_prerequisites
display_intro_banner
find_suitable_disks
distro_dependent_invoke "find_zfs_package_requirements"
create_passphrase_named_pipe

select_disks
select_pools_raid_type
distro_dependent_invoke "ask_root_password" --noforce
ask_encryption
ask_swap_size
ask_free_tail_space
ask_pool_names
ask_pool_tweaks

distro_dependent_invoke "install_host_packages"
setup_partitions

if [[ "${ZFS_OS_INSTALLATION_SCRIPT:-}" == "" ]]; then
  # Includes the O/S extra configuration, if necessary (network, root pwd, etc.)
  distro_dependent_invoke "install_operating_system"

  create_pools
  create_swap_volume
  sync_os_temp_installation_dir_to_rpool
  remove_temp_partition_and_expand_rpool
else
  create_pools
  create_swap_volume
  remove_temp_partition_and_expand_rpool

  custom_install_operating_system
fi

prepare_jail
distro_dependent_invoke "install_jail_zfs_packages"
distro_dependent_invoke "install_and_configure_bootloader"
sync_efi_partitions
configure_boot_pool_import
update_initramfs
distro_dependent_invoke "update_zed_cache" --noforce
configure_pools_trimming
configure_remaining_settings

prepare_for_system_exit
display_exit_banner
