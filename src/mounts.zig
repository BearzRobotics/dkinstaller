//! Extra mount points for manual partitioning (SPEC.md 5.3.5): partitions on any disk that the
//! new system mounts from its fstab. The rules here are shared by the answers file, the screens
//! and the planner. Pure.

const std = @import("std");
const fs_mod = @import("fs.zig");

/// One extra mount the user asked for.
pub const Mount = struct {
    /// Partition, by kernel name or device path; it may be on any disk.
    device: []const u8,
    /// Where the new system mounts it, e.g. "/home".
    at: []const u8,
    /// Off: the partition and what is on it are kept.
    format: bool = false,
    /// The new filesystem, when formatting.
    fs: fs_mod.Fs = .ext4,
    /// The fstab options; null: the filesystem's usual ones.
    options: ?[]const u8 = null,
};

/// Directories the installed system needs before it mounts what is in fstab (it has no initramfs).
const needed_early = [_][]const u8{ "/etc", "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64" };
/// Directories that are not on any disk.
const not_on_disk = [_][]const u8{ "/proc", "/sys", "/dev", "/run", "/var/run", "/var/lock" };
/// Directories the installer fills (or the new system must find empty), so they are formatted.
const filled_by_install = [_][]const u8{ "/boot", "/var", "/opt", "/root" };

/// Whether `path` is `dir` or inside it.
pub fn within(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/');
}

/// Why `at` can't be a mount point, or null.
pub fn pathError(at: []const u8) ?[]const u8 {
    if (at.len < 2 or at.len > 200 or at[0] != '/') return "A mount point is a directory path starting with /, for example /home. (/ is the root partition.)";
    // Nothing that needs quoting in fstab or could leave the new system's tree.
    for (at) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._-", c) == null) return "Only letters, digits and / . _ - can be used in a mount point.";
    var parts = std.mem.splitScalar(u8, at[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return "No empty, . or .. parts, and no / at the end.";
    }
    for (needed_early) |d| if (within(at, d)) return "This directory must stay on the root partition: the system needs it before it can mount other partitions.";
    for (not_on_disk) |d| if (within(at, d)) return "This directory is not kept on a disk.";
    if (within(at, "/boot") and !std.mem.eql(u8, at, "/boot")) return "Only /boot itself can be chosen here; the EFI System Partition has its own screen.";
    return null;
}

/// Why the fstab options can't be used, or null.
pub fn optionsError(options: []const u8) ?[]const u8 {
    const bad = "Options are a comma-separated list without spaces, for example defaults,noatime.";
    if (options.len == 0 or options.len > 200) return bad;
    for (options) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ",=._:+@%/-", c) == null) return bad;
    var it = std.mem.splitScalar(u8, options, ',');
    while (it.next()) |o| if (o.len == 0) return bad;
    return null;
}

pub fn hasOption(options: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, options, ',');
    while (it.next()) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

/// Whether a partition mounted at `at` may keep what is on it.
pub fn mayKeep(at: []const u8) bool {
    for (filled_by_install) |d| if (within(at, d)) return false;
    return true;
}

/// The filesystems a kept partition may hold.
pub fn keepableFs(fstype: []const u8) bool {
    for ([_][]const u8{ "ext2", "ext3", "ext4", "btrfs", "xfs", "vfat" }) |f| if (std.mem.eql(u8, f, fstype)) return true;
    return false;
}

/// Parents before what is mounted inside them.
pub fn before(_: void, a: Mount, b: Mount) bool {
    return std.mem.lessThan(u8, a.at, b.at);
}

// ---------------------------------------------------------------- tests

test "mount points: what is allowed" {
    for ([_][]const u8{ "/home", "/var", "/var/log", "/boot", "/srv/data", "/mnt/media_1", "/tmp", "/opt" }) |p| try std.testing.expect(pathError(p) == null);
    for ([_][]const u8{ "", "/", "home", "/home/", "//home", "/a/../etc", "/./x", "/my data", "/a\nb", "/etc", "/etc/x", "/usr", "/usr/local", "/lib64", "/proc", "/run/x", "/var/run", "/boot/efi", "/boot/x" }) |p| try std.testing.expect(pathError(p) != null);
    try std.testing.expect(pathError("/usrdata") == null);
}

test "mount options and what may be kept" {
    try std.testing.expect(optionsError("defaults,noatime,nofail") == null);
    try std.testing.expect(optionsError("subvol=@home,compress=zstd:3") == null);
    for ([_][]const u8{ "", "a b", "a,,b", ",a", "a\n/dev/sda / x" }) |o| try std.testing.expect(optionsError(o) != null);
    try std.testing.expect(mayKeep("/home") and mayKeep("/srv") and mayKeep("/bootx"));
    try std.testing.expect(!mayKeep("/boot") and !mayKeep("/var/log") and !mayKeep("/opt"));
}
