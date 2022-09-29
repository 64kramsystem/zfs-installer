# zfs-installer

ZFS installer is a shell script program that fully prepares ZFS on a system, and allows an effortless installation of several Debian-based operating systems using their standard installer (or debootstrap, or any custom script).

- [Project status](#project-status)
- [Requirements and functionality](#requirements-and-functionality)
- [Comparison with Ubuntu built-in installer](#comparison-with-ubuntu-built-in-installer)
- [Instructions](#instructions)
  - [Ubuntu Server](#ubuntu-server)
- [Stability](#stability)
- [Demo](#demo)
  - [Unsupported systems/Issues](#unsupported-systemsissues)
  - [Unattended installations](#unattended-installations)
- [Bug reporting/feature requests](#bug-reportingfeature-requests)
- [Help](#help)
- [Credits](#credits)

## Project status

The project is in passive maintenance: I accept PRs but not issues, and I may apply minor changes on an irregular basis. Issues and discussions have been deactivated.

PR are always welcome! 😄 I guarantee quick feedback.

The reason for the discontinuation of the active maintenance is that O/S installers don't have stable specifications (see the [stability section](#stability)), and I don't have the resources to investigate breakages.

Supported distros may or may not work; I only guarantee support for Ubuntu Desktop LTS versions, since it's the distribution I use.

## Requirements and functionality

The program currently supports:

- Ubuntu Desktop 18.04.x/20.04/22.04 Live
- Ubuntu Server 18.04.x/20.04/22.04 Live
- Linux Mint 19.x, 20
- Debian 10.x/11.x Live (desktop environment required)
- ElementaryOS 5.1

The ZFS version installed is 0.8 (optionally, 2.x), which supports native encryption and trimming (among the other improvements over 0.7). The required repositories are automatically added to the destination system.

EFI boot is required (any modern (2011+) system will do); legacy boot is currently not supported.

All the ZFS RAID types are supported, with any arbitrary number of disks. An EFI partition is created on each disk, for redundancy purposes.

It's fairly easy to extend the program to support other Debian-based operating systems (e.g. older/newer Ubuntu's, etc.) - the project is (very) open to feature requests.

## Comparison with Ubuntu built-in installer

As of 20.04, Canonical makes available an experimental ZFS installer on Ubuntu Desktop.

The advantages of this project over the Ubuntu installer are:

1. it allows configuring pools, datasets and the RAID type;
1. it allows customizing the disk partitions;
1. it supports additional features (e.g. encryption and trimming);
1. it supports newer OpenZFS versions, via PPA `jonathonf/zfs`.
1. it supports many more operating systems;
1. it supports unattended installations, via custom scripts;
1. it's easy to extend.

## Instructions

Start the live CD of a supported Linux distribution, then open a terminal and execute:

```sh
GET https://git.io/JEw00 | sudo bash
```

then follow the instructions; halfway through the procedure, the GUI installer of the O/S will be launched.

### Ubuntu Server

Ubuntu Server requires a slightly different execution procedure:

- when the installer welcome screen shows up, tap `Ctrl+Alt+F2`,
- then type `curl -L https://git.io/JEw00 | sudo bash`.

then follow the instructions.

## Stability

The project is carefully developed, however, it's practically impossible to guarantee continuous stability, for two reasons:

1. Linux distributions frequently apply small changes to their installers, even on the same distribution version,
1. automated testing is not feasible; although debootstrap installations could be automated, the bulk of the work is related to the installers, which can't be automated without sophisticated GUI automation,
1. testing is time consuming, so it can be performed on a limited amount of distros at a time.

Broadly speaking, there are two types of breakages:

1. minor changes directly or indirectly related to the installer, for example:
  - partition mounts change behavior (e.g. when they're dismounted)
  - installed services change behavior (e.g. a new service creates an ephemeral file under /target/run, and the sync fails because the file disappears)
2. GRUB setup not working
   - most annoying issue to debug; the installer will succeed, but the installed O/S won't boot

## Demo

![Demo](/demo/demo.gif?raw=true)

### Unsupported systems/Issues

The Ubuntu Server alternate (non-live) version is not supported, as it's based on the Busybox environment, which lacks several tools used in the installer (apt, rsync...).

The installer itself can run over SSH (\[S\]Ubiquity of course needs to be still run in the desktop environment, unless a custom script is provided), however, GNU Screen sessions may break, due to the virtual filesystems rebinding/chrooting. This is not an issue with the ZFS installer; it's a necessary step of the destination configuration.

### Unattended installations

The program supports unattended installation, via environment variables. The program built-in help explains all the options:

```
$ wget -qO- https://git.io/JEw00 | bash /dev/stdin --help
Usage: install-zfs.sh [-h|--help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_USE_PPA                : set to 1 to use packages from `ppa:jonathonf/zfs` (automatically set to true if the O/S version doesn't ship at least v0.8)
- ZFS_SELECTED_DISKS         : full path of the devices to create the pool on, comma-separated
- ZFS_PASSPHRASE
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

## Bug reporting/feature requests

This project is entirely oriented to community requests, as the target is to facilitate ZFS adoption.

Both for feature requests and bugs, [open a GitHub issue](https://github.com/64kramsystem/zfs-installer/issues/new).

For issues, also attach the content of the directory `/tmp/zfs-installer`. It doesn't contain any information aside what required for performing the installation; it can be trivially inspected, as it's a standard Bash debug output.

## Help

Since support for this project has been discontinued, the best place to request help is the [ZFS Discuss forum](https://zfsonlinux.topicbox.com/groups/zfs-discuss).

For the same reason, it's not great etiquette to write me an email asking for help 😬

## Credits

The workflow of this program is based on the official ZFS wiki procedure, so, many thanks to the ZFS team.

As my other open source work and [technical writing](https://saveriomiroddi.github.io), this project is sponsored by [Ticketsolve](https://ticketsolve.com).
