//! The root filesystems the installer can make (SPEC.md 5.3.4): which programs
//! each needs, whether the installed kernel can mount it without an initramfs,
//! and whether dklilo can read `/boot` on it. Pure: the facts about the live
//! disc and its kernel come in as arguments (`Probe.tools`, `Probe.kernel_builtin`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The choices for `/`. `ext4` is the default.
pub const Fs = enum { ext4, ext3, ext2, btrfs, xfs, zfs };

pub const all = [_]Fs{ .ext4, .ext3, .ext2, .btrfs, .xfs, .zfs };

/// What is known about one filesystem.
pub const Info = struct {
    /// Name in the answers file (`root_fs = "btrfs"`) and in messages.
    name: []const u8,
    /// One line for the menu.
    title: []const u8,
    /// Programs needed on the live disc to make it, in `PATH`.
    tools: []const []const u8,
    /// The package that has them (for the "missing" message).
    package: []const u8,
    /// `CONFIG_<this>=y` in the installed kernel's config means no initramfs is needed;
    /// null: always fine (ext4 is built in, and ext2 and ext3 use its driver).
    kernel_symbol: ?[]const u8,
    /// dklilo reads this filesystem (so `/boot` can be on it).
    boot_readable: bool,
    /// The type in fstab.
    fstab_type: []const u8,
    /// The fsck pass in fstab (0: none).
    fsck_pass: u8,
    /// Mount options in fstab.
    fstab_options: []const u8,
};

pub fn info(fs: Fs) Info {
    return switch (fs) {
        .ext4 => .{ .name = "ext4", .title = "ext4 (the default)", .tools = &.{"mkfs.ext4"}, .package = "e2fsprogs", .kernel_symbol = null, .boot_readable = true, .fstab_type = "ext4", .fsck_pass = 1, .fstab_options = "defaults" },
        .ext3 => .{ .name = "ext3", .title = "ext3", .tools = &.{"mkfs.ext3"}, .package = "e2fsprogs", .kernel_symbol = null, .boot_readable = true, .fstab_type = "ext3", .fsck_pass = 1, .fstab_options = "defaults" },
        .ext2 => .{ .name = "ext2", .title = "ext2 (no journal)", .tools = &.{"mkfs.ext2"}, .package = "e2fsprogs", .kernel_symbol = null, .boot_readable = true, .fstab_type = "ext2", .fsck_pass = 1, .fstab_options = "defaults" },
        .btrfs => .{ .name = "btrfs", .title = "btrfs", .tools = &.{"mkfs.btrfs"}, .package = "btrfs-progs", .kernel_symbol = "BTRFS_FS", .boot_readable = true, .fstab_type = "btrfs", .fsck_pass = 0, .fstab_options = "defaults,noatime" },
        .xfs => .{ .name = "xfs", .title = "XFS", .tools = &.{"mkfs.xfs"}, .package = "xfsprogs", .kernel_symbol = "XFS_FS", .boot_readable = false, .fstab_type = "xfs", .fsck_pass = 0, .fstab_options = "defaults" },
        .zfs => .{ .name = "zfs", .title = "ZFS", .tools = &.{ "zpool", "zfs" }, .package = "zfs", .kernel_symbol = null, .boot_readable = false, .fstab_type = "zfs", .fsck_pass = 0, .fstab_options = "defaults" },
    };
}

/// The optional programs the probe looks for on the live disc (ext4's mkfs and
/// mkfs.vfat are required programs, checked by 5.1).
pub const candidate_tools = [_][]const u8{ "mkfs.ext2", "mkfs.ext3", "mkfs.btrfs", "mkfs.xfs", "zpool", "zfs" };

/// The kernel config symbols the probe looks for (`CONFIG_<name>=y`).
pub const kernel_symbols = [_][]const u8{ "BTRFS_FS", "XFS_FS" };

pub fn parse(name: []const u8) ?Fs {
    return std.meta.stringToEnum(Fs, name);
}

/// Whether a filesystem can be the root, and if not, why (a sentence for the screen).
pub const Availability = union(enum) {
    ok,
    unusable: []const u8,
};

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// Whether the chosen boot loader can read `/boot` on this root (SPEC.md 5.6.8).
pub const BootCheck = struct {
    readable: bool,
    loader: []const u8,
};

/// SPEC.md 5.3.4: the tools first (so a missing tool is what the user is told,
/// as the thing they can fix), then what the installed system cannot do yet.
pub fn availability(arena: Allocator, fs: Fs, tools: []const []const u8, kernel_builtin: []const []const u8, boot: BootCheck) Allocator.Error!Availability {
    const i = info(fs);
    var missing: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (i.tools) |t| {
        if (has(tools, t) or (fs == .ext4)) continue; // ext4's mkfs is a required program
        if (n > 0) try missing.appendSlice(arena, " and ");
        try missing.appendSlice(arena, t);
        n += 1;
    }
    if (n > 0) {
        return .{ .unusable = try std.fmt.allocPrint(arena, "the live disc is missing {s} (package {s})", .{ missing.items, i.package }) };
    }
    if (fs == .zfs) return .{ .unusable = "ZFS needs an initramfs with the ZFS module, which installed systems do not have yet" };
    if (i.kernel_symbol) |sym| {
        if (!has(kernel_builtin, sym)) {
            return .{ .unusable = try std.fmt.allocPrint(arena, "{s} is a module in this kernel, so it needs an initramfs, which installed systems do not have yet (it is built in from linux r4)", .{i.name}) };
        }
    }
    if (!boot.readable) {
        return .{ .unusable = try std.fmt.allocPrint(arena, "{s} cannot read {s}: choose GRUB or systemd-boot as the boot loader", .{ boot.loader, i.name }) };
    }
    return .ok;
}

/// The command that makes the filesystem on `dev`. `force`: overwrite what is
/// there (an existing partition that held a filesystem). `grub_boot`: GRUB has
/// to read `/boot` from it.
pub fn mkfsArgv(arena: Allocator, fs: Fs, label: []const u8, uuid: []const u8, dev: []const u8, force: bool, grub_boot: bool) Allocator.Error![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    switch (fs) {
        .ext4, .ext3, .ext2 => {
            try a.append(arena, try std.fmt.allocPrint(arena, "mkfs.{s}", .{info(fs).name}));
            if (force) try a.append(arena, "-F");
            try a.appendSlice(arena, &.{ "-L", label, "-U", uuid, dev });
        },
        .btrfs => {
            try a.append(arena, "mkfs.btrfs");
            if (force) try a.append(arena, "-f");
            try a.appendSlice(arena, &.{ "-L", label, "-U", uuid, dev });
        },
        .xfs => {
            try a.append(arena, "mkfs.xfs");
            if (force) try a.append(arena, "-f");
            // GRUB 2.12 can't read XFS with these, which mkfs.xfs turns on by
            // default: grub-install fails with "unknown filesystem" after the erase.
            if (grub_boot) try a.appendSlice(arena, &.{ "-i", "nrext64=0,exchange=0", "-n", "parent=0" });
            try a.appendSlice(arena, &.{ "-L", label, "-m", try std.fmt.allocPrint(arena, "uuid={s}", .{uuid}), dev });
        },
        // Not selectable (availability): the pool is made by a later release.
        .zfs => try a.appendSlice(arena, &.{ "zpool", "create", dev }),
    }
    return a.items;
}

// ---------------------------------------------------------------- tests

const ok_boot: BootCheck = .{ .readable = true, .loader = "dklilo" };
const dklilo_boot: BootCheck = .{ .readable = false, .loader = "dklilo" };

fn arenaTest() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "ext4 is always available; the others need their tools" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try availability(a, .ext4, &.{}, &.{}, ok_boot)) == .ok);
    const e3 = try availability(a, .ext3, &.{}, &.{}, ok_boot);
    try std.testing.expectEqualStrings("the live disc is missing mkfs.ext3 (package e2fsprogs)", e3.unusable);
    try std.testing.expect((try availability(a, .ext3, &.{"mkfs.ext3"}, &.{}, ok_boot)) == .ok);
}

test "btrfs needs mkfs.btrfs and a kernel that has it built in" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const no_tool = try availability(a, .btrfs, &.{}, &.{"BTRFS_FS"}, ok_boot);
    try std.testing.expectEqualStrings("the live disc is missing mkfs.btrfs (package btrfs-progs)", no_tool.unusable);
    const module = try availability(a, .btrfs, &.{"mkfs.btrfs"}, &.{}, ok_boot);
    try std.testing.expect(std.mem.indexOf(u8, module.unusable, "needs an initramfs") != null);
    try std.testing.expect((try availability(a, .btrfs, &.{"mkfs.btrfs"}, &.{"BTRFS_FS"}, ok_boot)) == .ok);
}

test "xfs and zfs are listed with the reason they cannot be chosen yet" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const x = try availability(a, .xfs, &.{"mkfs.xfs"}, &.{"XFS_FS"}, dklilo_boot);
    try std.testing.expect(std.mem.indexOf(u8, x.unusable, "dklilo cannot read xfs") != null);
    const xm = try availability(a, .xfs, &.{}, &.{}, dklilo_boot);
    try std.testing.expectEqualStrings("the live disc is missing mkfs.xfs (package xfsprogs)", xm.unusable);
    const z = try availability(a, .zfs, &.{ "zpool", "zfs" }, &.{}, ok_boot);
    try std.testing.expect(std.mem.indexOf(u8, z.unusable, "initramfs") != null);
    const zm = try availability(a, .zfs, &.{"zfs"}, &.{}, dklilo_boot);
    try std.testing.expectEqualStrings("the live disc is missing zpool (package zfs)", zm.unusable);
    const zb = try availability(a, .zfs, &.{}, &.{}, dklilo_boot);
    try std.testing.expectEqualStrings("the live disc is missing zpool and zfs (package zfs)", zb.unusable);
}

test "xfs is available once the loader can read it and the kernel has it built in" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const grub: BootCheck = .{ .readable = true, .loader = "grub" };
    try std.testing.expect((try availability(a, .xfs, &.{"mkfs.xfs"}, &.{"XFS_FS"}, grub)) == .ok);
}

test "mkfs command lines" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const e = try mkfsArgv(a, .ext4, "dkrescue", "u-u-i-d", "/dev/sda3", false, false);
    try std.testing.expectEqualSlices(u8, "mkfs.ext4", e[0]);
    try std.testing.expectEqual(@as(usize, 6), e.len);
    const e2 = try mkfsArgv(a, .ext2, "x", "u", "/dev/sda3", true, false);
    try std.testing.expectEqualStrings("mkfs.ext2", e2[0]);
    try std.testing.expectEqualStrings("-F", e2[1]);
    const b = try mkfsArgv(a, .btrfs, "x", "u", "/dev/sda3", true, false);
    try std.testing.expectEqualStrings("mkfs.btrfs", b[0]);
    try std.testing.expectEqualStrings("-f", b[1]);
    const x = try mkfsArgv(a, .xfs, "x", "u", "/dev/sda3", false, false);
    try std.testing.expectEqualStrings("uuid=u", x[4]);
    const xg = try mkfsArgv(a, .xfs, "x", "u", "/dev/sda3", false, true);
    const wanted = [_][]const u8{ "mkfs.xfs", "-i", "nrext64=0,exchange=0", "-n", "parent=0", "-L", "x", "-m", "uuid=u", "/dev/sda3" };
    try std.testing.expectEqual(wanted.len, xg.len);
    for (wanted, xg) |w, got| try std.testing.expectEqualStrings(w, got);
}

test "parse and info" {
    try std.testing.expectEqual(Fs.btrfs, parse("btrfs").?);
    try std.testing.expect(parse("ntfs") == null);
    try std.testing.expectEqual(@as(u8, 0), info(.btrfs).fsck_pass);
    try std.testing.expect(!info(.xfs).boot_readable);
}
