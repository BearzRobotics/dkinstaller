//! Reads the machine and returns plain data: firmware, disks and partitions,
//! the live medium, `rootfs.size`. Implements SPEC.md 5.1, 5.2 and 6.1.
//!
//! Everything is allocated from the caller's arena. A probe can come from
//! the running machine (`live`) or from a recorded fixture (`fromFixture`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;

/// Boot firmware type.
pub const Firmware = enum { uefi, bios };

/// One partition, as `lsblk` reports it.
pub const Partition = struct {
    /// Kernel name, e.g. "nvme0n1p2".
    name: []const u8,
    /// Device node, e.g. "/dev/nvme0n1p2".
    path: []const u8,
    /// 1-based partition number.
    number: u32,
    size: u64,
    fstype: ?[]const u8 = null,
    label: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    partuuid: ?[]const u8 = null,
    /// GPT type GUID (lowercase) or MBR type byte as "0xef".
    parttype: ?[]const u8 = null,
    mounted: bool = false,
    /// Whether `\EFI\BOOT\BOOTX64.EFI` exists on this partition. Null when
    /// unknown (not an ESP, or not looked at); the plan then assumes it does.
    has_bootx64: ?bool = null,
};

/// One whole block device.
pub const Disk = struct {
    name: []const u8,
    path: []const u8,
    /// lsblk TYPE: "disk", "loop", "rom", ...
    kind: []const u8,
    size: u64,
    model: ?[]const u8 = null,
    /// "nvme", "sata", "usb", ...
    transport: ?[]const u8 = null,
    read_only: bool = false,
    /// "gpt", "dos" or null for no partition table.
    table: ?[]const u8 = null,
    /// Filesystem on the bare disk, if any.
    fstype: ?[]const u8 = null,
    label: ?[]const u8 = null,
    mounted: bool = false,
    partitions: []const Partition = &.{},

    /// Looks a partition up by kernel name or device path.
    pub fn findPartition(self: Disk, name_or_path: []const u8) ?Partition {
        for (self.partitions) |p| {
            if (std.mem.eql(u8, p.name, name_or_path) or std.mem.eql(u8, p.path, name_or_path)) return p;
        }
        return null;
    }
};

/// Everything the planner needs to know about the machine.
pub const Probe = struct {
    firmware: Firmware,
    /// `/sys/firmware/efi/efivars` is mounted read-write.
    efivars_rw: bool,
    /// `/run/live/medium/live/rootfs.sfs` exists.
    is_live: bool,
    /// Device mounted at `/run/live/medium`, e.g. "/dev/sr0" or "/dev/sdb1".
    live_medium_source: ?[]const u8,
    /// Contents of `live/rootfs.size`; null if the file is absent (OPEN 5.2.1).
    rootfs_size: ?u64,
    /// File name of the `vmlinuz-*` kernel inside the system image. Read
    /// from the image so that the plan can stay pure (SPEC.md 5.6.8).
    kernel: ?[]const u8,
    disks: []const Disk,

    /// Looks a disk up by kernel name or device path.
    pub fn findDisk(self: Probe, name_or_path: []const u8) ?Disk {
        for (self.disks) |d| {
            if (std.mem.eql(u8, d.name, name_or_path) or std.mem.eql(u8, d.path, name_or_path)) return d;
        }
        return null;
    }

    /// Whether `disk` holds the live medium (the device itself, or one of
    /// its partitions, is what's mounted at /run/live/medium).
    pub fn holdsLiveMedium(self: Probe, disk: Disk) bool {
        const src = self.live_medium_source orelse return false;
        if (std.mem.eql(u8, disk.path, src)) return true;
        for (disk.partitions) |p| {
            if (std.mem.eql(u8, p.path, src)) return true;
        }
        return false;
    }
};

/// Why a disk can't be a target (SPEC.md 5.2).
pub const Ineligible = enum {
    live_medium,
    mounted,
    not_a_disk,
    read_only,
    too_small,

    /// Human-readable reason, shown under the disk list.
    pub fn text(self: Ineligible) []const u8 {
        return switch (self) {
            .live_medium => "holds the live medium",
            .mounted => "has a mounted partition",
            .not_a_disk => "not a physical disk (loop, RAM, zram or optical)",
            .read_only => "read-only",
            .too_small => "smaller than the minimum size",
        };
    }
};

const MiB: u64 = 1024 * 1024;
const GiB: u64 = 1024 * MiB;

/// Minimum whole-disk size for a system image of `rootfs_size` bytes:
/// image + 25% free + 512 MiB ESP, rounded up to a whole GiB (SPEC.md 5.2.1).
pub fn minDiskSize(rootfs_size: u64) u64 {
    const need = rootfs_size + rootfs_size / 4 + 512 * MiB;
    return (need + GiB - 1) / GiB * GiB;
}

/// Minimum root partition size when partitions already exist (5.3.3):
/// the minimum disk size less the ESP's share.
pub fn minRootSize(rootfs_size: u64) u64 {
    return minDiskSize(rootfs_size) - 512 * MiB;
}

/// Returns why `disk` can't be installed to, or null if it can.
/// `check_size` is false for the existing-partitions path, where the size
/// of the chosen root partition is checked instead.
pub fn ineligible(p: Probe, disk: Disk, check_size: bool) ?Ineligible {
    if (!std.mem.eql(u8, disk.kind, "disk")) return .not_a_disk;
    if (std.mem.startsWith(u8, disk.name, "zram") or std.mem.startsWith(u8, disk.name, "ram")) return .not_a_disk;
    if (p.holdsLiveMedium(disk)) return .live_medium;
    if (disk.mounted) return .mounted;
    for (disk.partitions) |part| if (part.mounted) return .mounted;
    if (disk.read_only) return .read_only;
    if (check_size) if (p.rootfs_size) |rs| if (disk.size < minDiskSize(rs)) return .too_small;
    return null;
}

// ---------------------------------------------------------------- lsblk

fn str(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn num(v: ?json.Value) u64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

fn flag(v: ?json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

fn hasMount(v: ?json.Value) bool {
    const val = v orelse return false;
    switch (val) {
        .array => |arr| {
            for (arr.items) |item| if (item == .string) return true;
            return false;
        },
        .string => return true,
        else => return false,
    }
}

fn trailingNumber(name: []const u8) u32 {
    var i = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) i -= 1;
    return std.fmt.parseInt(u32, name[i..], 10) catch 0;
}

fn parsePartition(arena: Allocator, obj: json.ObjectMap) !Partition {
    const name = str(obj.get("name")) orelse return error.BadLsblk;
    const path = str(obj.get("path")) orelse try std.fmt.allocPrint(arena, "/dev/{s}", .{name});
    return .{
        .name = name,
        .path = path,
        .number = trailingNumber(name),
        .size = num(obj.get("size")),
        .fstype = str(obj.get("fstype")),
        .label = str(obj.get("label")),
        .uuid = str(obj.get("uuid")),
        .partuuid = str(obj.get("partuuid")),
        .parttype = str(obj.get("parttype")),
        .mounted = hasMount(obj.get("mountpoints")) or hasMount(obj.get("mountpoint")),
        .has_bootx64 = if (obj.get("has_bootx64")) |v| flag(v) else null,
    };
}

/// Parses `lsblk --json --bytes -o NAME,PATH,TYPE,SIZE,MODEL,TRAN,RO,PTTYPE,
/// FSTYPE,LABEL,UUID,PARTUUID,PARTTYPE,MOUNTPOINTS` output.
pub fn parseLsblk(arena: Allocator, text: []const u8) ![]Disk {
    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    if (root != .object) return error.BadLsblk;
    const devs = root.object.get("blockdevices") orelse return error.BadLsblk;
    if (devs != .array) return error.BadLsblk;

    var disks: std.ArrayList(Disk) = .empty;
    for (devs.array.items) |dev| {
        if (dev != .object) continue;
        const o = dev.object;
        const name = str(o.get("name")) orelse continue;
        var parts: std.ArrayList(Partition) = .empty;
        if (o.get("children")) |ch| if (ch == .array) {
            for (ch.array.items) |c| {
                if (c != .object) continue;
                const ty = str(c.object.get("type")) orelse "part";
                if (!std.mem.eql(u8, ty, "part")) continue;
                try parts.append(arena, try parsePartition(arena, c.object));
            }
        };
        try disks.append(arena, .{
            .name = name,
            .path = str(o.get("path")) orelse try std.fmt.allocPrint(arena, "/dev/{s}", .{name}),
            .kind = str(o.get("type")) orelse "disk",
            .size = num(o.get("size")),
            .model = str(o.get("model")),
            .transport = str(o.get("tran")),
            .read_only = flag(o.get("ro")),
            .table = str(o.get("pttype")),
            .fstype = str(o.get("fstype")),
            .label = str(o.get("label")),
            .mounted = hasMount(o.get("mountpoints")),
            .partitions = parts.items,
        });
    }
    return disks.items;
}

/// Builds a Probe from a recorded fixture: a JSON object with the machine
/// facts and an embedded `lsblk` object (tests/probes/*.json).
pub fn fromFixture(arena: Allocator, text: []const u8) !Probe {
    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    if (root != .object) return error.BadFixture;
    const o = root.object;
    const lsblk = o.get("lsblk") orelse return error.BadFixture;
    const lsblk_text = try json.Stringify.valueAlloc(arena, lsblk, .{});
    const fw_text = str(o.get("firmware")) orelse return error.BadFixture;
    return .{
        .firmware = if (std.mem.eql(u8, fw_text, "uefi")) .uefi else .bios,
        .efivars_rw = if (o.get("efivars_rw")) |v| flag(v) else false,
        .is_live = if (o.get("is_live")) |v| flag(v) else true,
        .live_medium_source = str(o.get("live_medium_source")),
        .rootfs_size = if (o.get("rootfs_size")) |v| num(v) else null,
        .kernel = str(o.get("kernel")),
        .disks = try parseLsblk(arena, lsblk_text),
    };
}

// ---------------------------------------------------------------- live

const lsblk_columns = "NAME,PATH,TYPE,SIZE,MODEL,TRAN,RO,PTTYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTTYPE,MOUNTPOINTS";

fn readSmall(arena: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Reads the running machine.
pub fn live(arena: Allocator, io: Io) !Probe {
    const lsblk = try std.process.run(arena, io, .{
        .argv = &.{ "lsblk", "--json", "--bytes", "-o", lsblk_columns },
    });
    if (!lsblk.term.success()) return error.LsblkFailed;

    var efivars_rw = false;
    var medium: ?[]const u8 = null;
    if (readSmall(arena, io, "/proc/self/mounts")) |mounts| {
        var lines = std.mem.splitScalar(u8, mounts, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const src = f.next() orelse continue;
            const dst = f.next() orelse continue;
            _ = f.next();
            const opts = f.next() orelse continue;
            if (std.mem.eql(u8, dst, "/sys/firmware/efi/efivars")) {
                var o = std.mem.tokenizeScalar(u8, opts, ',');
                while (o.next()) |opt| if (std.mem.eql(u8, opt, "rw")) {
                    efivars_rw = true;
                };
            }
            if (std.mem.eql(u8, dst, "/run/live/medium")) medium = src;
        }
    }

    var rootfs_size: ?u64 = null;
    if (readSmall(arena, io, "/run/live/medium/live/rootfs.size")) |t| {
        rootfs_size = std.fmt.parseInt(u64, std.mem.trim(u8, t, " \n\r\t"), 10) catch null;
    }

    const sfs = "/run/live/medium/live/rootfs.sfs";
    const is_live = exists(io, sfs);
    return .{
        .firmware = if (exists(io, "/sys/firmware/efi")) .uefi else .bios,
        .efivars_rw = efivars_rw,
        .is_live = is_live,
        .live_medium_source = medium,
        .rootfs_size = rootfs_size,
        .kernel = if (is_live) findKernel(arena, io, sfs) else null,
        .disks = try parseLsblk(arena, lsblk.stdout),
    };
}

/// Finds the highest `boot/vmlinuz-*` inside the system image.
fn findKernel(arena: Allocator, io: Io, sfs: []const u8) ?[]const u8 {
    const r = std.process.run(arena, io, .{ .argv = &.{ "unsquashfs", "-l", sfs } }) catch return null;
    if (!r.term.success()) return null;
    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        const marker = "/boot/vmlinuz-";
        const i = std.mem.indexOf(u8, line, marker) orelse continue;
        const name = line[i + "/boot/".len ..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        if (best == null or std.mem.order(u8, name, best.?) == .gt) best = name;
    }
    return best;
}

// ---------------------------------------------------------------- tests

test "min sizes" {
    // 3 GiB image -> 3.75 GiB + 0.5 GiB = 4.25 -> 5 GiB
    try std.testing.expectEqual(5 * GiB, minDiskSize(3 * GiB));
    try std.testing.expectEqual(5 * GiB - 512 * MiB, minRootSize(3 * GiB));
}

test "parseLsblk reads nested partitions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const disks = try parseLsblk(arena_state.allocator(),
        \\{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":1000,"ro":false,
        \\ "pttype":"gpt","mountpoints":[null],"children":[
        \\ {"name":"sda1","path":"/dev/sda1","type":"part","size":500,"fstype":"ntfs","label":"Windows",
        \\  "mountpoints":["/mnt"]}]}]}
    );
    try std.testing.expectEqual(@as(usize, 1), disks.len);
    try std.testing.expectEqualStrings("gpt", disks[0].table.?);
    try std.testing.expect(!disks[0].mounted);
    try std.testing.expectEqual(@as(u32, 1), disks[0].partitions[0].number);
    try std.testing.expect(disks[0].partitions[0].mounted);
    try std.testing.expectEqualStrings("Windows", disks[0].partitions[0].label.?);
}
