//! Autoinstall (docs/AUTOINSTALL.md): finding the answers file and the gates
//! that must all hold before a disk is erased without a typed confirmation.
//! Pure apart from `discover`, which looks at directories it is given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const probe_mod = @import("probe.zig");
const answers_mod = @import("answers.zig");

pub const Probe = probe_mod.Probe;
pub const Disk = probe_mod.Disk;

/// Where the answers file is looked for on a medium root, by convention.
pub const live_medium_file = "install/answers.ini";
pub const removable_file = "dkinstall.ini";
/// Where the installer mounts a removable medium to read the file.
pub const mount_point = "/mnt/dkinstall-auto";

/// What the kernel command line says about autoinstall.
pub const Cmdline = struct {
    /// `dkinstall.auto=1`.
    auto: bool = false,
    /// `dkinstall.answers=PATH` (a path on the live system, never a URL).
    answers: ?[]const u8 = null,
};

pub fn parseCmdline(text: []const u8) Cmdline {
    var c: Cmdline = .{};
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "dkinstall.auto=1")) c.auto = true;
        if (std.mem.startsWith(u8, tok, "dkinstall.answers=")) {
            const v = tok["dkinstall.answers=".len..];
            if (v.len > 0 and v[0] == '/') c.answers = v;
        }
    }
    return c;
}

pub const Source = enum { explicit, live_medium, mounted_medium };

pub const Found = struct {
    path: []const u8,
    source: Source,
};

pub const DiscoverOpts = struct {
    /// `--answers` or `dkinstall.answers=`.
    explicit: ?[]const u8 = null,
    live_medium: []const u8 = "/run/live/medium",
    /// Roots of media that are already mounted; each is checked at its top and
    /// one directory down (/media/<label>/).
    media_roots: []const []const u8 = &.{ "/mnt", "/media", "/run/media" },
};

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// The first answers file, in this order: the explicit path, the live
/// medium's `install/answers.ini`, then `dkinstall.ini` at the root of a
/// mounted medium. An explicit path that does not exist is not replaced by
/// a later one: it is null (the caller says so).
pub fn discover(arena: Allocator, io: Io, o: DiscoverOpts) Allocator.Error!?Found {
    if (o.explicit) |p| return if (isFile(io, p)) .{ .path = p, .source = .explicit } else null;
    const lm = try std.fmt.allocPrint(arena, "{s}/{s}", .{ o.live_medium, live_medium_file });
    if (isFile(io, lm)) return .{ .path = lm, .source = .live_medium };
    for (o.media_roots) |root| {
        const top = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, removable_file });
        if (isFile(io, top)) return .{ .path = top, .source = .mounted_medium };
        var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            const p = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, e.name, removable_file });
            if (isFile(io, p)) return .{ .path = p, .source = .mounted_medium };
        }
    }
    return null;
}

/// Why an autoinstall must not erase anything. `message` says it for the user.
pub const Gate = enum {
    no_flag,
    no_confirm,
    no_such_disk,
    confirm_mismatch,
    live_medium,

    pub fn message(self: Gate) []const u8 {
        return switch (self) {
            .no_flag => "dkinstall.auto=1 is not on the kernel command line",
            .no_confirm => "the answers file has no [install] confirm_erase: an autoinstall erases a disk only when the file names it",
            .no_such_disk => "[install] disk matches no disk that can be installed to",
            .confirm_mismatch => "[install] confirm_erase does not name the disk the plan would erase",
            .live_medium => "the chosen disk holds the live medium",
        };
    }
};

fn removableLike(d: Disk) bool {
    const t = d.transport orelse return false;
    return std.mem.eql(u8, t, "usb");
}

/// Resolves `[install] disk`: `first-nonremovable` (the first eligible disk
/// that is not on USB), `largest` (the biggest eligible disk), or a kernel
/// name or device path. Null if none qualifies.
pub fn resolveDisk(p: Probe, selector: []const u8) ?Disk {
    if (std.mem.eql(u8, selector, "first-nonremovable")) {
        for (p.disks) |d| {
            if (removableLike(d)) continue;
            if (probe_mod.ineligible(p, d, true) == null) return d;
        }
        return null;
    }
    if (std.mem.eql(u8, selector, "largest")) {
        var best: ?Disk = null;
        for (p.disks) |d| {
            if (probe_mod.ineligible(p, d, true) != null) continue;
            if (best == null or d.size > best.?.size) best = d;
        }
        return best;
    }
    return p.findDisk(selector);
}

/// `confirm` must equal the resolved disk's device path or kernel name, or a
/// `/dev/disk/by-*` link that resolves to it (`link_target` is where `confirm`
/// points, when the caller could resolve it).
pub fn confirmMatches(confirm: []const u8, disk: Disk, link_target: ?[]const u8) bool {
    if (std.mem.eql(u8, confirm, disk.path) or std.mem.eql(u8, confirm, disk.name)) return true;
    if (std.mem.startsWith(u8, confirm, "/dev/disk/by-")) if (link_target) |t| return std.mem.eql(u8, t, disk.path);
    return false;
}

pub const Checked = union(enum) {
    ok: Disk,
    refused: Gate,
};

/// All the gates, in order. `link_target` is `confirm_erase` resolved if it is a by-id link.
pub fn check(p: Probe, flag: bool, a: answers_mod.Answers, link_target: ?[]const u8) Checked {
    if (!flag) return .{ .refused = .no_flag };
    const confirm = a.confirm_erase orelse return .{ .refused = .no_confirm };
    const disk = resolveDisk(p, a.disk) orelse return .{ .refused = .no_such_disk };
    if (p.holdsLiveMedium(disk)) return .{ .refused = .live_medium };
    if (!confirmMatches(confirm, disk, link_target)) return .{ .refused = .confirm_mismatch };
    return .{ .ok = disk };
}

// ---------------------------------------------------------------- tests

fn fixture(arena: Allocator, name: []const u8) !Probe {
    const path = try std.fmt.allocPrint(arena, "tests/probes/{s}", .{name});
    const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    return probe_mod.fromFixture(arena, text);
}

fn ans(disk: []const u8, confirm: ?[]const u8) answers_mod.Answers {
    return .{
        .disk = disk,
        .partitioning = .auto,
        .root_pw = .{ .hash = "$6$a$b" },
        .user = "u",
        .user_pw = .{ .hash = "$6$a$b" },
        .confirm_erase = confirm,
    };
}

test "kernel command line" {
    try std.testing.expect(parseCmdline("quiet root=live:LABEL=X dkinstall.auto=1").auto);
    try std.testing.expect(!parseCmdline("quiet dkinstall.auto=0 xdkinstall.auto=1").auto);
    try std.testing.expectEqualStrings("/mnt/a.ini", parseCmdline("dkinstall.auto=1 dkinstall.answers=/mnt/a.ini").answers.?);
    try std.testing.expect(parseCmdline("dkinstall.answers=http://x/a.ini").answers == null);
}

test "discovery order: explicit, live medium, then a mounted medium" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    try tmp.dir.createDirPath(std.testing.io, "live/install");
    try tmp.dir.createDirPath(std.testing.io, "media/usb1");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "media/usb1/dkinstall.ini", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "given.ini", .data = "x" });
    const live = try std.fmt.allocPrint(arena, "{s}/live", .{root});
    const media = try std.fmt.allocPrint(arena, "{s}/media", .{root});
    const roots = [_][]const u8{media};

    // Only the medium has one.
    var f = (try discover(arena, std.testing.io, .{ .live_medium = live, .media_roots = &roots })).?;
    try std.testing.expectEqual(Source.mounted_medium, f.source);
    try std.testing.expect(std.mem.endsWith(u8, f.path, "media/usb1/dkinstall.ini"));
    // The live medium's file wins over it.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "live/install/answers.ini", .data = "x" });
    f = (try discover(arena, std.testing.io, .{ .live_medium = live, .media_roots = &roots })).?;
    try std.testing.expectEqual(Source.live_medium, f.source);
    // An explicit path wins over both.
    const given = try std.fmt.allocPrint(arena, "{s}/given.ini", .{root});
    f = (try discover(arena, std.testing.io, .{ .explicit = given, .live_medium = live, .media_roots = &roots })).?;
    try std.testing.expectEqual(Source.explicit, f.source);
    // An explicit path that is missing is not replaced by a later one.
    try std.testing.expect((try discover(arena, std.testing.io, .{ .explicit = "/nonexistent/a.ini", .live_medium = live, .media_roots = &roots })) == null);
    // Nothing anywhere.
    try std.testing.expect((try discover(arena, std.testing.io, .{ .live_medium = "/nonexistent", .media_roots = &.{"/nonexistent"} })) == null);
}

test "selectors: path, largest, first-nonremovable" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try fixture(arena, "uefi-nvme-blank.json");
    try std.testing.expectEqualStrings("nvme0n1", resolveDisk(p, "/dev/nvme0n1").?.name);
    try std.testing.expectEqualStrings("nvme0n1", resolveDisk(p, "largest").?.name);
    try std.testing.expectEqualStrings("nvme0n1", resolveDisk(p, "first-nonremovable").?.name);
    try std.testing.expect(resolveDisk(p, "nope") == null);
}

test "every gate: flag, confirm_erase present, disk resolves, not the live medium, confirm matches" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try fixture(arena, "uefi-nvme-blank.json");
    // All hold, with a path, a kernel name and a selector.
    try std.testing.expectEqualStrings("nvme0n1", check(p, true, ans("nvme0n1", "/dev/nvme0n1"), null).ok.name);
    try std.testing.expectEqualStrings("nvme0n1", check(p, true, ans("largest", "nvme0n1"), null).ok.name);
    try std.testing.expectEqualStrings("nvme0n1", check(p, true, ans("first-nonremovable", "/dev/nvme0n1"), null).ok.name);
    // A by-id link that resolves to the disk.
    try std.testing.expectEqualStrings("nvme0n1", check(p, true, ans("largest", "/dev/disk/by-id/nvme-X"), "/dev/nvme0n1").ok.name);
    // Each gate refuses.
    try std.testing.expectEqual(Gate.no_flag, check(p, false, ans("nvme0n1", "/dev/nvme0n1"), null).refused);
    try std.testing.expectEqual(Gate.no_confirm, check(p, true, ans("nvme0n1", null), null).refused);
    try std.testing.expectEqual(Gate.no_such_disk, check(p, true, ans("nope", "/dev/nope"), null).refused);
    try std.testing.expectEqual(Gate.confirm_mismatch, check(p, true, ans("nvme0n1", "/dev/sdc"), null).refused);
    // A selector is no confirmation by itself: confirm_erase must name the resolved disk.
    try std.testing.expectEqual(Gate.confirm_mismatch, check(p, true, ans("largest", "largest"), null).refused);
    try std.testing.expectEqual(Gate.confirm_mismatch, check(p, true, ans("largest", "/dev/disk/by-id/other"), "/dev/sdc").refused);
    // The live medium (sdb) is never a target.
    try std.testing.expectEqual(Gate.live_medium, check(p, true, ans("sdb", "/dev/sdb"), null).refused);
    // Selectors skip it as well.
    try std.testing.expect(!std.mem.eql(u8, resolveDisk(p, "largest").?.name, "sdb"));
}
