# What dkrescue-install needs from the ISO build

For the build system (dkbuilder). Checked against
`~/dkrescue/dkrescue-fixed.iso` (SHA-256
`7991de96eebf20eca6d5d2eaeb3f1283b12ee2f78ac292183700938dbb0b8c3c`), read
only, on 2026-11-01. A byte-identical copy is `dkrescue-fixed.iso.orig`.
Section numbers refer to `SPEC.md`.

## 1. What must change

These are missing from the image above. Without them the installer either
doesn't exist on the disc or does the wrong thing.

| # | Requirement | Why | Status |
|---|---|---|---|
| 1 | **`/usr/bin/dkrescue-install` in `rootfs.sfs`**, root-owned, mode 0755 | The installer itself | **Missing** |
| 2 | **`live/rootfs.size`** on the ISO, next to `rootfs.sfs`: one decimal number, the uncompressed size in bytes of the tree that went into `rootfs.sfs` (`du -sb` of that tree), newline optional | 5.2.1: the minimum disk size. Without the file the installer skips the size check, so a too-small disk is offered and the install fails late, after partitioning | **Missing** |
| 3 | **Time zone data: `/usr/share/zoneinfo`** (at least `UTC` and the usual `Region/City` files, from tzdata) | 5.4 and 5.6 step 5: the installer links `/etc/localtime` to `../usr/share/zoneinfo/<zone>`. The image has no `zoneinfo` directory, so every zone would be a dangling link | **Missing** |
| 4 | **A way to log in over the serial console in a test build** (see section 5) | The unattended QEMU tests (8) log in over `ttyS0`. The passwords of `root` and `rescue` are not known to the test | **Needs a decision** |

Recommended, not blocking:

| # | Requirement | Why |
|---|---|---|
| 5 | `/etc/skel` with a `.bashrc` and `.profile` (or whatever a new user should get) | `useradd -m` copies it. The image has none, so a new user gets an empty home |
| 6 | `/etc/os-release` | Not used by the installer; many tools expect it |

### 1.1 Building and adding the installer

From the `dkinstaller` repository (Zig 0.17.0), static, musl, baseline
x86-64 (3):

```
zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64 -Doptimize=ReleaseSafe \
    --prefix OUTDIR
install -m 0755 OUTDIR/bin/dkrescue-install  ROOTFS/usr/bin/dkrescue-install
strip ROOTFS/usr/bin/dkrescue-install        # optional; 5 MB with debug info
```

Checked: the result is `ELF 64-bit LSB executable, x86-64, statically
linked`. It has no runtime dependencies.

### 1.2 Writing `rootfs.size`

After the tree is final and before `mksquashfs`:

```
du -sb ROOTFS | cut -f1 > ISO/live/rootfs.size
```

For scale: the regular files in the current image add up to about
6,622,020,716 bytes (6.17 GiB), so the installer would ask for a disk of
at least 9 GiB (image + 25% + 512 MiB, rounded up to a whole GiB). The
file must be copied onto the ISO with the same path layout as `rootfs.sfs`:
the installer reads `/run/live/medium/live/rootfs.size`.

## 2. What is already right (keep it that way)

Everything below was checked in the image and the installer relies on it.

**Live layout (5.1).** The initrd mounts the ISO (iso9660, label
`DKRESCUE`) at `/run/live/medium` and the squashfs at `/run/live/rootfs`.
`/run/live/medium/live/rootfs.sfs` exists. The installer's "am I on the live
disc" check is exactly that file, and it copies the system from it with
`unsquashfs`, not from the running overlay. If the initrd changes where it
mounts the medium or what the file is called, the installer must change
with it.

**Kernel in the system image (5.6 step 8).** `/boot/vmlinuz-6.19-dkrescue`
is in `rootfs.sfs`. The installer picks the `vmlinuz-*` file there for
`dklilo.conf`. There must be exactly one such file, or the choice is
ambiguous. The installed system boots **without an initramfs**
(`root=PARTUUID=…`), so these must stay built into the kernel, not modules:

```
CONFIG_EXT4_FS=y   CONFIG_VFAT_FS=y  CONFIG_FAT_FS=y  CONFIG_EFI_PARTITION=y
CONFIG_MSDOS_PARTITION=y             CONFIG_BLK_DEV_NVME=y
CONFIG_SATA_AHCI=y CONFIG_ATA_PIIX=y CONFIG_VIRTIO_BLK=y CONFIG_VIRTIO_PCI=y
CONFIG_SCSI_VIRTIO=y                 CONFIG_EFI=y  CONFIG_EFI_STUB=y
CONFIG_EFIVAR_FS=y                   CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y               CONFIG_NLS_UTF8=y
```

All are `=y` in `config-6.19-dkrescue` today. (`CONFIG_VMD` was not
checked.)

**Programs the plan runs (6.3).** All present in the image:
`lsblk blkid wipefs sfdisk cfdisk mount umount mkfs.ext4 mkfs.vfat
unsquashfs chpasswd useradd userdel visudo dklilo loadkeys sync cp mv rm ln
mkdir reboot`. (`cfdisk` is only needed for manual partitioning;
`terminfo` for `linux`, `vt100` and `xterm` is present, which it needs.)

**Options those programs must support:**

| Program | Option used | Checked |
|---|---|---|
| `useradd`, `userdel`, `chpasswd` | `-R DIR` (chroot into the target) | present (shadow) |
| `chpasswd` | `-e` (already-hashed passwords from the answers file) | standard shadow |
| `unsquashfs` | `-percentage` (progress when output is a pipe) | present in the binary |
| `sfdisk` | `--part-type` (5.3.3) | present in the binary |
| `dklilo` | `install-uefi [--yes] [--removable] <esp-dir>`, `install-bios --yes <disk>`, `check <conf>` | matches `dklilo` usage output |

**System files the plan edits.** `wheel`, `video` and `render` groups exist
(`useradd -G` fails otherwise); user `rescue` exists (it is removed from the
installed system); `/etc/login.defs` has `ENCRYPT_METHOD SHA512` (musl has
no yescrypt, so typed passwords are hashed this way); `/etc/sudoers.d/00-wheel`
exists (the installer replaces it); `/etc/dinit.d/boot.d/` exists and
`/etc/dinit.d/rcboot` exists (the installer's keymap service depends on
`rcboot` and is linked into `boot.d`); `/var/log` exists. `/boot/efi` does
not need to exist: the installer creates it.

**Console keymap.** `lfs-dinit` (`dkrescue-12.3`) loads no keymap at boot.
The installer adds `/etc/dinit.d/keymap` and links it from `boot.d`. For
that, `/usr/bin/loadkeys` and `/usr/share/keymaps` (kbd) must stay on the
disc.

## 3. Things the installer must not break

- **Do not put anything in `rootfs.sfs` that must not reach an installed
  system.** The installer copies the whole squashfs. It removes `rescue`,
  replaces the sudoers policy, `/etc/fstab`, hostname, hosts, localtime and
  `machine-id`, and writes `dklilo.conf`. Anything else in the image (SSH
  host keys, shell history, test files) is copied as it is. The README of
  `lfs-dinit` already says host keys are made at first start, not baked
  in; keep it so.
- **`/etc/dinit.d/rootrw` is rewritten by the initrd** on the live disc
  (it does nothing there). The installed system gets the *squashfs's*
  version, not the initrd's, which is what an installed system needs.

## 4. Boot menu (`/boot/dklilo.conf` on the ISO)

Nothing to change for the installer. For the QEMU tests, `-nographic`
needs the serial entry (`dkrescue-serial`, with `console=ttyS0,115200`);
the default entry has no serial console. See section 5.

## 5. Test build: serial login for the QEMU tests

`tests/qemu/qemu_test.py` boots the ISO with `-nographic`, logs in at
`ttyS0`, mounts a seed disk holding the answers file and the installer,
and runs the install. It needs one of:

1. A **test ISO** that boots the `dkrescue-serial` entry by default
   (`default = dkrescue-serial`) and has a known password for `root`
   (or an autologin on `ttyS0`), **or**
2. The real password, passed in `LIVE_USER` / `LIVE_PASS`, and the serial
   entry chosen at the boot menu.

The release ISO must keep `ttyS0` without autologin (the `lfs-dinit`
README says so on purpose). Make the test credential a build option that is
off for releases.

Until `dkrescue-install` is in the image (item 1), the tests can run it
from the seed disk instead; the driver does not need a changed ISO for that.

## 6. How this was checked

All read only, from `dkrescue-fixed.iso.orig`:

```
xorriso -indev dkrescue-fixed.iso.orig -report_el_torito plain
xorriso -osirrox on -indev … -extract /live/rootfs.sfs … -extract /boot/initrd.img …
unsquashfs -l / -ll / -s rootfs.sfs            # file lists, links, sizes
unsquashfs -n -f -d DIR rootfs.sfs <paths>     # pull single files
zstdcat initrd.img | 7z x -tcpio …             # read /init
strings <binary> | grep …                      # which options a program has
```

Working files are in `~/dkrescue/iso-inspect/` and can be deleted.

## 7. Not checked yet

- That the installer works end to end. No installation has been run: the
  tests need the login in item 4.
- That a system installed this way boots with SeaBIOS and with OVMF, and
  that the `keymap` service works at boot.
- `CONFIG_VMD` and other drivers real hardware may need (5, I5).
- Whether `dklilo isohybrid`/`mkiso-images` output changes anything for the
  installer (the ISO is GPT-hybrid with an EFI image, as expected).
