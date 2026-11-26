# Autoinstall

`dkrescue-install --auto` installs with no screens and no typed confirmation.
Because that erases a disk by itself, it needs **all** of these:

1. `dkinstall.auto=1` on the kernel command line;
2. an answers file that says `[install] confirm_erase = ...` and names the disk
   the plan will erase;
3. a target that is not the live medium (and, being mounted, not the medium the
   answers file was read from).

If any is missing or wrong the installer prints which, erases nothing and
starts the normal screens. Nothing else triggers an unattended erase.

## Kernel parameters

| Parameter | Meaning |
|---|---|
| `dkinstall.auto=1` | Allow `--auto` to run. Without it `--auto` exits 0 and does nothing. |
| `dkinstall.answers=/path` | Answers file on the live system (absolute path; no URLs: the install is offline). |

## Where the answers file is looked for

In this order, the first that exists wins:

1. `--answers FILE`, or `dkinstall.answers=PATH`. If given and missing, there
   is no fallback: the normal installer starts.
2. `<live medium>/install/answers.toml` (`/run/live/medium`): bake it into the
   ISO.
3. `dkinstall.toml` at the root of a medium that is already mounted (`/mnt`,
   `/media`, `/run/media`, one directory down), else of each unmounted
   iso9660/vfat/ext4/exfat device in turn (mounted read-only at
   `/mnt/dkinstall-auto`; label does not matter; the live medium and loop
   devices are skipped; ext4 with `noload`, so no journal is replayed). Any USB
   stick or second virtual disk will do.

## What it does

No screens. Progress goes to the console, the log is
`/run/dkrescue-install/install.log` (copied to `/var/log/dkrescue-install.log`
on the new system). Exit code 0 when the install worked, 1 when a step failed.
Steps marked soft (SELinux, packages, network files, `[post]`) only warn.

At the end, after unmounting: `when_done = reboot` (default), `poweroff`, or
`shell` (a shell on the console). On failure a shell is left and the log path
printed.

## Complete example

`tests/auto/example.toml` (the unit tests plan it, and check that this copy matches):

```toml
# dkinstall.toml: a complete autoinstall answers file (docs/AUTOINSTALL.md).
# Passwords are crypt(3) hashes: openssl passwd -6

[install]
# The disk: a kernel name (nvme0n1) or a path (/dev/nvme0n1). With --auto also first-nonremovable
# (first installable disk not on USB) or largest (biggest installable disk).
disk = "largest"
# Existing partitions instead: partitioning = "existing" and a [partitions] section.
partitioning = "auto"
# The root filesystem: ext4 (the default), ext3, ext2, btrfs or xfs (not with dklilo, which cannot read it).
# zfs is refused (it needs an initramfs), as is a filesystem whose tools are not on the live disc, or that
# the installed kernel cannot mount without one, with the reason (SPEC.md 5.3.4).
#root_fs = "ext4"
# REQUIRED for an autoinstall. Must name the disk the plan erases: its path, its
# kernel name, or a /dev/disk/by-id/... link to it. A selector is not enough.
confirm_erase = "/dev/nvme0n1"
# reboot (default), poweroff or shell, after everything is unmounted.
when_done = "reboot"

[system]
hostname = "node01"
domain = "lab.example"
root_hash = "$6$saltsalt$rootrootrootroot"
user = "admin"
user_hash = "$6$saltsalt$useruseruseruser"
timezone = "Europe/Berlin"
keymap = "de"
ntp = true
firewall = true
# permissive (default), enforcing or disabled; needs the SELinux policy in the image.
selinux = "permissive"

[services]
# Names of dinit services in the image (/etc/dinit.d, /usr/lib/dinit.d).
enable = ["sshd"]
disable = ["bluetoothd"]

[ssh]
enable = true
root_login = "no"
password_auth = false
# Public key for the new user; an authorized_keys line.
authorized_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl admin@lab"

[network]
# guided, copy (the live session's NetworkManager connection), manual
# (nothing configured, network services off) or manual-shell (not possible
# unattended: it is only logged as skipped).
mode = "guided"
dns = ["1.1.1.1", "9.9.9.9"]
search = "lab.example"
wifi_ssid = "Office"
wifi_psk = "a passphrase here"
wifi_hidden = false

[[network.iface]]
name = "eth0"
kind = "static"
address = "192.168.1.5/24"
gateway = "192.168.1.1"

[[network.iface]]
name = "eth1"
kind = "dhcp"

[[network.iface]]
name = "eth2"
kind = "disabled"

# Extra packages from a repository medium (apks/<arch>/ on /mnt/cdrom or --repo).
# Without such a medium the install is refused, so the section is commented out.
#[packages]
#install = ["curl", "htop"]
#keep_repo = false
# Only for a medium signed with a key the system does not already trust.
#trust_medium_key = false

[post]
# Run last, each with sh -c in a chroot of the new system (/proc is not mounted).
# A failing command is a warning, not an error.
commands = ["echo \"installed by dkinstall\" > /etc/motd", "ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime"]
```

Not covered: one user only; no locale (only keymap and timezone); no
by-label disk selection; `manual-shell` network is skipped when unattended.
The WiFi passphrase is the one secret in plain text (it has no hash form); it
is never printed or logged, but keep the file private.

## Try it without erasing anything

    dkrescue-install --auto --cmdline tests/auto/cmdline-auto \
        --answers tests/auto/example.toml --probe tests/probes/uefi-services.json --dry-run

## What the image has to do

Something must run `dkrescue-install --auto` on boot of the live system, as
root, on the console: for example a dinit service that depends on
`loginready`, started only when `/proc/cmdline` contains `dkinstall.auto=1`
(the launcher exits 0 at once otherwise), with the console as its output. It
needs `mount`, `lsblk`, `chroot`, `reboot` and `poweroff` on the live system.
