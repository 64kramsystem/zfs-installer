#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Don't use spaces in the filenames; avoids ugly quoting.
#
c_fifo_filename="/tmp/target_image.fifo"
c_os_install_script="$(dirname "$0")/from_target_image-guest.sh"
c_zfs_installer_script="$(dirname "${0%/*}")/install-zfs.sh"

if [[ $# -ne 3 ]] || [[ ! -x "$(command -v sshpass)" ]]; then
  echo "Usage: $(basename "$0") <compressed_image> <host> <password>

Perform a ZFS installation via custom script \`$(basename "$c_os_install_script")\`, using the provided O/S image.

The image must be an XZ-tarball of the target mountpoint (typically, \`/target\`), as it is immediately after the installer (S)Ubiquity has finished.
The files must be relative to the target mountpoint.

Requirements:

- the \`sshpass\` tool on the host (for convenience);
- the SSH server on the guest, with allowed password authentication;
- the SSH client configured on the host.
" 
  echo
  exit 1
fi

v_image=$1
v_host=$2
export SSHPASS=$3

# Initiate the image copy in the background, but block until it's picked up.
#
sshpass -e ssh "$v_host" "rm -f $c_fifo_filename && mkfifo $c_fifo_filename"
sshpass -e scp -q "$v_image" "$v_host":"$c_fifo_filename" &

sshpass -e scp "$c_os_install_script" "$c_zfs_installer_script" "$v_host":

sshpass -e ssh -t "$v_host" "sudo ZFS_OS_INSTALLATION_SCRIPT=./$(basename "$c_os_install_script") ./$(basename "$c_zfs_installer_script")"
