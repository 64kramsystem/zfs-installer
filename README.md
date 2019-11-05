[![Build Status][BS IMG]](https://travis-ci.org/saveriomiroddi/zfs-installer)

# zfs-installer

ZFS installer is shell script program that fully prepares ZFS on a system, and allows an effortless installation of Ubuntu via the standard installer (or via any script).

## Requirements and functionality

The program currently supports:

- Ubuntu 18.04.x (Bionic);
- Linux Mint 19.x.

It uses the widespread [jonathonf/zfs PPA](https://launchpad.net/~jonathonf/+archive/ubuntu/zfs) for installing the latest ZFS version (0.8.x), which supports native encryption and trimming (among the other improvements over 0.7).

EFI boot is required (any modern (2011+) system will do); legacy boot is currently not supported.

RAID-1 (mirroring) is supported, with any arbitrary number of disks; the boot and root pools are mirrored, and the EFI partition is cloned for each disk.

It's fairly easy to extend the program to support at least other Debian-based operating systems (any Debian, older Ubuntu, etc.) - the project is (very) open to feature requests.

## Advantages over the Ubuntu 19.10 built-in installer

On October 17th, Canonical will release Ubuntu 19.10, with an experimental ZFS installer. The advantages of this project over the 19.10 installer are:

1. on production systems, it's undesirable to use a non-LTS version;
2. the experimental Ubuntu installer is unconfigurable, and supports a very simple configuration.

additionally, as explained in the previous section, the script can be easily adapted for other operating systems.

## Status

The script is in "open beta"; it's been tested on different configurations, but promoting the program to stable requires testing on a large amount of systems, as there always system-related peculiarities that need to be handled.

## Instructions

Start the live CD of a supported Linux distribution, then open a terminal and execute:

```sh
GET https://git.io/JelI5 | sudo bash -
```

then follow the instructions.

### Unattended installations

The program supports unattended installation, via environment variables. The program built-in help explains all the options:

```
$ wget -qO- https://git.io/JelI5 | bash /dev/stdin --help
Usage: install-zfs.sh [-h|--help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_SELECTED_DISKS         : full path of the devices to create the pool on, comma-separated
- ZFS_ENCRYPT_RPOOL          : set 1 to encrypt the pool
- ZFS_PASSPHRASE
- ZFS_BPOOL_NAME
- ZFS_RPOOL_NAME
- ZFS_BPOOL_TWEAKS           : boot pool options to set on creation (defaults to `-o ashift=12`)
- ZFS_RPOOL_TWEAKS           : root pool options to set on creation (defaults to `-o ashift=12 -O acltype=posixacl -O compression=lz4 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD`)
- ZFS_NO_INFO_MESSAGES       : set 1 to skip informational messages
- ZFS_SWAP_SIZE              : swap size (integer); set 0 for no swap
- ZFS_FREE_TAIL_SPACE        : leave free space at the end of each disk (integer), for example, for a swap partition

When installing the O/S via $ZFS_OS_INSTALLATION_SCRIPT, the root pool is mounted as `/mnt`; the requisites are:

1. the virtual filesystems must be mounted in `/mnt` (ie. `for vfs in proc sys dev; do mount --rbind /$vfs /mnt/$vfs; done`)
2. internet must be accessible while chrooting in `/mnt` (ie. `echo nameserver 8.8.8.8 >> /mnt/etc/resolv.conf`)
3. `/mnt` must be left in a dismountable state (e.g. no file locks, no swap etc.);
```

Other options may be supported, and displayed in the current commandline help, so users are invited to take a look.

## Screenshots

![Devices selection](/screenshots/01-devices_selection.png?raw=true)
![Encryption](/screenshots/02-encryption.png?raw=true)
![Boot pool tweaks](/screenshots/03-boot_pool_tweaks.png?raw=true)

## Bug reporting/feature requests

This project is entirely oriented to community requests, as the target is to facilitate ZFS adoption.

Both for feature requests and bugs, [open a GitHub issue](https://github.com/saveriomiroddi/zfs-installer/issues/new).

For issues, also attach the file `/tmp/install-zfs.log`. It doesn't contain any information aside what required for performing the installation; it can be trivially inspected, as it's a standard Bash debug output.

## Credits

The workflow of this program is based on the official ZFS wiki procedure, so, many thanks to the ZFS team.

Many thanks also to Gerard Beekmans for reaching out and giving useful feedback and help.

As my other open source work and [technical writing](https://saveriomiroddi.github.io), this project is sponsored by [Ticketsolve](https://ticketsolve.com).

[BS img]: https://travis-ci.org/saveriomiroddi/zfs-installer.svg?branch=master
