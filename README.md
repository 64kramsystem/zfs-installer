[![Build Status][BS IMG]](https://travis-ci.org/saveriomiroddi/zfs-installer)

# zfs-installer

ZFS installer is a shell script program that fully prepares ZFS on a system, and allows an effortless installation of several Debian-based operating systems using their standard installer (or debootstrap, or any custom script).

## Status

Due to the low popularity, the project is **inactive**.

I'll keep using it on my systems, so I'll update the code if required by my use case (Ubuntu Desktop), however, I likely won't implement new features, or add support for newer versions of the operating systems.

## Requirements and functionality

The program currently supports:

- Ubuntu Desktop 18.04.x/20.04 Live
- Ubuntu Server 18.04.x/20.04 Live
- Linux Mint 19.x
- Debian 10.x Live (desktop environment required)
- ElementaryOS 5.1

The ZFS version installed is 0.8, which supports native encryption and trimming (among the other improvements over 0.7). The required repositories are automatically added to the destination system.

EFI boot is required (any modern (2011+) system will do); legacy boot is currently not supported.

RAID-1 (mirroring) is supported, with any arbitrary number of disks; the boot and root pools are mirrored, and the EFI partition is cloned for each disk.

It's fairly easy to extend the program to support other Debian-based operating systems (e.g. older/newer Ubuntu's, etc.) - the project is (very) open to feature requests.

## Comparison with Ubuntu built-in installer

As of 20.04, Canonical makes available an experimental ZFS installer on Ubuntu Desktop.

The advantages of this project over the Ubuntu installer are:

1. it supports pools configuration;
2. it allows customization of the disks setup (including mirroring);
3. it supports additional features (e.g. encryption);
4. it supports many more operating systems;
5. it supports unattended installations, via custom scripts;
6. it's easy to extend.

The disadvantages are:

1. the Ubuntu installer has a more sophisticated filesystem layout - it separates base directories into different ZFS filesystems (this is planned to be implemented in the ZFS installer as well).

## Instructions

Start the live CD of a supported Linux distribution, then open a terminal and execute:

```sh
GET https://git.io/JelI5 | sudo bash -
```

then follow the instructions; halfway through the procedure, the GUI installer of the O/S will be launched.

### Ubuntu Server

Ubuntu Server requires a slightly different execution procedure:

- when the installer welcome screen shows up, tap `Ctrl+Alt+F2`,
- then type `sudo -- bash -c "$(curl -L https://git.io/JelI5)"`.

the rest is the same as the generic procedure.

### Unsupported systems/Issues

The Ubuntu Server alternate (non-live) version is not supported, as it's based on the Busybox environment, which lacks several tools used in the installer (apt, rsync...).

The installer itself can run over SSH (\[S\]Ubiquity of course needs to be still run in the desktop environment, unless a custom script is provided), however, GNU Screen sessions may break, due to the virtual filesystems rebinding/chrooting. This is not an issue with the ZFS installer; it's a necessary step of the destination configuration.

### Unattended installations

The program supports unattended installation, via environment variables. The program built-in help explains all the options:

```sh
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

For issues, also attach the content of the directory `/tmp/zfs-installer`. It doesn't contain any information aside what required for performing the installation; it can be trivially inspected, as it's a standard Bash debug output.

## Credits

The workflow of this program is based on the official ZFS wiki procedure, so, many thanks to the ZFS team.

Many thanks also to Gerard Beekmans for reaching out and giving useful feedback and help.

As my other open source work and [technical writing](https://saveriomiroddi.github.io), this project is sponsored by [Ticketsolve](https://ticketsolve.com).

[BS img]: https://travis-ci.org/saveriomiroddi/zfs-installer.svg?branch=master
