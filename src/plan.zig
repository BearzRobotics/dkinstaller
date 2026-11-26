//! Pure: turns probe data and answers into an ordered list of steps, or a
//! refusal. No I/O. Implements SPEC.md 5.2-5.6, 6.2 and 6.3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const probe_mod = @import("probe.zig");
const answers_mod = @import("answers.zig");
const files = @import("files.zig");
const fs_mod = @import("fs.zig");
const bl_mod = @import("bootloader.zig");

const Probe = probe_mod.Probe;
const Disk = probe_mod.Disk;
const Partition = probe_mod.Partition;
const Answers = answers_mod.Answers;

/// The largest partition the installer will retype as BIOS boot (SPEC.md 5.3.3).
pub const bios_boot_max_size: u64 = 16 * 1024 * 1024;

/// Whether `q` may be retyped as the BIOS boot partition: its contents are overwritten, so only
/// a small partition with no filesystem qualifies.
pub fn biosBootCandidate(q: Partition) bool {
    return q.size >= 1024 * 1024 and q.size <= bios_boot_max_size and q.fstype == null;
}

/// Where the target root is mounted while installing.
pub const target = "/run/dkrescue-install/target";
/// The install log while installing (SPEC.md 6.4).
pub const log_path = "/run/dkrescue-install/install.log";
/// Where the log is copied to on the target before it is unmounted.
pub const target_log = target ++ "/var/log/dkrescue-install.log";
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
    /// Never shown or logged (WiFi passphrases).
    secret: bool = false,
};

/// What a step does.
pub const Action = union(enum) {
    command: Command,
    write_file: FileWrite,
    /// A shell in the target for configuring by hand (chroot, with /proc /sys
    /// /dev /run bound in). Interactive: unattended runs skip it.
    shell,
    /// Does nothing; only says something in the dry run and the log.
    note,
};

/// A step that runs only when the system looks a certain way at the time it
/// would run (the plan is made before the target exists). Empty: always runs.
pub const Condition = struct {
    /// Every one of these paths must exist.
    exists: []const []const u8 = &.{},
    /// At least one of these must exist (when the list is not empty).
    any_of: []const []const u8 = &.{},
    /// None of these may exist.
    none_of: []const []const u8 = &.{},

    pub fn isEmpty(self: Condition) bool {
        return self.exists.len == 0 and self.any_of.len == 0 and self.none_of.len == 0;
    }
};

/// One thing the installer does. Everything done to the target is a Step.
pub const Step = struct {
    desc: []const u8,
    action: Action,
    /// Skipped silently (only the log says so) unless this holds when it is reached.
    when: Condition = .{},
    /// A failure is a warning: the install goes on (the user is asked first
    /// when the screens run it) and the final screen and log report it.
    soft: bool = false,
};

/// The ordered steps, and every program they run.
pub const Plan = struct {
    steps: []const Step,
    /// Unique program names used by the steps (SPEC.md 6.3).
    programs: []const []const u8,
    /// What the install mounts at `target`, so the final screen can mount it
    /// again for a shell in the installed system.
    root_dev: []const u8 = "",
    esp_dev: ?[]const u8 = null,

    /// Prints the plan as `--dry-run` and the summary screen show it.
    pub fn writeDryRun(self: Plan, w: *Io.Writer) Io.Writer.Error!void {
        for (self.steps, 1..) |s, n| {
            try w.print("# {d}. {s}\n", .{ n, s.desc });
            if (!s.when.isEmpty()) {
                try w.writeAll("   # runs only if");
                var first = true;
                const parts = [_]struct { l: []const []const u8, how: []const u8 }{
                    .{ .l = s.when.exists, .how = "all of these exist" },
                    .{ .l = s.when.any_of, .how = "one of these exists" },
                    .{ .l = s.when.none_of, .how = "none of these exists" },
                };
                for (parts) |part| {
                    if (part.l.len == 0) continue;
                    try w.print("{s} {s}:", .{ if (first) "" else "; and", part.how });
                    for (part.l) |pth| try w.print(" {s}", .{pth});
                    first = false;
                }
                try w.writeAll("; skipped otherwise\n");
            }
            if (s.soft) try w.writeAll("   # failure here is a warning, the install goes on\n");
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
                .shell => try w.writeAll("open a shell in the new system (chroot " ++ target ++ ", interactive; skipped when unattended)\n"),
                .note => try w.writeAll("(nothing to run)\n"),
                .write_file => |f| {
                    try w.print("write {s} (mode {o:0>4})\n", .{ f.path, f.mode });
                    if (f.secret) {
                        try w.writeAll("    | (contents hidden)\n");
                        try w.writeByte('\n');
                        continue;
                    }
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

/// Writes `arg` shell-quoted, as the dry run and the log show it.
pub fn writeQuoted(w: *Io.Writer, arg: []const u8) !void {
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
    root_dev: []const u8 = "",
    esp_dev: ?[]const u8 = null,

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

/// Whether `useradd` would fail because the system already has `name`. The live user's name
/// is free: that account is removed first.
pub fn userTaken(p: Probe, name: []const u8) bool {
    if (std.mem.eql(u8, name, "root")) return true;
    if (std.mem.eql(u8, name, p.live_user)) return false;
    for (p.accounts) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Builds the plan for `answers` on the machine described by `p`.
/// `ids` supplies the UUIDs for filesystems and partitions that don't exist yet.
pub fn build(arena: Allocator, p: Probe, a: Answers, ids: files.Ids) Allocator.Error!Result {
    var b: Builder = .{ .arena = arena };
    if (buildSteps(&b, p, a, ids)) |_| {
        return .{ .plan = .{
            .steps = b.steps.items,
            .programs = try collectPrograms(arena, b.steps.items),
            .root_dev = b.root_dev,
            .esp_dev = b.esp_dev,
        } };
    } else |err| switch (err) {
        error.Refused => return .{ .refused = b.refusal.? },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn collectPrograms(arena: Allocator, steps: []const Step) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (steps) |s| {
        // A conditional step names its own program in its condition.
        if (!s.when.isEmpty()) continue;
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
    if (userTaken(p, a.user)) return b.refuse("the user name {s} is already taken by an account or group in the system", .{a.user});
    const kernel = p.kernel orelse return b.refuse("no vmlinuz-* kernel found in the system image", .{});

    // The root filesystem (SPEC.md 5.3.4): its tools are on the live disc and the
    // installed kernel can mount it; otherwise say why, before anything is written.
    const loader = a.bootloader;
    const fw: bl_mod.Firmware = if (p.firmware == .uefi) .uefi else .bios;
    switch (try bl_mod.availability(arena, loader, fw, p.tools, p.paths)) {
        .ok => {},
        .unusable => |why| return b.refuse("the boot loader {s} can't be used: {s}", .{ bl_mod.info(loader).name, why }),
    }
    const boot_check: fs_mod.BootCheck = .{ .readable = bl_mod.canReadRoot(loader, a.root_fs), .loader = bl_mod.info(loader).name };
    switch (try fs_mod.availability(arena, a.root_fs, p.tools, p.kernel_builtin, boot_check)) {
        .ok => {},
        .unusable => |why| return b.refuse("the root filesystem {s} can't be used: {s}", .{ fs_mod.info(a.root_fs).name, why }),
    }

    const layout: Layout = switch (a.partitioning) {
        .auto => try planAuto(b, disk, a.root_fs, ids),
        .existing => try planExisting(b, p, disk, a, ids),
    };

    b.root_dev = layout.root_dev;
    b.esp_dev = layout.esp_dev;
    // 2. Mount
    try b.cmd("Create the mount point", &.{ "mkdir", "-p", target });
    try b.cmd("Mount the root filesystem", &.{ "mount", layout.root_dev, target });
    // systemd-boot reads only the ESP, so the kernels live on it: it is /boot. The others
    // keep /boot on the root and mount the ESP at /boot/efi.
    const esp_at: []const u8 = if (loader == .@"systemd-boot") "/boot" else "/boot/efi";
    const esp_mnt: []const u8 = if (loader == .@"systemd-boot") target ++ "/boot" else target ++ "/boot/efi";
    if (layout.esp_dev) |esp| if (loader != .@"systemd-boot") {
        try b.cmd("Create /boot/efi", &.{ "mkdir", "-p", target ++ "/boot/efi" });
        try b.cmd("Mount the EFI System Partition", &.{ "mount", esp, target ++ "/boot/efi" });
    };

    // 3. Copy the system
    try b.cmd("Copy the system from the disc image", &.{ "unsquashfs", "-percentage", "-f", "-d", target, rootfs_sfs });
    if (loader == .@"systemd-boot") {
        // /boot came in on the root; move what is there onto the ESP, which then covers it. (A copy
        // straight to FAT would fail to set owners and modes, so the files are copied without them.)
        const esp = layout.esp_dev orelse return b.refuse("systemd-boot needs an EFI System Partition", .{});
        try b.cmd("Keep the kernel files aside", &.{ "sh", "-c", "mkdir -p " ++ boot_stash ++ " && cp -a " ++ target ++ "/boot/. " ++ boot_stash ++ "/ && rm -rf " ++ target ++ "/boot/*" });
        try b.cmd("Mount the EFI System Partition as /boot", &.{ "mount", "-o", "umask=0077", esp, target ++ "/boot" });
        try b.cmd("Put the kernel files on the EFI System Partition", &.{ "sh", "-c", "cp -r --no-preserve=all " ++ boot_stash ++ "/. " ++ target ++ "/boot/ && rm -rf " ++ boot_stash });
    }

    // 4. fstab
    try b.file("Write fstab", target ++ "/etc/fstab", try files.fstabAt(arena, a.root_fs, layout.root_uuid, layout.esp_uuid, esp_at), 0o644);

    // 5. Identity
    try b.file("Set the hostname", target ++ "/etc/hostname", try files.hostnameFile(arena, a.hostname), 0o644);
    try b.file("Write hosts", target ++ "/etc/hosts", try files.hosts(arena, a.hostname, a.domain), 0o644);
    try b.cmd("Set the timezone", &.{
        "ln",                                                  "-sf",
        try b.fmt("../usr/share/zoneinfo/{s}", .{a.timezone}), target ++ "/etc/localtime",
    });
    if (a.keymap) |km| {
        try b.file("Write the console keymap service", target ++ "/etc/dinit.d/keymap", try files.keymapService(arena, km), 0o644);
        try b.cmd("Start the keymap service at boot", &.{ "ln", "-sf", "../keymap", target ++ "/etc/dinit.d/boot.d/keymap" });
    }
    try b.cmd("Remove the machine id (first boot makes a new one)", &.{ "rm", "-f", target ++ "/etc/machine-id" });

    // 6. Users
    try b.cmdStdin("Set the root password", chpasswdArgv(a.root_pw), try b.fmt("root:{s}\n", .{pwText(a.root_pw)}), true);
    // Before `useradd`: the chosen name may be the live user's.
    if (p.live_user.len > 0) try b.cmd("Remove the live disc's user", &.{ "userdel", "-R", target, "-r", p.live_user });
    try b.cmd("Create the user", &.{ "useradd", "-R", target, "-m", "-G", "wheel,video,render", "-s", "/bin/bash", a.user });
    try b.cmdStdin("Set the user's password", chpasswdArgv(a.user_pw), try b.fmt("{s}:{s}\n", .{ a.user, pwText(a.user_pw) }), true);
    // The image logs the live user in on tty1 by itself (`agetty --autologin <user>` in /etc/dinit.d/tty1). In the new
    // system that user is gone (or is the chosen user, who now has a password): a plain login prompt instead.
    if (p.live_user.len > 0) try b.steps.append(arena, .{
        .desc = "Turn off the live disc's automatic login on tty1",
        .action = .{ .command = .{ .argv = try arena.dupe([]const u8, &.{ "sed", "-i", try b.fmt("s| --autologin {s} | |", .{p.live_user}), target ++ "/etc/dinit.d/tty1" }) } },
        .when = .{ .exists = &.{target ++ "/etc/dinit.d/tty1"} },
        .soft = true,
    });

    // 7. sudo
    const sudo_new = target ++ "/etc/sudoers.d/00-wheel.new";
    try b.file("Write the sudo policy", sudo_new, files.sudoers_wheel, 0o440);
    try b.cmd("Check the sudo policy", &.{ "visudo", "-c", "-f", sudo_new });
    try b.cmd("Install the sudo policy", &.{ "mv", "-f", sudo_new, target ++ "/etc/sudoers.d/00-wheel" });

    // 7b. Extra packages from a repository medium
    try planRepoPackages(b, p, a);

    // 7c. Services, SSH, NTP, firewall
    try planConfig(b, p, a);
    try planNetwork(b, p, a, ids);
    for (a.post) |cmd| {
        try b.steps.append(arena, .{
            .desc = try b.fmt("Post-install command: {s}", .{cmd}),
            .action = .{ .command = .{ .argv = try arena.dupe([]const u8, &.{ "chroot", target, "/bin/sh", "-c", cmd }) } },
            .soft = true,
        });
    }

    // 8. Bootloader
    switch (loader) {
        .dklilo => try planDklilo(b, p, a, layout, disk, kernel),
        .grub => try planGrub(b, p, layout, disk),
        .@"systemd-boot" => try planSystemdBoot(b, p, layout, disk),
    }

    // 9. Finish
    try b.cmd("Copy the install log to the new system", &.{ "cp", log_path, target_log });
    try planSelinux(b, a, layout.esp_dev != null, esp_at);
    try b.cmd("Flush to disk", &.{"sync"});
    if (layout.esp_dev != null) try b.cmd("Unmount the EFI System Partition", &.{ "umount", esp_mnt });
    try b.cmd("Unmount the root filesystem", &.{ "umount", target });
}

/// Where the kernel files wait while the ESP is mounted over /boot (systemd-boot).
const boot_stash = "/run/dkrescue-install/boot-stash";

/// What the boot loader installers that run in the new system need: /dev, /proc and /sys
/// (the last carries the EFI variables).
fn bindMounts(b: *Builder) !void {
    try b.cmd("Prepare the new system's /dev, /proc and /sys", &.{ "mkdir", "-p", target ++ "/dev", target ++ "/proc", target ++ "/sys" });
    try b.cmd("Bind /dev into the new system", &.{ "mount", "--bind", "/dev", target ++ "/dev" });
    try b.cmd("Mount /proc in the new system", &.{ "mount", "-t", "proc", "proc", target ++ "/proc" });
    try b.cmd("Bind /sys into the new system", &.{ "mount", "--rbind", "/sys", target ++ "/sys" });
}

fn unbindMounts(b: *Builder) !void {
    try b.cmd("Unmount /sys from the new system", &.{ "umount", "-R", target ++ "/sys" });
    try b.cmd("Unmount /proc from the new system", &.{ "umount", target ++ "/proc" });
    try b.cmd("Unmount /dev from the new system", &.{ "umount", target ++ "/dev" });
}

fn planDklilo(b: *Builder, p: Probe, a: Answers, layout: Layout, disk: Disk, kernel: []const u8) BuildError!void {
    const arena = b.arena;
    _ = a;
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
                return b.refuse("efivars is not writable and the ESP already has \\EFI\\BOOT\\BOOTX64.EFI (or could not be checked for it), which is never replaced: nothing to install", .{});
            }
        },
        .bios => try b.cmd("Install dklilo (BIOS)", &.{ "dklilo", "install-bios", "--yes", disk.path }),
    }
    try b.cmd("Check dklilo.conf", &.{ "dklilo", "check", target ++ "/boot/dklilo.conf" });
}

/// GRUB, installed from inside the new system. There is no initramfs, so the kernel is given
/// root=PARTUUID (the kernel cannot resolve root=UUID itself).
fn planGrub(b: *Builder, p: Probe, layout: Layout, disk: Disk) BuildError!void {
    const arena = b.arena;
    try b.cmd("GRUB: make /etc/default/grub.d", &.{ "mkdir", "-p", target ++ "/etc/default/grub.d" });
    try b.file("GRUB: boot by partition id (the kernel has no initramfs to resolve root=UUID)", target ++ "/etc/default/grub.d/50-dkrescue-install.cfg", files.grub_dropin, 0o644);
    try bindMounts(b);
    switch (p.firmware) {
        .uefi => {
            const esp = layout.esp_dev.?;
            const has_boot = if (layout.esp_fresh) false else (espBootx64(p, disk, esp));
            const efi: []const []const u8 = &.{ "chroot", target, "grub-install", "--target=x86_64-efi", "--efi-directory=/boot/efi", "--bootloader-id=FenrirOS" };
            const removable: []const []const u8 = &.{ "chroot", target, "grub-install", "--target=x86_64-efi", "--efi-directory=/boot/efi", "--removable" };
            if (p.efivars_rw) {
                try b.cmd("Install GRUB (UEFI boot entry)", efi);
                if (!has_boot) try b.cmd("Install GRUB as the removable-media loader", removable);
            } else if (!has_boot) {
                try b.cmd("Install GRUB as the removable-media loader (efivars not writable)", removable);
            } else {
                return b.refuse("efivars is not writable and the ESP already has \\EFI\\BOOT\\BOOTX64.EFI (or could not be checked for it), which is never replaced: nothing to install", .{});
            }
        },
        .bios => try b.cmd("Install GRUB (BIOS)", &.{ "chroot", target, "grub-install", "--target=i386-pc", "--recheck", disk.path }),
    }
    try b.cmd("Write grub.cfg", &.{ "chroot", target, "update-grub" });
    try unbindMounts(b);
    _ = arena;
}

/// `sh -c` script: runs the command after `$1 $2` and puts the file `$1`, if there was one, back
/// as it was (saved at `$2`), whether or not the command worked.
pub const keep_file =
    \\f=$1 s=$2; shift 2
    \\had=; if [ -f "$f" ]; then cp "$f" "$s" || exit 1; had=1; fi
    \\"$@"; r=$?
    \\if [ -n "$had" ]; then cp "$s" "$f" || { echo "could not restore $f; it is saved at $s" >&2; exit 1; }; fi
    \\exit $r
;
const bootx64_saved = "/run/dkrescue-install/BOOTX64.EFI.kept";

/// systemd-boot, installed from inside the new system with the ESP as /boot.
fn planSystemdBoot(b: *Builder, p: Probe, layout: Layout, disk: Disk) BuildError!void {
    const arena = b.arena;
    try b.file("systemd-boot: boot by partition id (the kernel has no initramfs to resolve root=UUID)", target ++ "/etc/default/systemd-boot", try files.systemdBootDefaults(arena, layout.root_partuuid), 0o644);
    // A kept ESP may already have another system's BOOTX64.EFI, and `bootctl install` writes there.
    const keep = !layout.esp_fresh and espBootx64(p, disk, layout.esp_dev.?);
    if (keep and !p.efivars_rw) return b.refuse("efivars is not writable and the ESP already has \\EFI\\BOOT\\BOOTX64.EFI (or could not be checked for it), which is never replaced: nothing to install", .{});
    try bindMounts(b);
    const install: []const []const u8 = if (p.efivars_rw)
        &.{ "chroot", target, "bootctl", "install", "--esp-path=/boot" }
    else
        &.{ "chroot", target, "bootctl", "install", "--esp-path=/boot", "--no-variables" };
    var argv: std.ArrayList([]const u8) = .empty;
    if (keep) try argv.appendSlice(arena, &.{ "sh", "-c", keep_file, "sh", target ++ "/boot/EFI/BOOT/BOOTX64.EFI", bootx64_saved });
    try argv.appendSlice(arena, install);
    try b.cmd(if (!p.efivars_rw)
        "Install systemd-boot (efivars not writable: no boot entry)"
    else if (keep)
        "Install systemd-boot, keeping the ESP's own BOOTX64.EFI"
    else
        "Install systemd-boot", argv.items);
    try b.cmd("Write the boot entries", &.{ "chroot", target, "gen-systemd-boot" });
    try unbindMounts(b);
}

/// Where `setfiles` is looked for on the live system (which is what the new
/// system was copied from, so the target has it exactly when the live one does).
pub const setfiles_paths = [_][]const u8{ "/usr/sbin/setfiles", "/sbin/setfiles", "/usr/bin/setfiles", "/bin/setfiles" };
pub const selinux_config = target ++ "/etc/selinux/config";
pub const selinux_file_contexts = target ++ "/etc/selinux/targeted/contexts/files/file_contexts";

/// SELinux: label the new root when the policy is installed in it. Never
/// fatal: the system boots permissive (SELINUX=permissive in the target's
/// /etc/selinux/config), so a failure is a warning. The kernel command line
/// is left alone: SELinux is the kernel's default security module and
/// /etc/selinux/config decides the mode.
fn planSelinux(b: *Builder, a: Answers, esp_mounted: bool, esp_at: []const u8) !void {
    if (a.selinux) |mode| {
        try b.steps.append(b.arena, .{
            .desc = try b.fmt("SELinux mode: {s} (/etc/selinux/config)", .{@tagName(mode)}),
            .action = .{ .command = .{ .argv = try b.arena.dupe([]const u8, &.{ "sed", "-i", try b.fmt("s/^SELINUX=.*/SELINUX={s}/", .{@tagName(mode)}), selinux_config }) } },
            .when = .{ .exists = &.{selinux_config} },
            .soft = true,
        });
        // Nothing to label when SELinux is off.
        if (mode == .disabled) return;
    }
    const policy = [_][]const u8{ selinux_config, selinux_file_contexts };
    // Mount points of the target's own pseudo filesystems and the FAT ESP
    // (no xattrs there) are not labelled.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(b.arena, &.{ "setfiles", "-F", "-r", target });
    const skip = [_][]const u8{ "/proc", "/sys", "/dev", "/run", "/tmp" };
    for (skip) |d| try argv.appendSlice(b.arena, &.{ "-e", try b.fmt("{s}{s}", .{ target, d }) });
    if (esp_mounted) try argv.appendSlice(b.arena, &.{ "-e", try b.fmt("{s}{s}", .{ target, esp_at }) });
    try argv.appendSlice(b.arena, &.{ selinux_file_contexts, target });
    try b.steps.append(b.arena, .{
        .desc = "SELinux: label the new system (only when its policy is installed)",
        .action = .{ .command = .{ .argv = argv.items } },
        .when = .{ .exists = &policy, .any_of = &setfiles_paths },
        .soft = true,
    });
    // Policy present but no setfiles anywhere: the first boot relabels.
    try b.steps.append(b.arena, .{
        .desc = "SELinux: no setfiles here, ask for a relabel at the first boot",
        .action = .{ .command = .{ .argv = try b.arena.dupe([]const u8, &.{ "touch", target ++ "/.autorelabel" }) } },
        .when = .{ .exists = &policy, .none_of = &setfiles_paths },
        .soft = true,
    });
}

const SvcChange = struct { name: []const u8, on: bool };

fn setSvc(b: *Builder, list: *std.ArrayList(SvcChange), name: []const u8, on: bool) !void {
    for (list.items) |*c| if (std.mem.eql(u8, c.name, name)) {
        c.on = on;
        return;
    };
    try list.append(b.arena, .{ .name = name, .on = on });
}

/// The sshd drop-in the installer writes (sshd_config is not rewritten; its
/// `Include /etc/ssh/sshd_config.d/*.conf` reads this first, and sshd keeps
/// the first value it sees).
pub fn sshdDropIn(arena: Allocator, ssh: answers_mod.Ssh) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\# Written by the installer.
        \\PermitRootLogin {s}
        \\PasswordAuthentication {s}
        \\
    , .{ @tagName(ssh.root_login), if (ssh.password_auth) "yes" else "no" });
}

fn isNetService(name: []const u8) bool {
    for (probe_mod.net_service_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// dinit services (the Services, NTP and firewall screens, SSH's enable box)
/// and the SSH configuration. A service is enabled by the link the image step
/// makes (dkbuild image.zig), disabled by removing it.
fn planConfig(b: *Builder, p: Probe, a: Answers) BuildError!void {
    const arena = b.arena;
    var changes: std.ArrayList(SvcChange) = .empty;
    const net_mode: ?answers_mod.NetMode = if (a.network) |n| n.mode else null;
    // Manual: the network services are off. Manual-shell: the user's session
    // decides, the installer leaves them alone.
    if (net_mode == .manual) for (probe_mod.net_service_names) |n| {
        if (probe_mod.findService(p.services, n) != null) try setSvc(b, &changes, n, false);
    };
    for (a.services_enable) |n| if (net_mode != .@"manual-shell" or !isNetService(n)) try setSvc(b, &changes, n, true);
    for (a.services_disable) |n| if (net_mode != .@"manual-shell" or !isNetService(n)) try setSvc(b, &changes, n, false);
    if (a.firewall) |on| {
        if (probe_mod.findService(p.services, "firewalld") == null) return b.refuse("firewall was chosen but the image has no firewalld service", .{});
        try setSvc(b, &changes, "firewalld", on);
    }
    if (a.ntp) |on| {
        const svc = probe_mod.ntpService(p.services) orelse return b.refuse("NTP was chosen but the image has no NTP service (chronyd, ntpd, openntpd, ntpsec)", .{});
        try setSvc(b, &changes, svc.name, on);
    }
    var ssh_on = if (probe_mod.findService(p.services, "sshd")) |sv| sv.enabled else false;
    if (a.ssh) |ssh| {
        if (ssh.enable) |on| {
            if (probe_mod.findService(p.services, "sshd") == null) return b.refuse("SSH was chosen but the image has no sshd service", .{});
            try setSvc(b, &changes, "sshd", on);
            ssh_on = on;
        }
        if (ssh.authorized_key) |k| if (!answers_mod.validPubKey(k)) return b.refuse("the authorized key is not an OpenSSH public key line", .{});
    }

    var boot_d = false;
    for (changes.items) |c| {
        const svc = probe_mod.findService(p.services, c.name) orelse return b.refuse("no such service in the image: {s}", .{c.name});
        if (!c.on and svc.core) return b.refuse("{s} is needed to boot and can't be switched off", .{c.name});
        if (c.on == svc.enabled) continue;
        if (c.on) if (svc.missing_dep) |dep| return b.refuse("{s} can't be enabled: it needs {s}, which the image does not have (dinit would stop at boot)", .{ c.name, dep });
        const link = try b.fmt("{s}/etc/dinit.d/boot.d/{s}", .{ target, c.name });
        if (c.on) {
            if (!boot_d) try b.cmd("Create /etc/dinit.d/boot.d", &.{ "mkdir", "-p", target ++ "/etc/dinit.d/boot.d" });
            boot_d = true;
            try b.cmd(try b.fmt("Enable the {s} service at boot", .{c.name}), &.{ "ln", "-sfn", try svc.linkTarget(arena), link });
        } else {
            try b.cmd(try b.fmt("Disable the {s} service at boot", .{c.name}), &.{ "rm", "-f", link });
        }
    }

    const ssh = a.ssh orelse return;
    const have_key = ssh.authorized_key != null or ssh.generate_key;
    if (!ssh.password_auth and ssh_on and !have_key and !ssh.allow_lockout) {
        return b.refuse("sshd would allow only keys and no key is set up: nobody could log in over ssh. Give a key, allow passwords, or confirm the lockout", .{});
    }
    try b.file("Write the sshd drop-in", target ++ "/etc/ssh/sshd_config.d/10-dkinstall.conf", try sshdDropIn(arena, ssh), 0o644);
    // The image's sshd_config may not read the drop-in directory: add the line (once).
    try b.cmd("Make sshd_config read /etc/ssh/sshd_config.d (if it does not already)", &.{
        "sh", "-c", "grep -q '^Include /etc/ssh/sshd_config.d/' \"$1\" || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' \"$1\"", "sh", target ++ "/etc/ssh/sshd_config",
    });
    if (ssh_on) try b.cmd("Generate the ssh host keys", &.{ "ssh-keygen", "-A", "-f", target });
    if (have_key) {
        const home = try b.fmt("{s}/home/{s}", .{ target, a.user });
        const dir = try b.fmt("{s}/.ssh", .{home});
        const ak = try b.fmt("{s}/authorized_keys", .{dir});
        try b.cmd("Create the user's .ssh directory", &.{ "mkdir", "-p", "-m", "700", dir });
        if (ssh.authorized_key) |k| try b.file("Write the user's authorized_keys", ak, try b.fmt("{s}\n", .{std.mem.trim(u8, k, " \t")}), 0o600);
        if (ssh.generate_key) {
            const key = try b.fmt("{s}/id_ed25519", .{dir});
            try b.cmd("Generate an ed25519 key pair for the user (the fingerprint is shown)", &.{ "ssh-keygen", "-t", "ed25519", "-N", "", "-C", try b.fmt("{s}@{s}", .{ a.user, a.hostname }), "-f", key });
            if (ssh.authorized_key != null) {
                try b.cmd("Authorize the generated key too", &.{ "sh", "-c", "cat \"$1\" >> \"$2\"", "sh", try b.fmt("{s}.pub", .{key}), ak });
            } else {
                try b.cmd("Authorize the generated key", &.{ "cp", try b.fmt("{s}.pub", .{key}), ak });
                try b.cmd("Restrict authorized_keys", &.{ "chmod", "600", ak });
            }
        }
        try b.cmd("Give the .ssh directory to the user", &.{ "chroot", target, "chown", "-R", try b.fmt("{s}:", .{a.user}), try b.fmt("/home/{s}/.ssh", .{a.user}) });
    }
}

fn sanitize(arena: Allocator, name: []const u8) ![]u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*c| if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_' and c.* != '.') {
        c.* = '_';
    };
    return out;
}

fn uuidFor(b: *Builder, ids: files.Ids, name: []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(ids.root_fs_uuid);
    h.update(name);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return files.uuidFromBytes(b.arena, digest[0..16]);
}

fn joinSemi(b: *Builder, list: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |x| {
        try out.appendSlice(b.arena, x);
        try out.append(b.arena, ';');
    }
    return out.items;
}

/// A NetworkManager keyfile for one wired interface.
fn nmEthernet(b: *Builder, ids: files.Ids, ifc: answers_mod.Iface, net: answers_mod.Network) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(b.arena, try b.fmt("[connection]\nid=dk-{s}\nuuid={s}\ntype=ethernet\ninterface-name={s}\n", .{ ifc.name, try uuidFor(b, ids, ifc.name), ifc.name }));
    if (ifc.kind == .disabled) try o.appendSlice(b.arena, "autoconnect=false\n");
    try o.appendSlice(b.arena, "\n[ethernet]\n");
    var v4: std.ArrayList([]const u8) = .empty;
    var v6: std.ArrayList([]const u8) = .empty;
    for (net.dns) |d| {
        if (answers_mod.isV6(d)) try v6.append(b.arena, d) else try v4.append(b.arena, d);
    }
    const addr = ifc.address;
    for ([_]bool{ false, true }) |six| {
        try o.appendSlice(b.arena, if (six) "\n[ipv6]\n" else "\n[ipv4]\n");
        const dns = if (six) v6.items else v4.items;
        switch (ifc.kind) {
            .disabled => try o.appendSlice(b.arena, if (six) "method=ignore\n" else "method=disabled\n"),
            .dhcp => try o.appendSlice(b.arena, "method=auto\n"),
            .static => {
                if (addr != null and answers_mod.isV6(addr.?) == six) {
                    try o.appendSlice(b.arena, try b.fmt("method=manual\naddress1={s}{s}{s}\n", .{ addr.?, if (ifc.gateway != null) "," else "", ifc.gateway orelse "" }));
                } else try o.appendSlice(b.arena, if (six) "method=auto\n" else "method=disabled\n");
            },
        }
        if (ifc.kind != .disabled and dns.len > 0) try o.appendSlice(b.arena, try b.fmt("dns={s}\n", .{try joinSemi(b, dns)}));
        if (ifc.kind != .disabled and net.search != null) try o.appendSlice(b.arena, try b.fmt("dns-search={s};\n", .{net.search.?}));
    }
    return o.items;
}

fn nmWifi(b: *Builder, ids: files.Ids, wf: answers_mod.Wifi) ![]u8 {
    return b.fmt(
        \\[connection]
        \\id={s}
        \\uuid={s}
        \\type=wifi
        \\
        \\[wifi]
        \\mode=infrastructure
        \\ssid={s}
        \\{s}
        \\[wifi-security]
        \\key-mgmt=wpa-psk
        \\psk={s}
        \\
        \\[ipv4]
        \\method=auto
        \\
        \\[ipv6]
        \\method=auto
        \\
    , .{ wf.ssid, try uuidFor(b, ids, wf.ssid), wf.ssid, if (wf.hidden) "hidden=true\n" else "", wf.psk });
}

/// dhcpcd.conf lines for the interfaces (static, disabled) and DNS.
fn dhcpcdConf(b: *Builder, net: answers_mod.Network) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(b.arena, "\n# Added by the installer.\n");
    for (net.ifaces) |ifc| {
        switch (ifc.kind) {
            .dhcp => {
                if (net.dns.len == 0 and net.search == null) continue;
                try o.appendSlice(b.arena, try b.fmt("interface {s}\n", .{ifc.name}));
            },
            .disabled => try o.appendSlice(b.arena, try b.fmt("interface {s}\nnoipv4\nnoipv6\n", .{ifc.name})),
            .static => {
                const a = ifc.address.?;
                try o.appendSlice(b.arena, try b.fmt("interface {s}\n", .{ifc.name}));
                if (answers_mod.isV6(a)) {
                    try o.appendSlice(b.arena, try b.fmt("static ip6_address={s}\n", .{a}));
                    if (ifc.gateway) |g| try o.appendSlice(b.arena, try b.fmt("# gateway {s} comes from router advertisements; set it by hand if needed\n", .{g}));
                } else {
                    try o.appendSlice(b.arena, try b.fmt("static ip_address={s}\n", .{a}));
                    if (ifc.gateway) |g| try o.appendSlice(b.arena, try b.fmt("static routers={s}\n", .{g}));
                }
            },
        }
        if (ifc.kind != .disabled) {
            if (net.dns.len > 0) try o.appendSlice(b.arena, try b.fmt("static domain_name_servers={s}\n", .{try std.mem.join(b.arena, " ", net.dns)}));
            if (net.search) |sd| try o.appendSlice(b.arena, try b.fmt("static domain_search={s}\n", .{sd}));
        }
    }
    return o.items;
}

/// `sh -c` script that appends standard input to the file `$1` and prints nothing.
pub const append_private = "umask 077 && cat >> \"$1\"";

/// Network configuration (the network screens). The stack present in the
/// image decides the file format: NetworkManager keyfiles, or dhcpcd.conf and
/// wpa_supplicant.conf. Nothing is written for "as the image has it".
fn planNetwork(b: *Builder, p: Probe, a: Answers, ids: files.Ids) BuildError!void {
    const net = a.network orelse return;
    const arena = b.arena;
    switch (net.mode) {
        .manual => {
            try b.steps.append(arena, .{ .desc = "Network: left unconfigured; the network services are disabled (set it up after the first boot)", .action = .note });
            return;
        },
        .@"manual-shell" => {
            try b.steps.append(arena, .{ .desc = "Network: configure by hand now", .action = .shell });
            return;
        },
        else => {},
    }
    if (p.net_stack == .none) return b.refuse("the image has no network stack (NetworkManager or dhcpcd) to configure", .{});
    const conns = target ++ "/etc/NetworkManager/system-connections";
    if (net.mode == .copy) {
        if (p.net_stack != .networkmanager) return b.refuse("copying the live connection needs NetworkManager in the image", .{});
        const name = net.copy orelse return b.refuse("no connection chosen to copy", .{});
        var found = false;
        for (p.live_connections) |c| if (std.mem.eql(u8, c, name)) {
            found = true;
        };
        if (!found) return b.refuse("the live system has no NetworkManager connection {s}", .{name});
        try b.cmd("Create the NetworkManager connections directory", &.{ "mkdir", "-p", "-m", "700", conns });
        try b.cmd("Copy the live session's network connection", &.{ "cp", "-p", try b.fmt("{s}/{s}", .{ probe_mod.nm_connections_dir, name }), conns ++ "/" });
        return;
    }
    for (net.ifaces) |ifc| {
        if (ifc.kind == .static and (ifc.address == null)) return b.refuse("static interface {s} has no address", .{ifc.name});
    }
    if (net.dns.len > 0 and net.ifaces.len == 0) return b.refuse("DNS servers need an interface to apply to", .{});
    switch (p.net_stack) {
        .networkmanager => {
            var made = false;
            for (net.ifaces) |ifc| {
                if (ifc.kind == .dhcp and net.dns.len == 0 and net.search == null) continue;
                if (!made) try b.cmd("Create the NetworkManager connections directory", &.{ "mkdir", "-p", "-m", "700", conns });
                made = true;
                try b.file(try b.fmt("NetworkManager connection for {s} ({s})", .{ ifc.name, @tagName(ifc.kind) }), try b.fmt("{s}/dk-{s}.nmconnection", .{ conns, ifc.name }), try nmEthernet(b, ids, ifc, net), 0o600);
            }
            if (net.wifi) |wf| {
                if (!made) try b.cmd("Create the NetworkManager connections directory", &.{ "mkdir", "-p", "-m", "700", conns });
                try b.steps.append(arena, .{ .desc = try b.fmt("NetworkManager WiFi connection for {s}", .{wf.ssid}), .action = .{ .write_file = .{
                    .path = try b.fmt("{s}/wifi-{s}.nmconnection", .{ conns, try sanitize(arena, wf.ssid) }),
                    .contents = try nmWifi(b, ids, wf),
                    .mode = 0o600,
                    .secret = true,
                } } });
            }
        },
        .dhcpcd => {
            const conf = try dhcpcdConf(b, net);
            if (std.mem.indexOf(u8, conf, "interface ") != null) {
                try b.cmdStdin("Append the interface settings to dhcpcd.conf", &.{ "tee", "-a", target ++ "/etc/dhcpcd.conf" }, conf, false);
            }
            if (net.wifi) |wf| {
                const wconf = try b.fmt("\nnetwork={{\n    ssid=\"{s}\"\n    psk=\"{s}\"\n{s}}}\n", .{ wf.ssid, wf.psk, if (wf.hidden) "    scan_ssid=1\n" else "" });
                try b.cmd("Create /etc/wpa_supplicant", &.{ "mkdir", "-p", target ++ "/etc/wpa_supplicant" });
                // Not `tee`: it copies its input to its output, which is logged and shown. The umask keeps a
                // new file private from the moment it exists.
                try b.cmdStdin("Add the WiFi network to wpa_supplicant.conf (passphrase hidden)", &.{ "sh", "-c", append_private, "sh", target ++ "/etc/wpa_supplicant/wpa_supplicant.conf" }, wconf, true);
                try b.cmd("Restrict wpa_supplicant.conf", &.{ "chmod", "600", target ++ "/etc/wpa_supplicant/wpa_supplicant.conf" });
            }
        },
        .none => unreachable,
    }
}

/// Extra packages from the repository medium: `apk --root` with only that
/// repository, offline. Failure is a warning (the base system is complete).
fn planRepoPackages(b: *Builder, p: Probe, a: Answers) BuildError!void {
    if (a.packages.len == 0) return;
    const repo = p.repo orelse return b.refuse("packages were chosen but no repository medium was found (--repo PATH, or mount one at /mnt/cdrom)", .{});
    for (a.packages) |name| {
        if (!answers_mod.validPackageName(name)) return b.refuse("invalid package name: {s}", .{name});
    }
    const arena = b.arena;
    const keys_dir = target ++ "/etc/apk/keys";
    if (repo.keys.len > 0) {
        try b.cmd("Create the apk key directory", &.{ "mkdir", "-p", keys_dir });
        var cp: std.ArrayList([]const u8) = .empty;
        try cp.append(arena, "cp");
        try cp.appendSlice(arena, repo.keys);
        try cp.append(arena, keys_dir);
        try b.cmd("Trust the repository's signing key", cp.items);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "apk", "--root", target, "--no-network", "--no-progress", "--repositories-file", "/dev/null", "--repository", try repo.apkArg(arena) });
    if (repo.key_dir) |kd| try argv.appendSlice(arena, &.{ "--keys-dir", kd });
    try argv.append(arena, "add");
    try argv.appendSlice(arena, a.packages);
    try b.steps.append(arena, .{
        .desc = try b.fmt("Install {d} extra package(s) from {s}", .{ a.packages.len, repo.root }),
        .action = .{ .command = .{ .argv = argv.items } },
        .soft = true,
    });
    if (a.keep_repo) {
        const rel = if (repo.rel_dir.len > 0) repo.rel_dir else try b.fmt("apks/{s}", .{probe_mod.repoArch()});
        const line = try b.fmt(
            \\
            \\# The installation medium's repository, kept by the installer. Mount the
            \\# disc or stick at /mnt/cdrom, remove the "#" and run `apk update` to use it.
            \\#/mnt/cdrom/{s}{s}
            \\
        , .{ rel, if (std.mem.eql(u8, repo.index, "Packages.adb")) "/Packages.adb" else "" });
        try b.cmdStdin("Keep the repository (commented out) in the new system", &.{ "tee", "-a", target ++ "/etc/apk/repositories" }, line, false);
    }
    if (repo.mounted_dev) |_| try b.cmd("Unmount the repository medium", &.{ "umount", repo.root });
}

fn espBootx64(_: Probe, disk: Disk, esp_dev: []const u8) bool {
    const part = disk.findPartition(esp_dev) orelse return true;
    return part.has_bootx64 orelse true;
}

/// udev removes and re-adds the partition nodes while the kernel re-reads a
/// new table; formatting straight after `sfdisk` can find /dev/vda2 missing
/// (seen in QEMU on the dkde image). Wait for udev when it is there.
fn waitForDevices(b: *Builder) !void {
    const paths = [_][]const u8{ "/usr/sbin/udevadm", "/sbin/udevadm", "/usr/bin/udevadm", "/bin/udevadm" };
    try b.steps.append(b.arena, .{
        .desc = "Wait for the new partition devices to settle",
        .action = .{ .command = .{ .argv = try b.arena.dupe([]const u8, &.{ "udevadm", "settle", "--timeout=30" }) } },
        .when = .{ .any_of = &paths },
        .soft = true,
    });
}

fn planAuto(b: *Builder, disk: Disk, root_fs: fs_mod.Fs, ids: files.Ids) BuildError!Layout {
    const arena = b.arena;
    const esp_dev = try files.partitionPath(arena, disk.name, 2);
    const root_dev = try files.partitionPath(arena, disk.name, 3);
    try b.cmd("Erase all signatures on the disk", &.{ "wipefs", "-a", disk.path });
    try b.cmdStdin("Write the partition table", &.{ "sfdisk", disk.path }, try files.sfdiskScript(arena, ids), false);
    try waitForDevices(b);
    try b.cmd("Format the EFI System Partition", &.{ "mkfs.vfat", "-F", "32", "-n", "ESP", "-i", ids.esp_vol_id, esp_dev });
    try b.cmd(try b.fmt("Format the root filesystem ({s})", .{fs_mod.info(root_fs).name}), try fs_mod.mkfsArgv(arena, root_fs, "dkrescue", ids.root_fs_uuid, root_dev, false));
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
            // A partition about to be formatted is not a BIOS boot partition, whatever its type says.
            if (std.mem.eql(u8, q.path, root.path)) continue;
            if (esp_part) |e| if (std.mem.eql(u8, q.path, e.path)) continue;
            found = q;
            break;
        };
        if (found == null) {
            const name = a.bios_boot orelse return b.refuse("BIOS boot on a GPT disk needs a BIOS boot partition (1 MiB or more); none found", .{});
            const q = disk.findPartition(name) orelse return b.refuse("BIOS boot partition {s} is not on {s}", .{ name, disk.path });
            if (std.mem.eql(u8, q.path, root.path)) return b.refuse("root and the BIOS boot partition are the same partition", .{});
            if (esp_part) |e| if (std.mem.eql(u8, q.path, e.path)) return b.refuse("the ESP and the BIOS boot partition are the same partition", .{});
            if (q.size < MiB) return b.refuse("BIOS boot partition {s} is smaller than 1 MiB", .{q.path});
            if (!isBiosBootType(q.parttype) and !biosBootCandidate(q)) return b.refuse("{s} can't become the BIOS boot partition: it must be at most {d} MiB with no filesystem, because its contents are overwritten", .{ q.path, bios_boot_max_size / MiB });
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
    try b.cmd(try b.fmt("Format the root filesystem ({s})", .{fs_mod.info(a.root_fs).name}), try fs_mod.mkfsArgv(arena, a.root_fs, "dkrescue", ids.root_fs_uuid, root.path, true));
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
    try std.testing.expect(contains(out, "sed -i 's| --autologin rescue | |' /run/dkrescue-install/target/etc/dinit.d/tty1"));
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

test "btrfs root: formatted with mkfs.btrfs, fstab says btrfs, when its tools and kernel support are there" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    p.tools = &.{"mkfs.btrfs"};
    p.kernel_builtin = &.{"BTRFS_FS"};
    var a = testAnswers("nvme0n1", .auto);
    a.root_fs = .btrfs;
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "mkfs.btrfs -L dkrescue -U 11111111-2222-3333-4444-555555555555 /dev/nvme0n1p3"));
    try std.testing.expect(!contains(out, "mkfs.ext4"));
    try std.testing.expect(contains(out, "btrfs  defaults,noatime    0 0"));
    var have = false;
    for (r.plan.programs) |prog| if (std.mem.eql(u8, prog, "mkfs.btrfs")) {
        have = true;
    };
    try std.testing.expect(have);
}

test "btrfs on existing partitions is forced (-f), as ext4 is (-F)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-sata-fdisk.json");
    p.tools = &.{"mkfs.btrfs"};
    p.kernel_builtin = &.{"BTRFS_FS"};
    var a = testAnswers("sda", .existing);
    a.root_fs = .btrfs;
    a.root = "sda2";
    a.esp = "sda1";
    a.set_esp_type = true;
    const r = try build(arena, p, a, test_ids);
    switch (r) {
        .plan => |pl| try std.testing.expect(contains(try dryRun(arena, pl), "mkfs.btrfs -f -L dkrescue")),
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    }
}

test "a root filesystem that cannot be used is refused with the reason, before anything is written" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const base = try loadFixture(arena, "uefi-nvme-blank.json");
    var a = testAnswers("nvme0n1", .auto);

    a.root_fs = .btrfs;
    const no_tool = try build(arena, base, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, no_tool.refused, "the live disc is missing mkfs.btrfs (package btrfs-progs)") != null);

    var with_tool = base;
    with_tool.tools = &.{"mkfs.btrfs"};
    const module = try build(arena, with_tool, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, module.refused, "needs an initramfs") != null);

    a.root_fs = .xfs;
    var xfs = base;
    xfs.tools = &.{"mkfs.xfs"};
    xfs.kernel_builtin = &.{"XFS_FS"};
    const x = try build(arena, xfs, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, x.refused, "dklilo cannot read xfs") != null);

    a.root_fs = .zfs;
    var zfs = base;
    zfs.tools = &.{ "zpool", "zfs" };
    const z = try build(arena, zfs, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, z.refused, "initramfs") != null);
}

test "ext2 needs mkfs.ext2 on the live disc; ext4 (the default) needs nothing extra" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const base = try loadFixture(arena, "uefi-nvme-blank.json");
    var a = testAnswers("nvme0n1", .auto);
    a.root_fs = .ext2;
    const missing = try build(arena, base, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, missing.refused, "missing mkfs.ext2 (package e2fsprogs)") != null);
    var p = base;
    p.tools = &.{"mkfs.ext2"};
    const ok = try build(arena, p, a, test_ids);
    try std.testing.expect(contains(try dryRun(arena, ok.plan), "mkfs.ext2 -L dkrescue -U "));
}

test "GRUB on BIOS: a drop-in for root=PARTUUID, grub-install into the disk, update-grub, nothing for dklilo" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "bios-sata-windows.json");
    p.tools = &.{ "grub-install", "update-grub" };
    p.paths = &.{"/usr/lib/grub/i386-pc"};
    var a = testAnswers("sda", .auto);
    a.bootloader = .grub;
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "GRUB_DISABLE_LINUX_UUID=true"));
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target grub-install --target=i386-pc --recheck /dev/sda\n"));
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target update-grub\n"));
    try std.testing.expect(contains(out, "mount --rbind /sys /run/dkrescue-install/target/sys"));
    try std.testing.expect(contains(out, "umount -R /run/dkrescue-install/target/sys"));
    try std.testing.expect(!contains(out, "dklilo"));
    try std.testing.expect(!contains(out, "dklilo.conf"));
}

test "GRUB on UEFI installs for the x86_64-efi platform, ESP at /boot/efi" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    p.tools = &.{ "grub-install", "update-grub" };
    p.paths = &.{"/usr/lib/grub/x86_64-efi"};
    var a = testAnswers("nvme0n1", .auto);
    a.bootloader = .grub;
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable"));
    try std.testing.expect(contains(out, "UUID=ABCD-1234  /boot/efi"));
}

test "systemd-boot: the ESP is /boot, the kernel files move onto it, bootctl and gen-systemd-boot run in the new system" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    p.tools = &.{ "bootctl", "gen-systemd-boot" };
    p.paths = &.{"/usr/lib/systemd/boot/efi"};
    var a = testAnswers("nvme0n1", .auto);
    a.bootloader = .@"systemd-boot";
    const r = try build(arena, p, a, test_ids);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "UUID=ABCD-1234  /boot  vfat"));
    try std.testing.expect(!contains(out, "/boot/efi"));
    try std.testing.expect(contains(out, "mount -o umask=0077 /dev/nvme0n1p2 /run/dkrescue-install/target/boot\n"));
    // efivars is writable in this fixture: a boot entry is made
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target bootctl install --esp-path=/boot\n"));
    try std.testing.expect(!contains(out, "--no-variables"));
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target gen-systemd-boot\n"));
    try std.testing.expect(contains(out, "SD_BOOT_CMDLINE=\"root=PARTUUID=aaaaaaaa-0000-0000-0000-000000000003 quiet\""));
    // the kernel files are moved before the ESP covers /boot, and the order of the whole thing holds
    const keep = std.mem.indexOf(u8, out, "boot-stash").?;
    const mnt = std.mem.indexOf(u8, out, "mount -o umask=0077 /dev/nvme0n1p2 /run/dkrescue-install/target/boot").?;
    const bootctl = std.mem.indexOf(u8, out, "bootctl install").?;
    try std.testing.expect(keep < mnt and mnt < bootctl);
}

test "a boot loader that cannot be used is refused with the reason; XFS needs GRUB or systemd-boot" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const base = try loadFixture(arena, "bios-sata-windows.json");
    var a = testAnswers("sda", .auto);
    a.bootloader = .grub;
    const no_grub = try build(arena, base, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, no_grub.refused, "the live disc is missing grub-install and update-grub (package grub)") != null);
    a.bootloader = .@"systemd-boot";
    const sd = try build(arena, base, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, sd.refused, "boots UEFI machines only") != null);

    // XFS: refused under dklilo, allowed under GRUB once its tools and the kernel have it
    var p = base;
    p.tools = &.{ "mkfs.xfs", "grub-install", "update-grub" };
    p.paths = &.{"/usr/lib/grub/i386-pc"};
    p.kernel_builtin = &.{"XFS_FS"};
    a.root_fs = .xfs;
    a.bootloader = .dklilo;
    const under_dklilo = try build(arena, p, a, test_ids);
    try std.testing.expect(std.mem.indexOf(u8, under_dklilo.refused, "dklilo cannot read xfs: choose GRUB or systemd-boot") != null);
    a.bootloader = .grub;
    const under_grub = try build(arena, p, a, test_ids);
    try std.testing.expect(contains(try dryRun(arena, under_grub.plan), "mkfs.xfs -L dkrescue -m uuid="));
}

test "a keymap becomes a dinit service linked into boot.d; none, no service" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    var a = testAnswers("nvme0n1", .auto);
    a.keymap = "de";
    const with = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(with, "write /run/dkrescue-install/target/etc/dinit.d/keymap"));
    try std.testing.expect(contains(with, "loadkeys -q de"));
    try std.testing.expect(contains(with, "ln -sf ../keymap /run/dkrescue-install/target/etc/dinit.d/boot.d/keymap"));
    a.keymap = null;
    const without = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(!contains(without, "dinit.d/keymap"));
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

// ---------------------------------------------------------------- tests: config

fn svcAnswers() Answers {
    return testAnswers("nvme0n1", .auto);
}

fn buildSvc(arena: Allocator, a: Answers) !Result {
    const p = try loadFixture(arena, "uefi-services.json");
    return build(arena, p, a, test_ids);
}

test "SELinux: label step is conditional and never fatal; mode is written" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.selinux = .enforcing;
    const r = try buildSvc(arena, a);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "setfiles -F -r /run/dkrescue-install/target -e /run/dkrescue-install/target/proc"));
    try std.testing.expect(contains(out, "-e /run/dkrescue-install/target/boot/efi /run/dkrescue-install/target/etc/selinux/targeted/contexts/files/file_contexts /run/dkrescue-install/target"));
    try std.testing.expect(contains(out, "runs only if all of these exist: /run/dkrescue-install/target/etc/selinux/config"));
    try std.testing.expect(contains(out, "failure here is a warning"));
    try std.testing.expect(contains(out, "touch /run/dkrescue-install/target/.autorelabel"));
    try std.testing.expect(contains(out, "s/^SELINUX=.*/SELINUX=enforcing/"));
    // The setfiles step is soft; the kernel command line is untouched.
    try std.testing.expect(!contains(out, "selinux=1"));
    // Disabled: the mode is written and nothing is labelled.
    a.selinux = .disabled;
    const d = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(d, "SELINUX=disabled"));
    try std.testing.expect(!contains(d, "setfiles"));
}

test "services: enable and disable as the image does; core and unknown are refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.services_enable = &.{ "cupsd", "sshd" };
    a.services_disable = &.{ "firewalld", "networkmanager" };
    const out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "ln -sfn /usr/lib/dinit.d/cupsd /run/dkrescue-install/target/etc/dinit.d/boot.d/cupsd"));
    try std.testing.expect(contains(out, "ln -sfn ../sshd /run/dkrescue-install/target/etc/dinit.d/boot.d/sshd"));
    try std.testing.expect(contains(out, "rm -f /run/dkrescue-install/target/etc/dinit.d/boot.d/firewalld"));
    // Already as chosen: no step.
    a.services_enable = &.{"udevd"};
    a.services_disable = &.{};
    try std.testing.expect(!contains(try dryRun(arena, (try buildSvc(arena, a)).plan), "udevd service"));
    a.services_enable = &.{};
    a.services_disable = &.{"udevd"};
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "needed to boot"));
    a.services_disable = &.{"nonesuch"};
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "no such service"));
}

test "a service with a missing dependency is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.services_enable = &.{"bluetoothd"};
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "needs avahi-daemon"));
}

test "firewall and NTP use the image's own services" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.firewall = false;
    a.ntp = true;
    const out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "rm -f /run/dkrescue-install/target/etc/dinit.d/boot.d/firewalld"));
    try std.testing.expect(contains(out, "boot.d/chronyd"));
    // On the plain fixture (no services) they are refused.
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "no firewalld"));
}

test "ssh: drop-in, host keys, authorized_keys, generated key" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.ssh = .{ .enable = true, .root_login = .no, .password_auth = false, .authorized_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@host" };
    var out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "write /run/dkrescue-install/target/etc/ssh/sshd_config.d/10-dkinstall.conf (mode 0644)"));
    try std.testing.expect(contains(out, "| PermitRootLogin no"));
    try std.testing.expect(contains(out, "| PasswordAuthentication no"));
    try std.testing.expect(contains(out, "ssh-keygen -A -f /run/dkrescue-install/target"));
    try std.testing.expect(contains(out, "Include /etc/ssh/sshd_config.d/"));
    try std.testing.expect(contains(out, "write /run/dkrescue-install/target/home/dakota/.ssh/authorized_keys (mode 0600)"));
    try std.testing.expect(contains(out, "| ssh-ed25519 AAAAC3"));
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target chown -R dakota: /home/dakota/.ssh"));
    try std.testing.expect(contains(out, "ln -sfn ../sshd"));
    a.ssh.?.authorized_key = null;
    a.ssh.?.generate_key = true;
    out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "ssh-keygen -t ed25519 -N '' -C dakota@dkrescue -f /run/dkrescue-install/target/home/dakota/.ssh/id_ed25519"));
    try std.testing.expect(contains(out, "cp /run/dkrescue-install/target/home/dakota/.ssh/id_ed25519.pub"));
    // root login values.
    a.ssh.?.root_login = .@"prohibit-password";
    try std.testing.expect(contains(try dryRun(arena, (try buildSvc(arena, a)).plan), "PermitRootLogin prohibit-password"));
}

test "ssh: no password and no key is a lockout, refused unless confirmed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.ssh = .{ .enable = true, .password_auth = false };
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "nobody could log in"));
    a.ssh.?.allow_lockout = true;
    try std.testing.expect((try buildSvc(arena, a)) == .plan);
    // sshd staying off: no lockout to warn about.
    a.ssh = .{ .enable = false, .password_auth = false };
    try std.testing.expect((try buildSvc(arena, a)) == .plan);
    a.ssh = .{ .enable = true, .authorized_key = "ssh-ed25519 short" };
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "public key"));
}

test "network: NetworkManager keyfiles, passphrase masked" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.domain = "example.org";
    a.network = .{
        .ifaces = &.{
            .{ .name = "eth0", .kind = .static, .address = "192.168.1.5/24", .gateway = "192.168.1.1" },
            .{ .name = "eth1", .kind = .disabled },
        },
        .dns = &.{ "1.1.1.1", "2606:4700:4700::1111" },
        .search = "example.org",
        .wifi = .{ .ssid = "Home", .psk = "s3cretpassphrase", .hidden = true },
    };
    const r = try buildSvc(arena, a);
    const out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "write /run/dkrescue-install/target/etc/NetworkManager/system-connections/dk-eth0.nmconnection (mode 0600)"));
    try std.testing.expect(contains(out, "| address1=192.168.1.5/24,192.168.1.1"));
    try std.testing.expect(contains(out, "| dns=1.1.1.1;"));
    try std.testing.expect(contains(out, "| dns=2606:4700:4700::1111;"));
    try std.testing.expect(contains(out, "| dns-search=example.org;"));
    try std.testing.expect(contains(out, "| interface-name=eth1"));
    try std.testing.expect(contains(out, "| autoconnect=false"));
    try std.testing.expect(contains(out, "wifi-Home.nmconnection (mode 0600)"));
    try std.testing.expect(contains(out, "(contents hidden)"));
    try std.testing.expect(!contains(out, "s3cretpassphrase"));
    // The file itself has the key.
    var psk = false;
    for (r.plan.steps) |s| switch (s.action) {
        .write_file => |f| if (f.secret and contains(f.contents, "psk=s3cretpassphrase") and contains(f.contents, "hidden=true") and contains(f.contents, "key-mgmt=wpa-psk")) {
            psk = true;
        },
        else => {},
    };
    try std.testing.expect(psk);
    // Hostname and domain agree in /etc/hosts.
    try std.testing.expect(contains(out, "127.0.1.1  dkrescue.example.org dkrescue"));
}

test "network: default DHCP writes nothing; dhcpcd target gets dhcpcd.conf and wpa_supplicant.conf" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.network = .{ .ifaces = &.{.{ .name = "eth0", .kind = .dhcp }} };
    try std.testing.expect(!contains(try dryRun(arena, (try buildSvc(arena, a)).plan), "nmconnection"));
    var p = try loadFixture(arena, "uefi-services.json");
    p.net_stack = .dhcpcd;
    a.network = .{
        .ifaces = &.{ .{ .name = "eth0", .kind = .static, .address = "10.0.0.2/8", .gateway = "10.0.0.1" }, .{ .name = "eth1", .kind = .disabled } },
        .dns = &.{"9.9.9.9"},
        .wifi = .{ .ssid = "Home", .psk = "s3cretpassphrase" },
    };
    const out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(out, "tee -a /run/dkrescue-install/target/etc/dhcpcd.conf"));
    try std.testing.expect(contains(out, "static ip_address=10.0.0.2/8"));
    try std.testing.expect(contains(out, "static routers=10.0.0.1"));
    try std.testing.expect(contains(out, "static domain_name_servers=9.9.9.9"));
    try std.testing.expect(contains(out, "interface eth1\nnoipv4"));
    try std.testing.expect(contains(out, "sh -c 'umask 077 && cat >> \"$1\"' sh /run/dkrescue-install/target/etc/wpa_supplicant/wpa_supplicant.conf   # stdin: (hidden)"));
    try std.testing.expect(!contains(out, "tee -a /run/dkrescue-install/target/etc/wpa_supplicant"));
    try std.testing.expect(!contains(out, "s3cretpassphrase"));
}

test "network: copy the live connection; refuse an unknown one" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.network = .{ .mode = .copy, .copy = "Wired connection 1.nmconnection" };
    const out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "cp -p '/etc/NetworkManager/system-connections/Wired connection 1.nmconnection' /run/dkrescue-install/target/etc/NetworkManager/system-connections/"));
    a.network = .{ .mode = .copy, .copy = "nope" };
    try std.testing.expect(contains((try buildSvc(arena, a)).refused, "no NetworkManager connection"));
}

test "network: manual leaves it unconfigured with the services off; manual-shell opens a shell" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.network = .{ .mode = .manual };
    var out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "Network: left unconfigured; the network services are disabled"));
    try std.testing.expect(contains(out, "rm -f /run/dkrescue-install/target/etc/dinit.d/boot.d/networkmanager"));
    try std.testing.expect(contains(out, "boot.d/wpa_supplicant"));
    try std.testing.expect(!contains(out, "nmconnection"));
    a.network = .{ .mode = .@"manual-shell" };
    a.services_disable = &.{"networkmanager"};
    const r = try buildSvc(arena, a);
    out = try dryRun(arena, r.plan);
    try std.testing.expect(contains(out, "open a shell in the new system"));
    // The installer does not touch the network services in this mode.
    try std.testing.expect(!contains(out, "boot.d/networkmanager"));
    // The shell comes after the system is copied and before the bootloader.
    try std.testing.expect(std.mem.indexOf(u8, out, "open a shell").? > std.mem.indexOf(u8, out, "unsquashfs").?);
    try std.testing.expect(std.mem.indexOf(u8, out, "open a shell").? < std.mem.indexOf(u8, out, "dklilo").?);
    try std.testing.expectEqualStrings("/dev/nvme0n1p3", r.plan.root_dev);
    // chroot is a program the install needs when a key is chowned.
}

test "repository: sets, no sets, none, and a bad package name" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    var a = svcAnswers();
    a.packages = &.{ "curl", "wget" };
    // No repository: refused.
    try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "no repository"));
    // With sets (data/apks layout, key in keys/).
    p.repo = (try probe_mod.findRepo(arena, std.testing.io, "tests/repos/with-sets", "x86_64")).?;
    try std.testing.expectEqual(@as(usize, 2), p.repo.?.sets.len);
    var out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(out, "apk --root /run/dkrescue-install/target --no-network --no-progress --repositories-file /dev/null --repository tests/repos/with-sets/data/apks/x86_64/Packages.adb --keys-dir tests/repos/with-sets/keys add curl wget"));
    try std.testing.expect(contains(out, "cp tests/repos/with-sets/keys/fenriros.pub /run/dkrescue-install/target/etc/apk/keys"));
    try std.testing.expect(!contains(out, "/etc/apk/repositories"));
    // apk comes before the bootloader, after the copy.
    try std.testing.expect(std.mem.indexOf(u8, out, "apk --root").? > std.mem.indexOf(u8, out, "unsquashfs").?);
    try std.testing.expect(std.mem.indexOf(u8, out, "apk --root").? < std.mem.indexOf(u8, out, "dklilo").?);
    // Keep the repository: a commented-out line.
    a.keep_repo = true;
    out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(out, "tee -a /run/dkrescue-install/target/etc/apk/repositories"));
    try std.testing.expect(contains(out, "#/mnt/cdrom/data/apks/x86_64/Packages.adb"));
    // Without sets (apks/ layout, APKINDEX.tar.gz, key next to the packages).
    p.repo = (try probe_mod.findRepo(arena, std.testing.io, "tests/repos/no-sets", "x86_64")).?;
    try std.testing.expectEqual(@as(usize, 0), p.repo.?.sets.len);
    a.keep_repo = false;
    out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(out, "--repository tests/repos/no-sets/apks/x86_64 --keys-dir tests/repos/no-sets/apks/x86_64 add curl wget"));
    // Nothing chosen: no steps at all.
    a.packages = &.{};
    try std.testing.expect(!contains(try dryRun(arena, (try build(arena, p, a, test_ids)).plan), "apk --root"));
    a.packages = &.{"--root"};
    try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "invalid package name"));
}

test "--repo path: missing directory and a directory with no layout are errors" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    try std.testing.expectError(error.RepoMissing, probe_mod.findRepo(arena, std.testing.io, "tests/repos/does-not-exist", "x86_64"));
    try std.testing.expectError(error.RepoNoLayout, probe_mod.findRepo(arena, std.testing.io, "tests/repos/empty", "x86_64"));
    try std.testing.expectEqual(@as(?probe_mod.Repo, null), try probe_mod.findRepo(arena, std.testing.io, null, "x86_64") orelse null);
}

test "package sets parse; candidates never include the target disk" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const sets = try probe_mod.parseSets(arena, "# c\nweb | Web | nginx php\nbad\n | x | y\nempty | none |\n");
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    try std.testing.expectEqualStrings("nginx", sets[0].packages[0]);
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    const c = try probe_mod.repoCandidates(arena, p, "sdc");
    for (c) |x| try std.testing.expect(!std.mem.startsWith(u8, x.path, "/dev/sdc") and !std.mem.eql(u8, x.path, "/dev/sdb1"));
    // sdc1 is mounted anyway; the live medium (sdb1) is never offered.
    try std.testing.expectEqualStrings("a label", probe_mod.serviceLabel("#!/bin/sh\n# a label\nx"));
    try std.testing.expectEqualStrings("Hello", probe_mod.serviceLabel("type = process\ndescription = Hello\n"));
    const keys = try probe_mod.findPubFiles(arena, std.testing.io, &.{"tests/keys"});
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("tests/keys/me.pub", keys[0]);
    try std.testing.expect(answers_mod.validPubKey(probe_mod.firstKeyLine(try Io.Dir.cwd().readFileAlloc(std.testing.io, keys[0], arena, .limited(4096))).?));
}

test "post-install commands run in the chroot as soft steps, after configuration and before the bootloader" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var a = svcAnswers();
    a.post = &.{ "echo hi > /etc/motd", "ln -s a b" };
    const out = try dryRun(arena, (try buildSvc(arena, a)).plan);
    try std.testing.expect(contains(out, "chroot /run/dkrescue-install/target /bin/sh -c 'echo hi > /etc/motd'"));
    try std.testing.expect(contains(out, ". Post-install command: ln -s a b"));
    try std.testing.expect(std.mem.indexOf(u8, out, "echo hi").? < std.mem.indexOf(u8, out, "dklilo").?);
    try std.testing.expect(contains(out, "failure here is a warning"));
}

fn biosGptFixture(arena: Allocator) !Probe {
    var p = try loadFixture(arena, "bios-mbr-fdisk.json");
    const parts = try arena.alloc(Partition, 2);
    parts[0] = p.disks[0].partitions[0];
    parts[1] = .{ .name = "vda2", .path = "/dev/vda2", .number = 2, .size = 2 * MiB };
    const disks = try arena.dupe(Disk, p.disks);
    disks[0].table = "gpt";
    disks[0].partitions = parts;
    p.disks = disks;
    return p;
}

test "the BIOS boot partition is never root, given by either name" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try biosGptFixture(arena);
    var a = testAnswers("vda", .existing);
    a.root = "vda1";
    a.set_bios_boot_type = true;
    for ([_][]const u8{ "vda1", "/dev/vda1" }) |name| {
        a.bios_boot = name;
        const r = try build(arena, p, a, test_ids);
        try std.testing.expect(contains(r.refused, "same partition"));
    }
    a.bios_boot = "vda2";
    const ok = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(ok, "sfdisk --part-type /dev/vda 2 " ++ files.guid_bios_boot));
    // Root already typed as BIOS boot does not count as the BIOS boot partition.
    const parts = try arena.dupe(Partition, p.disks[0].partitions);
    parts[0].parttype = files.guid_bios_boot;
    const disks = try arena.dupe(Disk, p.disks);
    disks[0].partitions = parts;
    p.disks = disks;
    a.bios_boot = null;
    try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "none found"));
}

test "only a small partition without a filesystem is retyped as BIOS boot" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const base = try biosGptFixture(arena);
    var a = testAnswers("vda", .existing);
    a.root = "vda1";
    a.bios_boot = "vda2";
    a.set_bios_boot_type = true;
    const cases = [_]struct { size: u64, fstype: ?[]const u8 }{
        .{ .size = 500 * 1024 * MiB, .fstype = null },
        .{ .size = 2 * MiB, .fstype = "ntfs" },
    };
    for (cases) |c| {
        var p = base;
        const parts = try arena.dupe(Partition, base.disks[0].partitions);
        parts[1].size = c.size;
        parts[1].fstype = c.fstype;
        const disks = try arena.dupe(Disk, base.disks);
        disks[0].partitions = parts;
        p.disks = disks;
        try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "contents are overwritten"));
    }
}

test "systemd-boot on a kept ESP restores its BOOTX64.EFI; with read-only efivars it refuses" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-sata-fdisk.json");
    p.tools = &.{ "bootctl", "gen-systemd-boot" };
    p.paths = &.{"/usr/lib/systemd/boot/efi"};
    var a = testAnswers("sda", .existing);
    a.root = "sda2";
    a.esp = "sda1";
    a.set_esp_type = true;
    a.bootloader = .@"systemd-boot";
    const out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(contains(out, "keeping the ESP's own BOOTX64.EFI"));
    try std.testing.expect(contains(out, "BOOTX64.EFI /run/dkrescue-install/BOOTX64.EFI.kept chroot"));
    p.efivars_rw = false;
    try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "never replaced"));
    a.format_esp = true;
    try std.testing.expect(!contains(try dryRun(arena, (try build(arena, p, a, test_ids)).plan), "BOOTX64.EFI.kept"));
}

test "the keep-file script restores the file even when the command fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const f = try std.fmt.allocPrint(gpa, "{s}/BOOTX64.EFI", .{dir});
    defer gpa.free(f);
    const s = try std.fmt.allocPrint(gpa, "{s}/saved", .{dir});
    defer gpa.free(s);
    try tmp.dir.writeFile(io, .{ .sub_path = "BOOTX64.EFI", .data = "other system" });
    for ([_]u8{ 0, 3 }) |code| {
        const cmd = try std.fmt.allocPrint(gpa, "echo systemd > '{s}'; exit {d}", .{ f, code });
        defer gpa.free(cmd);
        const r = try std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", keep_file, "sh", f, s, "sh", "-c", cmd } });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, r.term);
        const now = try tmp.dir.readFileAlloc(io, "BOOTX64.EFI", gpa, .limited(100));
        defer gpa.free(now);
        try std.testing.expectEqualStrings("other system", now);
    }
}

test "a user name that is taken is refused; the live user's name works because it is removed first" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-nvme-blank.json");
    var names: std.ArrayList([]const u8) = .empty;
    try probe_mod.accountNames(arena, &names, "root:x:0:0::/root:/bin/sh\ndaemon:x:1:1::/:/bin/false\nrescue:x:1000:1000::/home/rescue:/bin/sh\nwheel:x:10:\n");
    p.accounts = names.items;
    var a = testAnswers("nvme0n1", .auto);
    for ([_][]const u8{ "root", "daemon", "wheel" }) |name| {
        a.user = name;
        try std.testing.expect(contains((try build(arena, p, a, test_ids)).refused, "already taken"));
    }
    a.user = "rescue";
    const out = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    const del = std.mem.indexOf(u8, out, "userdel -R /run/dkrescue-install/target -r rescue").?;
    const add = std.mem.indexOf(u8, out, "/bin/bash rescue").?;
    try std.testing.expect(del < add);
    p.live_user = "";
    a.user = "dakota";
    const none = try dryRun(arena, (try build(arena, p, a, test_ids)).plan);
    try std.testing.expect(!contains(none, "userdel") and !contains(none, "--autologin"));
}
