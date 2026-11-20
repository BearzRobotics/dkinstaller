//! The boot loaders the installer can put on the new system (SPEC.md 5.6.8):
//! dklilo (the default), GRUB and systemd-boot. Which one is usable depends on the
//! firmware and on what the live disc (the image the new system is copied from)
//! has. Pure: the facts come in as arguments (`Probe.tools`, `Probe.paths`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs_mod = @import("fs.zig");

pub const Bootloader = enum { dklilo, grub, @"systemd-boot" };

pub const all = [_]Bootloader{ .dklilo, .grub, .@"systemd-boot" };

pub const Firmware = enum { bios, uefi };

pub const Info = struct {
    name: []const u8,
    title: []const u8,
    /// Programs needed in `PATH` of the live disc (the target is a copy of it).
    tools: []const []const u8,
    /// The package(s) with them, for the "missing" message.
    package: []const u8,
    /// Files or directories that must exist, per firmware: GRUB's modules for the platform.
    bios_paths: []const []const u8,
    uefi_paths: []const []const u8,
    /// Package with the paths of the platform, for the message.
    platform_package_bios: []const u8,
    platform_package_uefi: []const u8,
    /// BIOS machines are supported.
    bios: bool,
};

pub fn info(b: Bootloader) Info {
    return switch (b) {
        .dklilo => .{ .name = "dklilo", .title = "dklilo (the default)", .tools = &.{"dklilo"}, .package = "dklilo", .bios_paths = &.{}, .uefi_paths = &.{}, .platform_package_bios = "", .platform_package_uefi = "", .bios = true },
        .grub => .{
            .name = "grub",
            .title = "GRUB",
            .tools = &.{ "grub-install", "update-grub" },
            .package = "grub",
            .bios_paths = &.{"/usr/lib/grub/i386-pc"},
            .uefi_paths = &.{"/usr/lib/grub/x86_64-efi"},
            .platform_package_bios = "grub-i386-pc",
            .platform_package_uefi = "grub-x86_64-efi",
            .bios = true,
        },
        .@"systemd-boot" => .{
            .name = "systemd-boot",
            .title = "systemd-boot (UEFI only)",
            .tools = &.{ "bootctl", "gen-systemd-boot" },
            .package = "systemd-boot",
            .bios_paths = &.{},
            .uefi_paths = &.{"/usr/lib/systemd/boot/efi"},
            .platform_package_bios = "",
            .platform_package_uefi = "systemd-boot",
            .bios = false,
        },
    };
}

/// The programs the probe looks for on the live disc, besides dklilo (a required program).
pub const candidate_tools = [_][]const u8{ "grub-install", "update-grub", "bootctl", "gen-systemd-boot" };

/// The paths the probe looks for.
pub const candidate_paths = [_][]const u8{ "/usr/lib/grub/i386-pc", "/usr/lib/grub/x86_64-efi", "/usr/lib/systemd/boot/efi" };

pub fn parse(name: []const u8) ?Bootloader {
    return std.meta.stringToEnum(Bootloader, name);
}

/// Whether the loader itself can read `/boot` on a root of type `fs`. systemd-boot never
/// reads the root: the kernel is on the ESP, so any root the kernel can mount works.
pub fn canReadRoot(b: Bootloader, fs: fs_mod.Fs) bool {
    return switch (b) {
        .dklilo => fs_mod.info(fs).boot_readable,
        .grub => switch (fs) {
            .ext2, .ext3, .ext4, .btrfs, .xfs => true,
            .zfs => false, // only with a pool made for GRUB's feature set; not offered
        },
        .@"systemd-boot" => true,
    };
}

pub const Availability = union(enum) {
    ok,
    unusable: []const u8,
};

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// SPEC.md 5.6.8: the firmware, then the programs, then the platform files.
pub fn availability(arena: Allocator, b: Bootloader, fw: Firmware, tools: []const []const u8, paths: []const []const u8) Allocator.Error!Availability {
    const i = info(b);
    if (fw == .bios and !i.bios) {
        return .{ .unusable = try std.fmt.allocPrint(arena, "{s} boots UEFI machines only, and this one is BIOS", .{i.name}) };
    }
    if (b != .dklilo) {
        var missing: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        for (i.tools) |t| {
            if (has(tools, t)) continue;
            if (n > 0) try missing.appendSlice(arena, " and ");
            try missing.appendSlice(arena, t);
            n += 1;
        }
        if (n > 0) {
            return .{ .unusable = try std.fmt.allocPrint(arena, "the live disc is missing {s} (package {s})", .{ missing.items, i.package }) };
        }
    }
    const need = if (fw == .bios) i.bios_paths else i.uefi_paths;
    for (need) |path| {
        if (!has(paths, path)) {
            const pkg = if (fw == .bios) i.platform_package_bios else i.platform_package_uefi;
            return .{ .unusable = try std.fmt.allocPrint(arena, "the live disc is missing {s} (package {s})", .{ path, pkg }) };
        }
    }
    return .ok;
}

// ---------------------------------------------------------------- tests

test "dklilo is always available; GRUB and systemd-boot need their tools and files" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try availability(a, .dklilo, .bios, &.{}, &.{})) == .ok);
    const g = try availability(a, .grub, .bios, &.{}, &.{});
    try std.testing.expectEqualStrings("the live disc is missing grub-install and update-grub (package grub)", g.unusable);
    const gp = try availability(a, .grub, .bios, &.{ "grub-install", "update-grub" }, &.{});
    try std.testing.expectEqualStrings("the live disc is missing /usr/lib/grub/i386-pc (package grub-i386-pc)", gp.unusable);
    try std.testing.expect((try availability(a, .grub, .bios, &.{ "grub-install", "update-grub" }, &.{"/usr/lib/grub/i386-pc"})) == .ok);
    try std.testing.expect((try availability(a, .grub, .uefi, &.{ "grub-install", "update-grub" }, &.{"/usr/lib/grub/x86_64-efi"})) == .ok);
}

test "systemd-boot is UEFI only" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const bios = try availability(a, .@"systemd-boot", .bios, &.{ "bootctl", "gen-systemd-boot" }, &.{"/usr/lib/systemd/boot/efi"});
    try std.testing.expectEqualStrings("systemd-boot boots UEFI machines only, and this one is BIOS", bios.unusable);
    try std.testing.expect((try availability(a, .@"systemd-boot", .uefi, &.{ "bootctl", "gen-systemd-boot" }, &.{"/usr/lib/systemd/boot/efi"})) == .ok);
}

test "which loader can read which root" {
    try std.testing.expect(canReadRoot(.dklilo, .btrfs));
    try std.testing.expect(!canReadRoot(.dklilo, .xfs));
    try std.testing.expect(canReadRoot(.grub, .xfs));
    try std.testing.expect(!canReadRoot(.grub, .zfs));
    try std.testing.expect(canReadRoot(.@"systemd-boot", .xfs));
    try std.testing.expectEqual(Bootloader.@"systemd-boot", parse("systemd-boot").?);
}
