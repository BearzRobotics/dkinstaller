# dkrescue-install — Specification

Status: **Draft v0.1**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

A text-mode installer that puts DKRescue on a computer's disk, run from the
live disc. It does what a person following the build posts would do by
hand (partition, format, copy the system, write `fstab`, set up users and
install the bootloader), and it shows every one of those steps as the
command it runs.

It's written for someone who could do the install by hand and wants to see
what's being done: every action is a visible, logged shell command, and
`--dry-run` lists them all without running any. If something fails
halfway, the log shows exactly where, and the rest can be finished by hand.

## 2. Goals and non-goals

### Goals (v1)

- Install DKRescue to a whole disk, on UEFI and BIOS machines.
- Automatic partitioning (erase the disk) and manual partitioning (with
  `cfdisk`).
- Copy the system exactly as it is on the disc, unaffected by anything done
  in the live session.
- Set the hostname, root password, one user, timezone and console keymap.
- Install dklilo, with a working `dklilo.conf`.
- Work on the kernel console at 80×24 with 16 colours, on dkde-console,
  and over a serial line.
- `--dry-run` and an answers file for unattended, repeatable installs
  (used for testing; see 8).

### Non-goals (v1)

- Installing alongside another operating system in free space
  (**post-v1**: "use free space", and adding Windows to the boot menu).
- Encrypted root, LVM or RAID as the install target.
- btrfs as the root filesystem (needs an initramfs or `BTRFS_FS` built in;
  see 5.6).
- A graphical installer.
- Network installs. Everything comes from the disc.

## 3. Constraints

DKRescue's CONSTRAINTS.md applies, and these follow from it:

- **Never touches a disk on its own.** The installer runs only when started
  by hand, as root. Nothing is written to any disk before the summary
  screen (5.5) is confirmed by typing the disk's name.
- **The live disc is never offered as a target,** nor is any disk with a
  mounted partition.
- **Offline.** Everything comes from the live medium.
- **Static.** On musl, `dkrescue-install` is one statically linked binary.
- **Runs on baseline x86-64**, like everything else on the disc.

## 4. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Zig 0.17.0** | Pinned in `build.zig.zon`, as in dklilo and dkde. |
| Terminal UI | **libvaxis**, or a small terminal layer of our own | See 4.1. |
| Disk information | `lsblk --json` and `blkid`, parsed with `std.json` | Both from util-linux, already on the disc. |
| Disk changes | `wipefs`, `sfdisk`, `mkfs.vfat`, `mkfs.ext4`, `cfdisk` | Run as commands; see 6. |
| System copy | `unsquashfs` | From squashfs-tools, on the disc for the ISO build. |
| Users | `useradd -R`, `chpasswd -R`, `userdel -R` (shadow) | `-R` works on the target without a chroot. |
| Bootloader | `dklilo install-uefi`, `install-bios`, `check` | |
| Build | `zig build` | |

### 4.1 Terminal UI library

A third-party TUI library is allowed if it's pure Zig (or links only what
can be built statically), builds with Zig 0.17.0, and is pinned by hash.
**libvaxis** is the first choice: it's pure Zig, handles terminal capability
detection and key decoding, and draws with Unicode box characters.

If it doesn't build with Zig 0.17.0, the installer uses its own small layer
instead: raw mode through `termios`, ANSI escape sequences for drawing,
and a key decoder for the sequences the Linux console, xterm-compatible
terminals and serial terminals send. The installer only needs lists,
text fields, a password field, a progress view and message boxes, so that
layer stays small.

**Decided:** the installer uses its own layer (`src/ui/term.zig`), so there
is no third-party dependency to pin. libvaxis was not tried on Zig 0.17.0.

**Rendering rules,** whichever is used:

- Works at 80×24, the size of the console with the largest default font,
  and of a serial line.
- 16 colours only, and readable without colour (selection is also shown
  with reverse video).
- Box drawing with Unicode line characters, which every console font on the
  disc has. `--ascii` switches to `+-|` for terminals that lack them.
- Keyboard only: arrows, Tab, Enter, Esc, and letter shortcuts shown on
  screen. No mouse needed.

## 5. The installation, step by step

The installer is a sequence of screens. Esc goes back one screen at any
point before 5.5. Nothing is written until 5.5 is confirmed.

### 5.1 Checks

- Running as root; otherwise it exits with a message.
- Running from the live disc: `/run/live/medium/live/rootfs.sfs` exists.
  Otherwise it exits: installing from an installed system isn't supported.
- **Firmware:** UEFI if `/sys/firmware/efi` exists, BIOS otherwise. Shown on
  the screen, because it decides the partition layout and the bootloader
  install.
- On UEFI, `/sys/firmware/efi/efivars` must be mounted read-write, so
  dklilo can create the boot entry. If it isn't, the installer says so and
  offers a removable-media install only (5.6).
- Every external program the plan will run exists (6.3). A missing one is
  reported by name before anything else happens.

### 5.2 Disk

A list of every disk that can be a target, with path, size, model,
transport (NVMe, SATA, USB) and the partitions and filesystems on it, from
`lsblk --json --bytes`. Not listed, with the reason shown below the list:

- the disk holding the live medium (the parent of the device mounted at
  `/run/live/medium`)
- disks with any partition mounted
- loop, RAM, zram and optical devices, and read-only disks
- disks smaller than the minimum size (5.2.1)

A disk that holds partitions or a recognizable filesystem is marked
**"contains data"**, and shows what was found, for example
`NTFS "Windows"` or `ext4 "home"`.

#### 5.2.1 Minimum size

The ISO build writes the system's uncompressed size, in bytes, to
`live/rootfs.size` next to `rootfs.sfs` (`du -sb` of the tree being
packed). The minimum disk size is that, plus 512 MiB for the ESP, plus 25%
free space for the installed system to use, rounded up to a whole GiB.
**OPEN:** add the `rootfs.size` step to the ISO post.

### 5.3 Partitioning

Three choices:

- **Erase the disk and partition it automatically** (5.3.1)
- **Partition by hand with `cfdisk`** (5.3.2)
- **Use the existing partitions** (5.3.3), for a disk already partitioned
  with `fdisk`, `gdisk`, `parted` or anything else. Offered only when the
  disk has a partition table.

#### 5.3.1 Automatic layout

Always GPT:

| # | Size | Type | Filesystem | Mounted at |
|---|---|---|---|---|
| 1 | 1 MiB | BIOS boot (`21686148-6449-6E6F-744E-656564454649`) | none | |
| 2 | 512 MiB | EFI System | FAT32, label `ESP` | `/boot/efi` |
| 3 | the rest | Linux filesystem | ext4, label `dkrescue` | `/` |

Partition 1 is created on **both** firmware types: it's where dklilo's
stage 2 lives on BIOS machines, and it costs 1 MiB. Partition 2 is likewise
created on both, so a disk installed on one kind of machine also boots on
the other once the matching dklilo half is installed. Partitions are
aligned to 1 MiB. No swap partition is made.

The layout is written with one `sfdisk` script, after `wipefs -a` on the
disk. The script is shown in the summary (5.5).

#### 5.3.2 Manual partitioning

- The installer runs `cfdisk` on the chosen disk and waits for it to exit.
  **This is the one step that writes before the summary screen,** because
  the user is driving it: the screen before it says so, and asks for the
  disk's name to be typed, as 5.5 does.
- When `cfdisk` exits, the disk is probed again and the installer
  continues exactly as in 5.3.3.

#### 5.3.3 Existing partitions

Nothing is written at this point: choosing partitions only fills in the
answers.

- The installer lists the disk's partitions (number, size, type,
  filesystem, label) and asks which is **root**, and, on UEFI, which is
  the **EFI System Partition**. The ESP is preselected if exactly one
  partition has the EFI System type.
- For each partition chosen, it asks whether to format it. Root is always
  formatted, and the screen says so. Not formatting an existing ESP is the
  default, so other systems' bootloaders on it are kept. An unformatted ESP
  must already hold a FAT filesystem.
- **Checks,** with the reason shown when one fails:
  - root is at least the minimum size (5.2.1), less the ESP's share
  - on UEFI, the ESP has the EFI System type and is at least 100 MiB
  - for BIOS on a GPT disk, a BIOS boot partition exists (at least
    1 MiB); on an MBR disk, the gap before the first partition is large
    enough for dklilo's stage 2 (`dklilo install-bios` itself refuses if
    not; it has no read-only `--check` yet, see 12.6, so a failure shows up
    at the bootloader step, after formatting)
- **Wrong partition type:** a partition made with `fdisk` and left as
  "Linux filesystem" when it was meant to be the ESP or the BIOS boot
  partition is common. The installer offers to set the correct type. That
  becomes one `sfdisk --part-type` step in the plan, shown in the summary
  like every other change, so it's written only after confirmation.
- No partition is created, resized or deleted in this path.

### 5.4 System settings

One screen per item, each with a sensible default:

| Setting | Default | Source of choices |
|---|---|---|
| Hostname | `dkrescue` | Checked against RFC 1123 hostname rules |
| Root password | none (must be entered twice) | |
| User name | none (must be entered) | Checked against `useradd`'s rules |
| User password | none (must be entered twice) | |
| Timezone | `UTC` | `/usr/share/zoneinfo` |
| Console keymap | the one loaded now | `/usr/share/keymaps` |

The user goes into `wheel`, `video` and `render`. An empty root password
isn't accepted: on an installed system, root is locked if the user prefers
sudo only (**OPEN:** offer "lock root, use sudo" as a choice?).

### 5.5 Summary

Before anything is written, one screen shows:

- the disk, its size and model, and **everything found on it**, in red:
  this is what will be erased
- the partition layout, or the partitions chosen and which will be
  formatted
- the settings from 5.4 (passwords as `set`)
- the full list of commands that will run (scrollable), as `--dry-run`
  would print them

To go on, the user **types the disk's name** (for example `nvme0n1`).
Enter alone does nothing. Esc goes back.

### 5.6 Install

Each step's command is shown as it runs, with its output in a scrolling
area below a progress list. The steps, in order:

1. **Partition and format** (automatic layout): `wipefs -a`, `sfdisk`,
   `mkfs.vfat -F 32 -n ESP`, `mkfs.ext4 -L dkrescue`.
2. **Mount** root at `/run/dkrescue-install/target`, and the ESP at
   `target/boot/efi`.
3. **Copy the system:** `unsquashfs -f -d <target> /run/live/medium/live/rootfs.sfs`.
   This copies the disc's system, **not** the running overlay, so nothing
   from the live session reaches the installed system: not the live
   `fstab`, not files created while testing. Progress comes from
   `unsquashfs`'s own progress output.
4. **`fstab`:** written from scratch for the target, by UUID:
   ```
   UUID=<root>   /          ext4  defaults    1 1
   UUID=<esp>    /boot/efi  vfat  umask=0077  0 2
   ```
   followed by the same `proc`, `sysfs`, `devpts`, `tmpfs`, `devtmpfs` and
   `cgroup2` lines as the base system's `fstab`.
5. **Identity:** `/etc/hostname`; `/etc/hosts` with the new hostname;
   `/etc/localtime` linked to the zone; the keymap written where the
   system's boot scripts load it (**OPEN:** the file `lfs-dinit` reads the
   console keymap from). `/etc/machine-id` is removed if present; the first
   boot creates one.
6. **Users:** `chpasswd -R <target>` for root; `useradd -R <target> -m -G
   wheel,video,render -s /bin/bash <name>` and `chpasswd -R` for the user;
   `userdel -R <target> -r rescue` removes the live disc's user.
7. **sudo:** `/etc/sudoers.d/00-wheel` is replaced with
   `%wheel ALL=(ALL:ALL) ALL`. The live disc's password-free policy says in
   its own comment that it must not reach an installed system; this is
   where that's enforced. `visudo -c -f` checks the new file before it's
   kept.
8. **Bootloader:**
   - `/boot/dklilo.conf` is written with `root=PARTUUID=<root>` (works
     without an initramfs, since ext4, NVMe, AHCI and VMD are built into the
     kernel), `append = "ro quiet"`, a `-safe` entry with `nomodeset`, and
     `timeout = 50`. The kernel path is the `vmlinuz-*` file found in the
     target's `/boot`.
   - **UEFI:** `dklilo install-uefi --yes <esp-mountpoint>` (dklilo takes the mounted ESP
     directory and finds the device itself) creates the boot entry. If the
     ESP has no `\EFI\BOOT\BOOTX64.EFI` yet, `--removable` is run too, so
     firmware that loses its boot entries still finds dklilo. An existing
     `BOOTX64.EFI` (another system's) is never replaced.
   - **BIOS:** `dklilo install-bios --yes <disk>`.
   - `dklilo check <target>/boot/dklilo.conf` must pass.
9. **Finish:** `sync`, unmount the ESP and root, and show "Installation
   complete" with the choice to reboot or return to the live system.

### 5.7 When a step fails

The install stops at the failing step. The screen shows the command, its
exit code and its last output lines, and the path of the log (6.4). The
choices are:

- **Open a shell** (`/bin/sh`, with the target still mounted and its path
  shown), to fix the problem or finish by hand
- **Quit**, which unmounts what the installer mounted

There's no automatic undo: after partitioning, there's nothing to undo to.
The installer never retries a step that changes a disk on its own.

## 6. Architecture

```
probe  ->  answers  ->  plan  ->  (summary)  ->  execute
```

### 6.1 Modules

| Module | Job |
|---|---|
| `probe` | Reads the machine: firmware type, disks and partitions (`lsblk --json`, `blkid -o export`), the live medium, mounts, `rootfs.size`, the `vmlinuz-*` name inside `rootfs.sfs` (so `plan` can stay pure), available keymaps and zones. Returns plain data. |
| `answers` | The user's choices: disk, partitioning, settings. Filled by the UI, or read from an answers file (7). |
| `plan` | **Pure:** turns probe data, answers and caller-supplied UUIDs (random in production, fixed in tests; filesystems and PARTUUIDs are created with these, so `fstab` and `dklilo.conf` can name them before they exist) into an ordered list of `Step`s. No I/O. |
| `execute` | Runs steps one by one, streams output, writes the log, stops at the first failure. |
| `ui` | The screens. Talks only to `probe`, `answers`, `plan` and `execute`. |
| `files` | Generates `fstab`, `hosts`, `dklilo.conf`, sudoers and the `sfdisk` script. Pure: text in, text out. |

`plan` and `files` do no I/O, so every decision the installer makes is unit
tested without a disk.

### 6.2 Steps

A `Step` is a description shown to the user, plus one of:

- a command: an `argv` array, run directly with no shell, so no quoting
  problems with paths
- a file write: a path and its full contents, from `files`

**Everything the installer does to the target is a `Step`.** `--dry-run`
prints the steps, and the summary screen shows the same list, so what's
shown is exactly what runs.

### 6.3 External programs

The plan records every program its steps use, and 5.1 checks them all
before the first screen. They're all on the live disc: util-linux
(`lsblk`, `blkid`, `wipefs`, `sfdisk`, `cfdisk`, `mount`, `umount`),
e2fsprogs, dosfstools, squashfs-tools, shadow, sudo (`visudo`) and dklilo.

### 6.4 Log

Everything (each step, its command line, its output and exit code) goes to
`/run/dkrescue-install/install.log` while installing, and is copied to the
target's `/var/log/dkrescue-install.log` at the end. Passwords never appear
in the log or on screen: they're passed to `chpasswd` on its standard input.

## 7. Command line

| Command | Does |
|---|---|
| `dkrescue-install` | The interactive installer |
| `dkrescue-install --dry-run` | Runs the screens, then prints the plan instead of running it |
| `dkrescue-install --answers FILE` | Takes every answer from `FILE` (INI format) and skips the screens, **except** the summary and its typed confirmation |
| `dkrescue-install --answers FILE --yes-really-erase DISK` | Fully unattended, for tests. `DISK` must match the disk in `FILE` |
| `--probe FILE` | Uses a recorded probe fixture (`tests/probes/*.json`) instead of reading the machine. For tests and `--dry-run`; never combined with execution |
| `--ascii` | ASCII box drawing |

The answers file holds passwords as hashes (`openssl passwd -6` format),
never in plain text.

## 8. Testing

- **Unit tests** for `plan` and `files`, against probe data recorded from
  real machines (UEFI and BIOS, NVMe and SATA, empty and Windows disks):
  the steps produced, the `sfdisk` script, `fstab`, `dklilo.conf`, and
  every refusal (the live disk, a mounted disk, a disk too small).
- **QEMU, unattended**, using `--answers` and `--yes-really-erase`:
  - boot the ISO with a blank 20 GB disk, install, power off, then boot
    **that disk alone**, with SeaBIOS and with OVMF, to a login prompt.
  - **Untouched-disk check** (CONSTRAINTS.md): attach a second disk with
    known contents, install to the first, and compare the second's checksum
    before and after.
- **QEMU, interactive**, once per milestone: the screens at 80×24 on the
  kernel console, over `-serial`, and with `--ascii`.
- **Real hardware**, before a release: one UEFI and one BIOS machine.

## 9. Code conventions and documentation

As in dklilo and dkde: `zig fmt`; the Zig style guide (`TitleCase` types,
`camelCase` functions, `snake_case` variables and fields); no global
mutable state; every allocation owned and freed; errors as error unions,
shown to the user only in `ui`. Every file starts with a `//!` comment
saying what it does and which section of this spec it implements; every
`pub` declaration has a `///` comment.

## 10. Repository layout

```
build.zig
build.zig.zon
SPEC.md
src/
  main.zig        command line, then ui or answers
  probe.zig
  answers.zig
  plan.zig
  files.zig
  execute.zig
  ui/             screens (and the terminal layer, if not libvaxis)
tests/
  probes/         recorded probe data from real machines
  qemu/           unattended install and boot scripts
```

## 11. Milestones

Each milestone is merged only when its acceptance criteria pass.

### I0 — Probe and plan

- `probe`, `answers` from a file, `plan`, `files`, `--dry-run`. No UI, no
  execution.
- **Done when:** `--dry-run --answers` prints a correct plan for every
  recorded probe in `tests/probes/`, and the unit tests pass.

### I1 — Screens

- Every screen from 5.1 to 5.5, ending in `--dry-run` output.
- **Done when:** the screens work at 80×24 on the kernel console, over
  serial, and with `--ascii`, and Esc goes back from every screen.

### I2 — Install on UEFI

- `execute`, 5.6 and 5.7, automatic layout, UEFI.
- **Done when:** the unattended QEMU test installs and boots with OVMF, the
  untouched-disk check passes, and a failure injected at each step stops
  cleanly with the log intact.

### I3 — Install on BIOS

- `dklilo install-bios` path.
- **Done when:** the same disk boots with SeaBIOS too, and a disk installed
  on one firmware type boots on the other after the matching `dklilo
  install-*` is run.

### I4 — Manual and existing partitions

- 5.3.2 and 5.3.3.
- **Done when:** installs onto partitions made in `cfdisk`, and onto a disk
  partitioned beforehand with `fdisk` (GPT and MBR, including one with the
  ESP left as the wrong type), all boot; and an existing ESP's other
  bootloaders are untouched.

### I5 — Real hardware

- **Done when:** installed and booted on one real UEFI machine and one
  real BIOS machine.

## 12. Open questions

1. ~~libvaxis on Zig 0.17.0, or our own terminal layer~~ (4.1): decided, our own.
2. Writing `live/rootfs.size` in the ISO build (5.2.1).
3. Where `lfs-dinit` reads the console keymap from (5.6, step 5).
4. Offer "lock root, use sudo only" (5.4).
5. Repository: its own repository, or inside the DKRescue build repository.
6. `dklilo install-bios` has no `--check` option. Add one to dklilo that
   reports whether stage 2 fits without writing, so the installer can test
   it before formatting (5.3.3).
