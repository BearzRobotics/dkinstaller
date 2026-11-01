//! Pure: turns probe data and answers into an ordered list of steps, or a
//! refusal. No I/O. Implements SPEC.md 5.2-5.6, 6.2 and 6.3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const probe_mod = @import("probe.zig");
const answers_mod = @import("answers.zig");
const files = @import("files.zig");

const Probe = probe_mod.Probe;
const Disk = probe_mod.Disk;
const Partition = probe_mod.Partition;
const Answers = answers_mod.Answers;

/// Where the target root is mounted while installing.
pub const target = "/run/dkrescue-install/target";
/// Where the system image lives on the live medium.
pub const rootfs_sfs = "/run/live/medium/live/rootfs.sfs";

const MiB: u64 = 1024 * 1024;

/// Programs the live disc must have (SPEC.md 6.3), checked before the first
/// screen. `cfdisk` is only needed for manual partitioning.
pub const required_programs = [_][]const u8{
    "lsblk",     "blkid",      "wipefs",   "sfdisk",  "mount",   "umount", "mkfs.ext4",
    "mkfs.vfat", "unsquashfs", "chpasswd", "useradd", "userdel", "visudo", "dklilo",
};

/// A command, run directly with no shell.
pub const Command = struct {
    argv: []const []const u8,
    /// Fed to the command's standard input.
    stdin: ?[]const u8 = null,
    /// Never shown or logged (passwords).
    secret_stdin: bool = false,
};

/// A file written with its full contents.
pub const FileWrite = struct {
    path: []const u8,
    contents: []const u8,
    mode: u32 = 0o644,
};

/// What a step does.
pub const Action = union(enum) {
    command: Command,
    write_file: FileWrite,
};

/// One thing the installer does. Everything done to the target is a Step.
pub const Step = struct {
    desc: []const u8,
    action: Action,
};

/// The ordered steps, and every program they run.
pub const Plan = struct {
    steps: []const Step,
    /// Unique program names used by the steps (SPEC.md 6.3).
    programs: []const []const u8,

    /// Prints the plan as `--dry-run` and the summary screen show it.
    pub fn writeDryRun(self: Plan, w: *Io.Writer) Io.Writer.Error!void {
        for (self.steps, 1..) |s, n| {
            try w.print("# {d}. {s}\n", .{ n, s.desc });
            switch (s.action) {
                .command => |c| {
                    for (c.argv, 0..) |arg, i| {
                        if (i > 0) try w.writeByte(' ');
                        try writeQuoted(w, arg);
                    }
                    if (c.stdin) |in| {
                        if (c.secret_stdin) {
                            try w.writeAll("   # stdin: (hidden)\n");
                        } else {
                            try w.writeAll(" <<'EOF'\n");
                            try w.writeAll(in);
                            if (in.len == 0 or in[in.len - 1] != '\n') try w.writeByte('\n');
                            try w.writeAll("EOF\n");
                        }
                    } else try w.writeByte('\n');
                },
                .write_file => |f| {
                    try w.print("write {s} (mode {o:0>4})\n", .{ f.path, f.mode });
                    var lines = std.mem.splitScalar(u8, f.contents, '\n');
                    while (lines.next()) |l| {
                        if (l.len == 0 and lines.peek() == null) break;
                        try w.print("    | {s}\n", .{l});
                    }
                },
            }
            try w.writeByte('\n');
        }
    }
};

fn writeQuoted(w: *Io.Writer, arg: []const u8) !void {
    var plain = arg.len > 0;
    for (arg) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_@%+=:,./-", c) != null)) plain = false;
    }
    if (plain) return w.writeAll(arg);
    try w.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// Either a plan, or the reason there isn't one.
pub const Result = union(enum) {
    plan: Plan,
    /// Why the installer refuses; shown to the user as is.
    refused: []const u8,
};

const Layout = struct {
    root_dev: []const u8,
    root_partuuid: []const u8,
    root_uuid: []const u8,
    esp_dev: ?[]const u8 = null,
    esp_uuid: ?[]const u8 = null,
    /// ESP will be (re)formatted, so it has no BOOTX64.EFI.
    esp_fresh: bool = false,
};

const Builder = struct {
    arena: Allocator,
    steps: std.ArrayList(Step) = .empty,
    refusal: ?[]const u8 = null,

    fn refuse(self: *Builder, comptime f: []const u8, args: anytype) error{Refused} {
        self.refusal = std.fmt.allocPrint(self.arena, f, args) catch "out of memory";
        return error.Refused;
    }

    fn cmd(self: *Builder, desc: []const u8, argv: []const []const u8) !void {
        try self.steps.append(self.arena, .{
            .desc = desc,
            .action = .{ .command = .{ .argv = try self.arena.dupe([]const u8, argv) } },
        });
    }

    fn cmdStdin(self: *Builder, desc: []const u8, argv: []const []const u8, stdin: []const u8, secret: bool) !void {
        try self.steps.append(self.arena, .{
            .desc = desc,
            .action = .{ .command = .{
                .argv = try self.arena.dupe([]const u8, argv),
                .stdin = stdin,
                .secret_stdin = secret,
            } },
        });
    }

    fn file(self: *Builder, desc: []const u8, path: []const u8, contents: []const u8, mode: u32) !void {
        try self.steps.append(self.arena, .{
            .desc = desc,
            .action = .{ .write_file = .{ .path = path, .contents = contents, .mode = mode } },
        });
    }

    fn fmt(self: *Builder, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(self.arena, f, args);
    }
};

fn pwText(pw: answers_mod.Password) []const u8 {
    return switch (pw) {
        .hash, .plain => |t| t,
    };
}

/// Hashes need `chpasswd -e`; typed passwords don't.
fn chpasswdArgv(pw: answers_mod.Password) []const []const u8 {
    return switch (pw) {
        .hash => &.{ "chpasswd", "-R", target, "-e" },
        .plain => &.{ "chpasswd", "-R", target },
    };
}

fn isEspType(t: ?[]const u8) bool {
    const s = t orelse return false;
    return std.ascii.eqlIgnoreCase(s, files.guid_esp) or std.ascii.eqlIgnoreCase(s, "0xef");
}

fn isBiosBootType(t: ?[]const u8) bool {
    const s = t orelse return false;
    return std.ascii.eqlIgnoreCase(s, files.guid_bios_boot);
}

/// Builds the plan for `answers` on the machine described by `p`.
/// `ids` supplies the UUIDs for filesystems and partitions that don't exist yet.
pub fn build(arena: Allocator, p: Probe, a: Answers, ids: files.Ids) Allocator.Error!Result {
    var b: Builder = .{ .arena = arena };
    if (buildSteps(&b, p, a, ids)) |_| {
        return .{ .plan = .{
            .steps = b.steps.items,
            .programs = try collectPrograms(arena, b.steps.items),
        } };
    } else |err| switch (err) {
        error.Refused => return .{ .refused = b.refusal.? },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn collectPrograms(arena: Allocator, steps: []const Step) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (steps) |s| {
        const c = switch (s.action) {
            .command => |c| c,
            else => continue,
        };
        const prog = std.fs.path.basename(c.argv[0]);
        var seen = false;
        for (list.items) |q| if (std.mem.eql(u8, q, prog)) {
            seen = true;
        };
        if (!seen) try list.append(arena, prog);
    }
    return list.items;
}

const BuildError = error{ Refused, OutOfMemory };

fn buildSteps(b: *Builder, p: Probe, a: Answers, ids: files.Ids) BuildError!void {
    const arena = b.arena;
    if (!p.is_live) return b.refuse("not running from the live disc", .{});
    const disk = p.findDisk(a.disk) orelse return b.refuse("disk {s} not found", .{a.disk});
    if (probe_mod.ineligible(p, disk, a.partitioning == .auto)) |why| {
        return b.refuse("{s} can't be used: {s}", .{ disk.path, why.text() });
    }
    const kernel = p.kernel orelse return b.refuse("no vmlinuz-* kernel found in the system image", .{});

    const layout: Layout = switch (a.partitioning) {
        .auto => try planAuto(b, disk, ids),
        .existing => try planExisting(b, p, disk, a, ids),
    };

    // 2. Mount
    try b.cmd("Create the mount point", &.{ "mkdir", "-p", target });
    try b.cmd("Mount the root filesystem", &.{ "mount", layout.root_dev, target });
    if (layout.esp_dev) |esp| {
        try b.cmd("Create /boot/efi", &.{ "mkdir", "-p", target ++ "/boot/efi" });
        try b.cmd("Mount the EFI System Partition", &.{ "mount", esp, target ++ "/boot/efi" });
    }

    // 3. Copy the system
    try b.cmd("Copy the system from the disc image", &.{ "unsquashfs", "-f", "-d", target, rootfs_sfs });

    // 4. fstab
    try b.file("Write fstab", target ++ "/etc/fstab", try files.fstab(arena, layout.root_uuid, layout.esp_uuid), 0o644);

    // 5. Identity
    try b.file("Set the hostname", target ++ "/etc/hostname", try files.hostnameFile(arena, a.hostname), 0o644);
    try b.file("Write hosts", target ++ "/etc/hosts", try files.hosts(arena, a.hostname), 0o644);
    try b.cmd("Set the timezone", &.{
        "ln",                                                  "-sf",
        try b.fmt("../usr/share/zoneinfo/{s}", .{a.timezone}), target ++ "/etc/localtime",
    });
    // OPEN (SPEC.md 5.6.5, 12.3): the console keymap is not written until
    // the file lfs-dinit reads it from is known.
    try b.cmd("Remove the machine id (first boot makes a new one)", &.{ "rm", "-f", target ++ "/etc/machine-id" });

    // 6. Users
    try b.cmdStdin("Set the root password", chpasswdArgv(a.root_pw), try b.fmt("root:{s}\n", .{pwText(a.root_pw)}), true);
    try b.cmd("Create the user", &.{ "useradd", "-R", target, "-m", "-G", "wheel,video,render", "-s", "/bin/bash", a.user });
    try b.cmdStdin("Set the user's password", chpasswdArgv(a.user_pw), try b.fmt("{s}:{s}\n", .{ a.user, pwText(a.user_pw) }), true);
    try b.cmd("Remove the live disc's user", &.{ "userdel", "-R", target, "-r", "rescue" });

    // 7. sudo
    const sudo_new = target ++ "/etc/sudoers.d/00-wheel.new";
    try b.file("Write the sudo policy", sudo_new, files.sudoers_wheel, 0o440);
    try b.cmd("Check the sudo policy", &.{ "visudo", "-c", "-f", sudo_new });
    try b.cmd("Install the sudo policy", &.{ "mv", "-f", sudo_new, target ++ "/etc/sudoers.d/00-wheel" });

    // 8. Bootloader
    try b.file("Write dklilo.conf", target ++ "/boot/dklilo.conf", try files.dkliloConf(arena, kernel, layout.root_partuuid), 0o644);
    switch (p.firmware) {
        .uefi => {
            const esp = layout.esp_dev.?;
            // dklilo takes the ESP as a mounted directory and finds the device itself.
            const esp_mnt = target ++ "/boot/efi";
            const has_boot = if (layout.esp_fresh) false else (espBootx64(p, disk, esp));
            if (p.efivars_rw) {
                try b.cmd("Install dklilo (UEFI boot entry)", &.{ "dklilo", "install-uefi", "--yes", esp_mnt });
                if (!has_boot) try b.cmd("Install dklilo as the removable-media loader", &.{ "dklilo", "install-uefi", "--yes", "--removable", esp_mnt });
            } else if (!has_boot) {
                try b.cmd("Install dklilo as the removable-media loader (efivars not writable)", &.{ "dklilo", "install-uefi", "--yes", "--removable", esp_mnt });
            } else {
                return b.refuse("efivars is not writable and the ESP already has \\EFI\\BOOT\\BOOTX64.EFI, which is never replaced: nothing to install", .{});
            }
        },
        .bios => try b.cmd("Install dklilo (BIOS)", &.{ "dklilo", "install-bios", "--yes", disk.path }),
    }
    try b.cmd("Check dklilo.conf", &.{ "dklilo", "check", target ++ "/boot/dklilo.conf" });

    // 9. Finish
    try b.cmd("Flush to disk", &.{"sync"});
    if (layout.esp_dev != null) try b.cmd("Unmount the EFI System Partition", &.{ "umount", target ++ "/boot/efi" });
    try b.cmd("Unmount the root filesystem", &.{ "umount", target });
}

fn espBootx64(_: Probe, disk: Disk, esp_dev: []const u8) bool {
    const part = disk.findPartition(esp_dev) orelse return true;
    return part.has_bootx64 orelse true;
}

fn planAuto(b: *Builder, disk: Disk, ids: files.Ids) BuildError!Layout {
    const arena = b.arena;
    const esp_dev = try files.partitionPath(arena, disk.name, 2);
    const root_dev = try files.partitionPath(arena, disk.name, 3);
    try b.cmd("Erase all signatures on the disk", &.{ "wipefs", "-a", disk.path });
    try b.cmdStdin("Write the partition table", &.{ "sfdisk", disk.path }, try files.sfdiskScript(arena, ids), false);
    try b.cmd("Format the EFI System Partition", &.{ "mkfs.vfat", "-F", "32", "-n", "ESP", "-i", ids.esp_vol_id, esp_dev });
    try b.cmd("Format the root filesystem", &.{ "mkfs.ext4", "-L", "dkrescue", "-U", ids.root_fs_uuid, root_dev });
    return .{
        .root_dev = root_dev,
        .root_partuuid = ids.root_partuuid,
        .root_uuid = ids.root_fs_uuid,
        .esp_dev = esp_dev,
        .esp_uuid = try files.volIdToUuid(arena, ids.esp_vol_id),
        .esp_fresh = true,
    };
}

fn planExisting(b: *Builder, p: Probe, disk: Disk, a: Answers, ids: files.Ids) BuildError!Layout {
    const arena = b.arena;
    const table = disk.table orelse return b.refuse("{s} has no partition table; use automatic partitioning or cfdisk first", .{disk.path});
    const gpt = std.mem.eql(u8, table, "gpt");

    const root = disk.findPartition(a.root.?) orelse return b.refuse("root partition {s} is not on {s}", .{ a.root.?, disk.path });
    if (p.rootfs_size) |rs| {
        const need = probe_mod.minRootSize(rs);
        if (root.size < need) return b.refuse("root partition {s} is {d} MiB; at least {d} MiB is needed", .{ root.path, root.size / MiB, need / MiB });
    }
    const root_partuuid = root.partuuid orelse return b.refuse("root partition {s} has no PARTUUID", .{root.path});

    var esp_part: ?Partition = null;
    if (a.esp) |name| {
        const e = disk.findPartition(name) orelse return b.refuse("ESP {s} is not on {s}", .{ name, disk.path });
        if (std.mem.eql(u8, e.path, root.path)) return b.refuse("root and ESP are the same partition", .{});
        esp_part = e;
    } else if (p.firmware == .uefi) {
        return b.refuse("a UEFI install needs an EFI System Partition", .{});
    }

    // BIOS on MBR: dklilo install-bios itself refuses if the gap before the
    // first partition can't hold stage 2 (SPEC.md 12.6: no read-only --check yet).

    var type_fixes: std.ArrayList(Step) = .empty;

    var esp_uuid: ?[]const u8 = null;
    var esp_dev: ?[]const u8 = null;
    var esp_fresh = false;
    if (esp_part) |e| {
        if (e.size < 100 * MiB) return b.refuse("ESP {s} is {d} MiB; at least 100 MiB is needed", .{ e.path, e.size / MiB });
        if (!isEspType(e.parttype)) {
            if (!a.set_esp_type) return b.refuse("{s} is not typed as an EFI System Partition (type {s}); set_esp_type = true fixes that", .{ e.path, e.parttype orelse "none" });
            try type_fixes.append(arena, .{
                .desc = "Set the partition type to EFI System",
                .action = .{ .command = .{ .argv = try arena.dupe([]const u8, &.{
                    "sfdisk", "--part-type", disk.path, try b.fmt("{d}", .{e.number}), if (gpt) files.guid_esp else "ef",
                }) } },
            });
        }
        esp_dev = e.path;
        if (a.format_esp) {
            esp_fresh = true;
            esp_uuid = try files.volIdToUuid(arena, ids.esp_vol_id);
        } else {
            const fs = e.fstype orelse "none";
            if (!std.mem.eql(u8, fs, "vfat")) return b.refuse("ESP {s} holds {s}, not FAT; format it or pick another partition", .{ e.path, fs });
            esp_uuid = e.uuid orelse return b.refuse("ESP {s} has no filesystem UUID", .{e.path});
        }
    }

    // BIOS boot partition (GPT + BIOS firmware only).
    if (p.firmware == .bios and gpt) {
        var found: ?Partition = null;
        for (disk.partitions) |q| if (isBiosBootType(q.parttype) and q.size >= MiB) {
            found = q;
            break;
        };
        if (found == null) {
            const name = a.bios_boot orelse return b.refuse("BIOS boot on a GPT disk needs a BIOS boot partition (1 MiB or more); none found", .{});
            const q = disk.findPartition(name) orelse return b.refuse("BIOS boot partition {s} is not on {s}", .{ name, disk.path });
            if (q.size < MiB) return b.refuse("BIOS boot partition {s} is smaller than 1 MiB", .{q.path});
            if (!a.set_bios_boot_type) return b.refuse("{s} is not typed as BIOS boot (type {s}); set_bios_boot_type = true fixes that", .{ q.path, q.parttype orelse "none" });
            try type_fixes.append(arena, .{
                .desc = "Set the partition type to BIOS boot",
                .action = .{ .command = .{ .argv = try arena.dupe([]const u8, &.{
                    "sfdisk", "--part-type", disk.path, try b.fmt("{d}", .{q.number}), files.guid_bios_boot,
                }) } },
            });
        }
    }

    try b.steps.appendSlice(arena, type_fixes.items);
    try b.cmd("Format the root filesystem", &.{ "mkfs.ext4", "-F", "-L", "dkrescue", "-U", ids.root_fs_uuid, root.path });
    if (esp_fresh) {
        try b.cmd("Format the EFI System Partition", &.{ "mkfs.vfat", "-F", "32", "-n", "ESP", "-i", ids.esp_vol_id, esp_dev.? });
    }

    return .{
        .root_dev = root.path,
        .root_partuuid = root_partuuid,
        .root_uuid = ids.root_fs_uuid,
        .esp_dev = esp_dev,
        .esp_uuid = esp_uuid,
        .esp_fresh = esp_fresh,
    };
}

// ---------------------------------------------------------------- tests

const test_ids: files.Ids = .{
    .root_fs_uuid = "11111111-2222-3333-4444-555555555555",
    .esp_vol_id = "ABCD1234",
    .root_partuuid = "aaaaaaaa-0000-0000-0000-000000000003",
    .esp_partuuid = "aaaaaaaa-0000-0000-0000-000000000002",
    .bios_partuuid = "aaaaaaaa-0000-0000-0000-000000000001",
};

fn loadFixture(arena: Allocator, name: []const u8) !Probe {
    const path = try std.fmt.allocPrint(arena, "tests/probes/{s}", .{name});
    const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    return probe_mod.fromFixture(arena, text);
}

fn testAnswers(disk: []const u8, part: answers_mod.Partitioning) Answers {
    return .{
        .disk = disk,
        .partitioning = part,
        .root_pw = .{ .hash = "$6$r$rootsecret" },
        .user = "dakota",
        .user_pw = .{ .hash = "$6$u$usersecret" },
    };
}

fn dryRun(arena: Allocator, plan: Plan) ![]u8 {
    var w: Io.Writer.Allocating = .init(arena);
    try plan.writeDryRun(&w.writer);
    return w.written();
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "auto layout on a blank UEFI NVMe machine" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    const r = try build(arena, p, testAnswers("nvme0n1", .auto), test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "wipefs -a /dev/nvme0n1\n"));
    try std.testing.expect(contains(out, "sfdisk /dev/nvme0n1 <<'EOF'"));
    try std.testing.expect(contains(out, "mkfs.vfat -F 32 -n ESP -i ABCD1234 /dev/nvme0n1p2"));
    try std.testing.expect(contains(out, "mkfs.ext4 -L dkrescue -U 11111111-2222-3333-4444-555555555555 /dev/nvme0n1p3"));
    try std.testing.expect(contains(out, "dklilo install-uefi --yes /run/dkrescue-install/target/boot/efi\n"));
    try std.testing.expect(contains(out, "dklilo install-uefi --yes --removable /run/dkrescue-install/target/boot/efi\n"));
    try std.testing.expect(!contains(out, "install-bios"));
    try std.testing.expect(contains(out, "root = PARTUUID=aaaaaaaa-0000-0000-0000-000000000003"));
    try std.testing.expect(contains(out, "UUID=ABCD-1234  /boot/efi"));
    // Passwords never appear.
    try std.testing.expect(!contains(out, "rootsecret"));
    try std.testing.expect(!contains(out, "usersecret"));
    // Programs recorded.
    var have_dklilo = false;
    for (r.plan.programs) |prog| if (std.mem.eql(u8, prog, "dklilo")) {
        have_dklilo = true;
    };
    try std.testing.expect(have_dklilo);
}

test "auto layout on BIOS installs the BIOS half" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "bios-sata-windows.json");
    const r = try build(arena, p, testAnswers("sda", .auto), test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "dklilo install-bios --yes /dev/sda\n"));
    try std.testing.expect(!contains(out, "install-uefi"));
    try std.testing.expect(contains(out, "mkfs.ext4 -L dkrescue -U 11111111-2222-3333-4444-555555555555 /dev/sda3"));
}

test "refuses the live disk, a mounted disk and a disk too small" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    const live = try build(arena, p, testAnswers("sdb", .auto), test_ids);
    try std.testing.expect(contains(live.refused, "holds the live medium"));
    const mounted = try build(arena, p, testAnswers("sdc", .auto), test_ids);
    try std.testing.expect(contains(mounted.refused, "mounted"));
    const small = try build(arena, p, testAnswers("sdd", .auto), test_ids);
    try std.testing.expect(contains(small.refused, "minimum size"));
    const none = try build(arena, p, testAnswers("nope", .auto), test_ids);
    try std.testing.expect(contains(none.refused, "not found"));
}

test "existing partitions: wrong ESP type needs consent, then adds a part-type step" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-sata-fdisk.json");

    var a = testAnswers("sda", .existing);
    a.root = "sda2";
    a.esp = "sda1";
    const refused = try build(arena, p, a, test_ids);
    try std.testing.expect(contains(refused.refused, "set_esp_type"));

    a.set_esp_type = true;
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "sfdisk --part-type /dev/sda 1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b"));
    // The unformatted ESP keeps its own UUID and gets no mkfs; root is forced.
    try std.testing.expect(contains(out, "mkfs.ext4 -F -L dkrescue"));
    try std.testing.expect(!contains(out, "mkfs.vfat"));
    try std.testing.expect(!contains(out, "wipefs"));
    try std.testing.expect(contains(out, "UUID=7E11-0A0A  /boot/efi"));
    // Its existing BOOTX64.EFI is never replaced: no --removable run.
    try std.testing.expect(!contains(out, "--removable"));
    // The part-type fix comes before the mkfs.
    try std.testing.expect(std.mem.indexOf(u8, out, "--part-type").? < std.mem.indexOf(u8, out, "mkfs.ext4").?);
}

test "existing partitions: root too small is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-sata-fdisk.json");
    var a = testAnswers("sda", .existing);
    a.root = "sda1";
    a.esp = "sda2";
    const r = try build(arena, p, a, test_ids);
    try std.testing.expect(contains(r.refused, "at least"));
}

test "existing partitions on BIOS/MBR installs without an ESP" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "bios-mbr-fdisk.json");
    var a = testAnswers("vda", .existing);
    a.root = "vda1";
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "dklilo install-bios --yes /dev/vda\n"));
    try std.testing.expect(!contains(out, "/boot/efi"));
}

test "UEFI without writable efivars falls back to removable-only" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    p.efivars_rw = false;
    const r = try build(arena, p, testAnswers("nvme0n1", .auto), test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "dklilo install-uefi --yes --removable /run/dkrescue-install/target/boot/efi"));
    try std.testing.expect(!contains(out, "install-uefi --yes /run"));
}
