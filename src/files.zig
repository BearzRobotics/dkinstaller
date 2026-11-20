//! Text generators for everything the installer writes: `fstab`, `hosts`,
//! `dklilo.conf`, sudoers and the `sfdisk` script. Pure: text in, text out.
//! Implements SPEC.md 5.3.1, 5.6 (steps 4, 5, 7, 8) and 6.1.

const std = @import("std");
const fs_mod = @import("fs.zig");
const Allocator = std.mem.Allocator;

/// GPT partition type GUIDs (lowercase, as `lsblk` prints them).
pub const guid_bios_boot = "21686148-6449-6e6f-744e-656564454649";
pub const guid_esp = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
pub const guid_linux = "0fc63daf-8483-4772-8e79-3d69d8477de4";

/// Identifiers chosen by the caller (random in production, fixed in tests)
/// so that the plan can name UUIDs before any filesystem exists.
pub const Ids = struct {
    /// ext4 UUID for a freshly formatted root.
    root_fs_uuid: []const u8,
    /// FAT volume id, 8 uppercase hex digits, for a freshly formatted ESP.
    esp_vol_id: []const u8,
    /// GPT PARTUUIDs for the automatic layout.
    root_partuuid: []const u8,
    esp_partuuid: []const u8,
    bios_partuuid: []const u8,
};

/// The pseudo-filesystem lines appended to every `fstab`.
/// OPEN: should be read from the base system's own fstab (SPEC.md 5.6.4).
pub const base_fstab =
    \\proc      /proc           proc      nosuid,noexec,nodev        0 0
    \\sysfs     /sys            sysfs     nosuid,noexec,nodev        0 0
    \\devpts    /dev/pts        devpts    gid=5,mode=620             0 0
    \\tmpfs     /run            tmpfs     defaults                   0 0
    \\devtmpfs  /dev            devtmpfs  mode=0755,nosuid           0 0
    \\cgroup2   /sys/fs/cgroup  cgroup2   nosuid,noexec,nodev        0 0
    \\
;

/// Converts a FAT volume id ("ABCD1234") to the UUID form blkid reports
/// ("ABCD-1234"). Caller owns the result.
pub fn volIdToUuid(arena: Allocator, vol_id: []const u8) ![]u8 {
    std.debug.assert(vol_id.len == 8);
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ vol_id[0..4], vol_id[4..8] });
}

/// `/etc/fstab` with an ext4 root. `esp_uuid` is null when there is no ESP to mount.
pub fn fstab(arena: Allocator, root_uuid: []const u8, esp_uuid: ?[]const u8) ![]u8 {
    return fstabFor(arena, .ext4, root_uuid, esp_uuid);
}

/// `/etc/fstab` for a root filesystem of type `root_fs` (SPEC.md 5.3.4): its type, its
/// mount options, and the fsck pass (0 for btrfs, XFS and ZFS, which have no boot-time fsck).
pub fn fstabFor(arena: Allocator, root_fs: fs_mod.Fs, root_uuid: []const u8, esp_uuid: ?[]const u8) ![]u8 {
    return fstabAt(arena, root_fs, root_uuid, esp_uuid, "/boot/efi");
}

/// As `fstabFor`, with the ESP mounted at `esp_at` (`/boot/efi`; `/boot` for systemd-boot).
pub fn fstabAt(arena: Allocator, root_fs: fs_mod.Fs, root_uuid: []const u8, esp_uuid: ?[]const u8, esp_at: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const fi = fs_mod.info(root_fs);
    const root = try std.fmt.allocPrint(arena, "UUID={s}  /          {s}  {s}    {d} {d}\n", .{ root_uuid, fi.fstab_type, fi.fstab_options, fi.fsck_pass, fi.fsck_pass });
    try out.appendSlice(arena, root);
    if (esp_uuid) |u| {
        const esp = try std.fmt.allocPrint(arena, "UUID={s}  {s}  vfat  umask=0077  0 2\n", .{ u, esp_at });
        try out.appendSlice(arena, esp);
    }
    try out.appendSlice(arena, "\n");
    try out.appendSlice(arena, base_fstab);
    return out.items;
}

/// `/etc/default/grub.d/50-dkrescue-install.cfg`: the kernel has no initramfs, so it can only
/// find the root by `root=/dev/...` or `root=PARTUUID=`; GRUB's default `root=UUID=` would not boot.
pub const grub_dropin =
    \\# Written by dkrescue-install. The installed kernel has no initramfs, which is what turns a
    \\# root=UUID=... into a device, so the kernel is given root=PARTUUID=... instead.
    \\GRUB_DISABLE_LINUX_UUID=true
    \\GRUB_DISABLE_LINUX_PARTUUID=false
    \\
;

/// `/etc/default/systemd-boot`: `gen-systemd-boot` writes root=UUID=...; a later root= on the
/// command line wins, so the PARTUUID given here (which the kernel can resolve without an initramfs) is used.
pub fn systemdBootDefaults(arena: Allocator, root_partuuid: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\# Written by dkrescue-install. No initramfs: the kernel resolves root=PARTUUID, not root=UUID;
        \\# the last root= on the command line is the one used.
        \\SD_BOOT_CMDLINE="root=PARTUUID={s} quiet"
        \\
    , .{root_partuuid});
}

/// `/etc/hostname`.
pub fn hostnameFile(arena: Allocator, hostname: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\n", .{hostname});
}

/// `/etc/hosts`.
pub fn hosts(arena: Allocator, hostname: []const u8, domain: ?[]const u8) ![]u8 {
    if (domain) |d| return std.fmt.allocPrint(
        arena,
        "127.0.0.1  localhost\n127.0.1.1  {s}.{s} {s}\n::1        localhost\n",
        .{ hostname, d, hostname },
    );
    return std.fmt.allocPrint(
        arena,
        "127.0.0.1  localhost\n127.0.1.1  {s}\n::1        localhost\n",
        .{hostname},
    );
}

/// `/etc/sudoers.d/00-wheel`.
pub const sudoers_wheel = "%wheel ALL=(ALL:ALL) ALL\n";

/// `/etc/dinit.d/keymap`: loads the console keymap at boot. lfs-dinit
/// (dkrescue-12.3) loads none itself, so the installer adds this service;
/// `boot.d/keymap` links to it. It is in `boot.d` (waits-for), so a failure
/// here never stops the boot.
pub fn keymapService(arena: Allocator, keymap: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\# Loads the console keymap chosen at install time (dkrescue-install).
        \\
        \\type = scripted
        \\command = /usr/bin/loadkeys -q {s}
        \\restart = false
        \\
        \\depends-on: rcboot
        \\
    , .{keymap});
}

/// `/boot/dklilo.conf`, in dklilo's syntax (docs/dklilo.conf.5.md): `image`
/// starts an entry, `label`, `root` and `append` belong to it. `kernel` is
/// the file name found under `/boot`.
pub fn dkliloConf(arena: Allocator, kernel: []const u8, root_partuuid: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\timeout = 50
        \\default = dkrescue
        \\
        \\image = /boot/{[k]s}
        \\    label = dkrescue
        \\    root = PARTUUID={[r]s}
        \\    append = "ro quiet"
        \\
        \\image = /boot/{[k]s}
        \\    label = dkrescue-safe
        \\    root = PARTUUID={[r]s}
        \\    append = "ro nomodeset"
        \\
    , .{ .k = kernel, .r = root_partuuid });
}

/// The `sfdisk` script for the automatic layout (SPEC.md 5.3.1).
pub fn sfdiskScript(arena: Allocator, ids: Ids) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\label: gpt
        \\first-lba: 2048
        \\
        \\size=1MiB, type={s}, uuid={s}
        \\size=512MiB, type={s}, uuid={s}
        \\type={s}, uuid={s}
        \\
    , .{
        guid_bios_boot, ids.bios_partuuid,
        guid_esp,       ids.esp_partuuid,
        guid_linux,     ids.root_partuuid,
    });
}

/// Path of partition `n` of disk `name` under /dev ("nvme0n1" -> "p2").
pub fn partitionPath(arena: Allocator, disk_name: []const u8, n: u32) ![]u8 {
    const sep: []const u8 = if (disk_name.len > 0 and std.ascii.isDigit(disk_name[disk_name.len - 1])) "p" else "";
    return std.fmt.allocPrint(arena, "/dev/{s}{s}{d}", .{ disk_name, sep, n });
}

test "fstab has root, esp and base lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try fstab(a, "r-uuid", "ABCD-1234");
    try std.testing.expect(std.mem.startsWith(u8, s, "UUID=r-uuid  /          ext4"));
    try std.testing.expect(std.mem.indexOf(u8, s, "UUID=ABCD-1234  /boot/efi  vfat  umask=0077") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "cgroup2") != null);
    const no_esp = try fstab(a, "r", null);
    try std.testing.expect(std.mem.indexOf(u8, no_esp, "/boot/efi") == null);
}

test "sfdisk script and partition paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try sfdiskScript(a, .{
        .root_fs_uuid = "x",
        .esp_vol_id = "AAAABBBB",
        .root_partuuid = "r",
        .esp_partuuid = "e",
        .bios_partuuid = "b",
    });
    try std.testing.expect(std.mem.indexOf(u8, s, "label: gpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "size=1MiB, type=21686148-6449-6e6f-744e-656564454649, uuid=b") != null);
    try std.testing.expectEqualStrings("/dev/nvme0n1p3", try partitionPath(a, "nvme0n1", 3));
    try std.testing.expectEqualStrings("/dev/sda3", try partitionPath(a, "sda", 3));
}

test "keymap service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try keymapService(arena.allocator(), "de");
    try std.testing.expect(std.mem.indexOf(u8, t, "command = /usr/bin/loadkeys -q de\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "depends-on: rcboot") != null);
}

test "dklilo.conf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try dkliloConf(arena_state.allocator(), "vmlinuz-6.12", "abc");
    try std.testing.expect(std.mem.indexOf(u8, s, "image = /boot/vmlinuz-6.12") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "root = PARTUUID=abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "nomodeset") != null);
}

pub fn uuidFromBytes(arena: Allocator, b: *const [16]u8) ![]u8 {
    var x = b.*;
    x[6] = (x[6] & 0x0f) | 0x40;
    x[8] = (x[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(arena, "{x}-{x}-{x}-{x}-{x}", .{
        x[0..4], x[4..6], x[6..8], x[8..10], x[10..16],
    });
}

/// Number of random bytes `idsFromBytes` needs.
pub const ids_entropy = 68;

/// Builds `Ids` from random bytes (UUID version 4 each), so the caller owns
/// the source of randomness and tests can use fixed bytes.
pub fn idsFromBytes(arena: Allocator, bytes: *const [ids_entropy]u8) !Ids {
    return .{
        .root_fs_uuid = try uuidFromBytes(arena, bytes[0..16]),
        .root_partuuid = try uuidFromBytes(arena, bytes[16..32]),
        .esp_partuuid = try uuidFromBytes(arena, bytes[32..48]),
        .bios_partuuid = try uuidFromBytes(arena, bytes[48..64]),
        .esp_vol_id = try std.fmt.allocPrint(arena, "{X}", .{bytes[64..68]}),
    };
}

test "idsFromBytes makes v4 UUIDs and an 8-digit volume id" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const bytes: [ids_entropy]u8 = @splat(0xAB);
    const ids = try idsFromBytes(st.allocator(), &bytes);
    try std.testing.expectEqualStrings("abababab-abab-4bab-abab-abababababab", ids.root_fs_uuid);
    try std.testing.expectEqualStrings("ABABABAB", ids.esp_vol_id);
}

test "fstab for each root filesystem" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const e = try fstabFor(a, .ext4, "r", "ABCD-1234");
    try std.testing.expect(std.mem.indexOf(u8, e, "UUID=r  /          ext4  defaults    1 1\n") != null);
    const b = try fstabFor(a, .btrfs, "r", null);
    try std.testing.expect(std.mem.indexOf(u8, b, "UUID=r  /          btrfs  defaults,noatime    0 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "/boot/efi") == null);
    const e2 = try fstabFor(a, .ext2, "r", null);
    try std.testing.expect(std.mem.indexOf(u8, e2, "ext2  defaults    1 1") != null);
}
