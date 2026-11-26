//! Reads the machine and returns plain data: firmware, disks and partitions,
//! the live medium, `rootfs.size`. Implements SPEC.md 5.1, 5.2 and 6.1.
//!
//! Everything is allocated from the caller's arena. A probe can come from
//! the running machine (`live`) or from a recorded fixture (`fromFixture`).

const std = @import("std");
const fs_mod = @import("fs.zig");
const bl_mod = @import("bootloader.zig");
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
    /// A package repository medium found (or chosen with `--repo`), if any.
    repo: ?Repo = null,
    /// The live system's own login (removed from the new system): "rescue" on
    /// the rescue image, "live" on the dkde image; read from its /etc/passwd.
    live_user: []const u8 = "rescue",
    /// User and group names the system already has: `useradd` can't make another by that name.
    accounts: []const []const u8 = &.{},
    /// The dinit services of the system image (the live system is the image).
    services: []const Service = &.{},
    /// The image has /etc/selinux/config.
    selinux: bool = false,
    /// Network interfaces of the live system (not `lo`).
    net_ifaces: []const NetIface = &.{},
    /// Which network stack the image has (the target is a copy of it).
    net_stack: NetStack = .none,
    /// Connection files of the live NetworkManager (the session's own setup).
    live_connections: []const []const u8 = &.{},
    /// Which of `fs.candidate_tools` (mkfs.btrfs, mkfs.xfs, zpool, ...) are in PATH on the live disc.
    tools: []const []const u8 = &.{},
    /// Which of `fs.kernel_symbols` (BTRFS_FS, XFS_FS) are `=y` in the target kernel's config.
    kernel_builtin: []const []const u8 = &.{},
    /// Which of `bootloader.candidate_paths` (GRUB's platform modules, systemd-boot's EFI files) exist.
    paths: []const []const u8 = &.{},

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
            .mounted => "has a mounted partition, or one in use",
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

// ---------------------------------------------------------------- network

pub const NetIface = struct {
    name: []const u8,
    wireless: bool = false,
};

/// NetworkManager (dkde), dhcpcd + wpa_supplicant (rescue's base-net), or neither.
pub const NetStack = enum { networkmanager, dhcpcd, none };

/// The services that make up the network stack.
pub const net_service_names = [_][]const u8{ "networkmanager", "wpa_supplicant", "dhcpcd" };

pub const nm_connections_dir = "/etc/NetworkManager/system-connections";

fn detectStack(arena: Allocator, io: Io, root: []const u8, services: []const Service) NetStack {
    if (findService(services, "networkmanager") != null or existsIn(arena, io, root, "/usr/sbin/NetworkManager") or existsIn(arena, io, root, "/usr/bin/NetworkManager")) return .networkmanager;
    if (findService(services, "dhcpcd") != null or existsIn(arena, io, root, "/usr/sbin/dhcpcd") or existsIn(arena, io, root, "/sbin/dhcpcd")) return .dhcpcd;
    return .none;
}

fn readNetIfaces(arena: Allocator, io: Io) Allocator.Error![]const NetIface {
    var out: std.ArrayList(NetIface) = .empty;
    var d = Io.Dir.cwd().openDir(io, "/sys/class/net", .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (std.mem.eql(u8, e.name, "lo")) continue;
        const wl = try std.fmt.allocPrint(arena, "/sys/class/net/{s}/wireless", .{e.name});
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .wireless = exists(io, wl) });
    }
    std.mem.sort(NetIface, out.items, {}, struct {
        fn lt(_: void, a: NetIface, b: NetIface) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items;
}

fn readConnections(arena: Allocator, io: Io) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, nm_connections_dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and e.name[0] != '.') try out.append(arena, try arena.dupe(u8, e.name));
    }
    return out.items;
}

// ---------------------------------------------------------------- services

/// One dinit service of the image.
pub const Service = struct {
    name: []const u8,
    /// First comment line or `description =` of the service file; may be empty.
    label: []const u8 = "",
    /// Linked from /etc/dinit.d/boot.d: started at boot.
    enabled: bool = false,
    /// The file is in /usr/lib/dinit.d rather than /etc/dinit.d.
    in_usr: bool = false,
    /// Listens on the network (a server): shown marked, never changed by default.
    network: bool = false,
    /// Needed to boot or log in: not offered for switching off.
    core: bool = false,
    /// A service this one depends on (depends-on, depends-ms, waits-for) is not
    /// in the image: enabling it would stop dinit at boot ("could not load
    /// dependency"). Null when all are there.
    missing_dep: ?[]const u8 = null,

    /// Where `boot.d/<name>` points when enabled (dkbuild's image step).
    pub fn linkTarget(self: Service, arena: Allocator) ![]const u8 {
        return if (self.in_usr) std.fmt.allocPrint(arena, "/usr/lib/dinit.d/{s}", .{self.name}) else std.fmt.allocPrint(arena, "../{s}", .{self.name});
    }
};

const network_services = [_][]const u8{
    "sshd",       "firewalld",  "cupsd",          "cups",           "httpd",   "nginx",  "smbd",     "nmbd",    "samba",      "nfsd",      "rpcbind", "avahi-daemon",
    "avahi",      "named",      "bind",           "dhcpd",          "dnsmasq", "vsftpd", "exim",     "postfix", "dovecot",    "mariadb",   "mysqld",  "postgresql",
    "redis",      "ntpd",       "chronyd",        "incusd",         "incus",   "sddm",   "libvirtd", "docker",  "containerd", "mosquitto", "snmpd",   "telnetd",
    "bluetoothd", "tailscaled", "wpa_supplicant", "networkmanager",
};

/// Services the system needs to boot and log in.
const core_services = [_][]const u8{ "boot", "udevd", "udev-trigger", "udev-settle", "modules", "syslogd", "dbus", "seatd", "loginready", "rcboot", "single", "recovery", "system", "early-filesystems", "early-devices", "fsck", "mount-all", "remount-rootfs", "hostname", "cgroups", "tmpfiles", "filesystems", "late-filesystems", "rootrw", "rootfscheck", "auxfscheck", "dbus-prepare", "sshd-keys", "hwclock" };

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The label of a dinit service file: its first plain comment line (not a
/// `#!` line) or a `description =` line.
pub fn serviceLabel(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| : (n += 1) {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "description")) {
            if (std.mem.indexOfScalar(u8, l, '=')) |eq| return std.mem.trim(u8, l[eq + 1 ..], " \t");
        }
        if (l.len > 1 and l[0] == '#' and l[1] != '!') {
            const t = std.mem.trim(u8, l[1..], " #\t");
            if (t.len > 0) return t;
        }
        if (n > 12) break;
    }
    return "";
}

/// The first ordinary login (uid 1000-59999 with a /home directory) in /etc/passwd; empty if
/// there is none (nothing to remove then).
pub fn liveUser(arena: Allocator, io: Io, root: []const u8) []const u8 {
    const text = readIn(arena, io, root, "/etc/passwd") orelse return "";
    return firstOrdinaryUser(text) orelse "";
}

/// Appends the names (first field) of a passwd or group file.
pub fn accountNames(arena: Allocator, out: *std.ArrayList([]const u8), text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (colon > 0 and l[0] != '#') try out.append(arena, l[0..colon]);
    }
}

fn readAccounts(arena: Allocator, io: Io, root: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "/etc/passwd", "/etc/group" }) |path| {
        if (readIn(arena, io, root, path)) |text| try accountNames(arena, &out, text);
    }
    return out.items;
}

pub fn firstOrdinaryUser(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.splitScalar(u8, l, ':');
        const name = f.next() orelse continue;
        _ = f.next();
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        _ = f.next();
        _ = f.next();
        const home = f.next() orelse continue;
        if (uid >= 1000 and uid < 60000 and std.mem.startsWith(u8, home, "/home/")) return name;
    }
    return null;
}

/// The first `depends-on`/`depends-ms`/`waits-for` name in `text` that is not
/// among `services`; null if all are there.
pub fn missingDependency(text: []const u8, services: []const Service) ?[]const u8 {
    var deps: Dependencies = .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    while (deps.next()) |name| if (findService(services, name) == null) return name;
    return null;
}

/// Reads /etc/dinit.d and /usr/lib/dinit.d (files only) and boot.d of the system at `root`.
pub fn readServices(arena: Allocator, io: Io, root: []const u8) Allocator.Error![]const Service {
    var out: std.ArrayList(Service) = .empty;
    const dirs = [_]struct { path: []const u8, usr: bool }{ .{ .path = "/etc/dinit.d", .usr = false }, .{ .path = "/usr/lib/dinit.d", .usr = true } };
    for (dirs) |dd| {
        const dir_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ root, dd.path });
        var d = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (e.name.len == 0 or e.name[0] == '.') continue;
            if (std.mem.endsWith(u8, e.name, ".sh") or std.mem.endsWith(u8, e.name, ".md")) continue;
            var dup = false;
            for (out.items) |o| if (std.mem.eql(u8, o.name, e.name)) {
                dup = true;
            };
            if (dup) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dd.path, e.name });
            const label = if (readIn(arena, io, root, path)) |t| try arena.dupe(u8, serviceLabel(t)) else "";
            const link = try std.fmt.allocPrint(arena, "{s}/etc/dinit.d/boot.d/{s}", .{ root, e.name });
            try out.append(arena, .{
                .name = try arena.dupe(u8, e.name),
                .label = label,
                // The link itself: an absolute target would be looked up outside `root`.
                .enabled = linkPresent(io, link),
                .in_usr = dd.usr,
                .network = inList(&network_services, e.name),
                .core = inList(&core_services, e.name) or std.mem.startsWith(u8, e.name, "tty"),
            });
        }
    }
    std.mem.sort(Service, out.items, {}, struct {
        fn lt(_: void, a: Service, b: Service) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    const texts = try arena.alloc([]const u8, out.items.len);
    for (out.items, texts) |sv, *text| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ if (sv.in_usr) "/usr/lib/dinit.d" else "/etc/dinit.d", sv.name });
        text.* = readIn(arena, io, root, path) orelse "";
    }
    markMissingDependencies(out.items, texts);
    return out.items;
}

/// Sets `missing_dep` from each service's file (`texts`, in the same order), through any
/// number of services in between.
pub fn markMissingDependencies(services: []Service, texts: []const []const u8) void {
    for (services, texts) |*sv, t| sv.missing_dep = missingDependency(t, services);
    var changed = true;
    while (changed) {
        changed = false;
        for (services, texts) |*sv, t| {
            if (sv.missing_dep != null) continue;
            var deps: Dependencies = .{ .lines = std.mem.splitScalar(u8, t, '\n') };
            while (deps.next()) |name| {
                const dep = findService(services, name) orelse continue;
                if (dep.missing_dep) |missing| {
                    sv.missing_dep = missing;
                    changed = true;
                    break;
                }
            }
        }
    }
}

/// The names after `depends-on`, `depends-ms` and `waits-for` in a service file.
const Dependencies = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *Dependencies) ?[]const u8 {
        while (self.lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            for ([_][]const u8{ "depends-on", "depends-ms", "waits-for" }) |key| {
                if (!std.mem.startsWith(u8, l, key)) continue;
                var rest = std.mem.trim(u8, l[key.len..], " \t");
                if (rest.len == 0 or (rest[0] != ':' and rest[0] != '=')) continue;
                rest = std.mem.trim(u8, rest[1..], " \t");
                if (rest.len > 0) return rest;
            }
        }
        return null;
    }
};

pub fn findService(services: []const Service, name: []const u8) ?Service {
    for (services) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// NTP daemons in the order the installer prefers them.
pub const ntp_services = [_][]const u8{ "chronyd", "ntpd", "openntpd", "ntpsec" };

/// The NTP service the image has, if any.
pub fn ntpService(services: []const Service) ?Service {
    for (ntp_services) |n| if (findService(services, n)) |s| return s;
    return null;
}

// ---------------------------------------------------------------- repository

/// Where the repository disc is looked for when `--repo` is not given.
pub const repo_mounts = [_][]const u8{ "/mnt/cdrom", "/mnt/repo", "/media/cdrom", "/run/live/medium-repo", "/run/live/medium" };
/// Where the installer mounts a repository device itself (read-only).
pub const repo_mount_point = "/mnt/cdrom";
/// Index file names, newest format first.
pub const repo_indexes = [_][]const u8{ "Packages.adb", "APKINDEX.tar.gz" };
/// Package-set list names, in the order tried.
pub const repo_set_files = [_][]const u8{ "packages-sets.txt", "sets.txt" };

/// A named group of packages offered on the packages screen.
pub const PackageSet = struct {
    name: []const u8,
    description: []const u8,
    packages: []const []const u8,
};

/// A package repository on a mounted medium: `<root>/apks/<arch>/` or
/// `<root>/data/apks/<arch>/` (what `dkbuild discs` writes) with an index.
pub const Repo = struct {
    /// Mount point (or directory) of the medium.
    root: []const u8,
    /// The `apks/<arch>` directory, absolute.
    dir: []const u8,
    /// `dir` relative to `root`, e.g. "data/apks/x86_64".
    rel_dir: []const u8,
    /// "Packages.adb" or "APKINDEX.tar.gz".
    index: []const u8,
    /// Directory holding the signing key(s), absolute; null if none was found.
    key_dir: ?[]const u8 = null,
    /// Key files (`*.pub`) in `key_dir`, absolute.
    keys: []const []const u8 = &.{},
    /// Every key in `keys` is one the system image already trusts. Otherwise the medium
    /// vouches for itself, and the user has to agree to that.
    keys_trusted: bool = false,
    /// From `packages-sets.txt` / `sets.txt`; empty when the medium has none.
    sets: []const PackageSet = &.{},
    /// The installer mounted `mounted_dev` itself, so the plan unmounts it.
    mounted_dev: ?[]const u8 = null,

    /// What `apk --repository` takes: the index file for Packages.adb, the
    /// directory for an APKINDEX.tar.gz repository.
    pub fn apkArg(self: Repo, arena: Allocator) ![]const u8 {
        if (std.mem.eql(u8, self.index, "Packages.adb")) return std.fmt.allocPrint(arena, "{s}/{s}", .{ self.dir, self.index });
        return self.dir;
    }
};

pub const RepoError = error{ RepoMissing, RepoNoLayout, OutOfMemory };

/// The architecture directory name apk uses on this build.
pub fn repoArch() []const u8 {
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @tagName(@import("builtin").cpu.arch),
    };
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn indexIn(io: Io, dir: []const u8, arena: Allocator) ?[]const u8 {
    for (repo_indexes) |name| {
        const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return null;
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return name;
    }
    return null;
}

/// `name | description | pkg pkg ...` per line; `#` starts a comment.
/// Lines without three fields or without packages are ignored.
pub fn parseSets(arena: Allocator, text: []const u8) Allocator.Error![]const PackageSet {
    var out: std.ArrayList(PackageSet) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '|');
        const name = std.mem.trim(u8, f.next() orelse continue, " \t");
        const desc = std.mem.trim(u8, f.next() orelse continue, " \t");
        const pk = std.mem.trim(u8, f.rest(), " \t");
        if (name.len == 0 or pk.len == 0) continue;
        var pkgs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, pk, " \t");
        while (it.next()) |t| try pkgs.append(arena, try arena.dupe(u8, t));
        try out.append(arena, .{ .name = try arena.dupe(u8, name), .description = try arena.dupe(u8, desc), .packages = pkgs.items });
    }
    return out.items;
}

/// Where the image (or, without the image mount, the running system) keeps the keys apk trusts.
const trusted_key_dirs = [_][]const u8{ image_mount ++ "/etc/apk/keys", image_mount ++ "/usr/share/apk/keys", "/etc/apk/keys", "/usr/share/apk/keys" };

/// Whether every file in `keys` has the same contents as some file in `dirs`.
pub fn allTrusted(arena: Allocator, io: Io, keys: []const []const u8, dirs: []const []const u8) bool {
    next: for (keys) |key| {
        const want = readSmall(arena, io, key) orelse return false;
        for (dirs) |dir| {
            var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, e.name }) catch return false;
                const have = readSmall(arena, io, path) orelse continue;
                if (std.mem.eql(u8, have, want)) continue :next;
            }
        }
        return false;
    }
    return true;
}

/// SHA-256 of a key file in hex, as shown when asking whether to trust it.
pub fn keyDigest(arena: Allocator, io: Io, path: []const u8) []const u8 {
    const text = readSmall(arena, io, path) orelse return "(unreadable)";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&digest}) catch "?";
}

/// Looks for a repository under `root` (a mounted medium, or the `apks/<arch>`
/// directory itself). Null if the layout is not there.
pub fn repoAt(arena: Allocator, io: Io, root_in: []const u8, arch: []const u8) Allocator.Error!?Repo {
    const root = std.mem.trimEnd(u8, root_in, "/");
    const rels = [_][]const u8{
        try std.fmt.allocPrint(arena, "apks/{s}", .{arch}),
        try std.fmt.allocPrint(arena, "data/apks/{s}", .{arch}),
        "", // `root` is the apks/<arch> directory itself
    };
    for (rels) |rel| {
        const dir = if (rel.len == 0) try arena.dupe(u8, root) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
        const idx = indexIn(io, dir, arena) orelse continue;
        var repo: Repo = .{ .root = try arena.dupe(u8, root), .dir = dir, .rel_dir = rel, .index = idx };
        // Sets file.
        for (repo_set_files) |sf| {
            const sp = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, sf });
            if (readSmall(arena, io, sp)) |t| {
                repo.sets = try parseSets(arena, t);
                break;
            }
        }
        // Keys: next to the packages, or in keys/ of the medium (dkbuild discs).
        const key_dirs = [_][]const u8{
            dir,
            try std.fmt.allocPrint(arena, "{s}/keys", .{root}),
            try std.fmt.allocPrint(arena, "{s}/keys", .{dir}),
        };
        for (key_dirs) |kd| {
            var keys: std.ArrayList([]const u8) = .empty;
            var d = Io.Dir.cwd().openDir(io, kd, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                if ((e.kind == .file or e.kind == .sym_link) and std.mem.endsWith(u8, e.name, ".pub"))
                    try keys.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ kd, e.name }));
            }
            if (keys.items.len > 0) {
                std.mem.sort([]const u8, keys.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lt);
                repo.key_dir = kd;
                repo.keys = keys.items;
                repo.keys_trusted = allTrusted(arena, io, keys.items, &trusted_key_dirs);
                break;
            }
        }
        return repo;
    }
    return null;
}

/// The repository to use: `explicit` (`--repo PATH`) must exist and hold the
/// layout; otherwise the first of `repo_mounts` that does. Null if none.
pub fn findRepo(arena: Allocator, io: Io, explicit: ?[]const u8, arch: []const u8) RepoError!?Repo {
    if (explicit) |path| {
        if (!isDir(io, path)) return error.RepoMissing;
        return (try repoAt(arena, io, path, arch)) orelse error.RepoNoLayout;
    }
    for (repo_mounts) |m| {
        if (!isDir(io, m)) continue;
        if (try repoAt(arena, io, m, arch)) |r| return r;
    }
    return null;
}

/// Where public key files are looked for (mounted media, one level of
/// sub-directories too: /media/<label>/).
pub const key_roots = [_][]const u8{ "/mnt/cdrom", "/mnt/repo", "/mnt/usb", "/media", "/run/media" };

/// `*.pub` files directly in `roots` and one directory below them.
pub fn findPubFiles(arena: Allocator, io: Io, roots: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, e.name });
            if (e.kind == .file and std.mem.endsWith(u8, e.name, ".pub")) {
                try out.append(arena, path);
            } else if (e.kind == .directory) {
                var sub = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var it2 = sub.iterate();
                while (it2.next(io) catch null) |e2| {
                    if (e2.kind == .file and std.mem.endsWith(u8, e2.name, ".pub"))
                        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, e2.name }));
                }
            }
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

/// The first public key line in a key file (skips blanks and comments).
pub fn firstKeyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 0 and l[0] != '#') return l;
    }
    return null;
}

/// A block device that might hold a repository: not the target disk, not the
/// live medium, not mounted, with a filesystem a medium would have.
pub const RepoCandidate = struct {
    path: []const u8,
    fstype: []const u8,
    label: ?[]const u8,
    size: u64,
};

fn mediumFs(fs: ?[]const u8) bool {
    const f = fs orelse return false;
    for ([_][]const u8{ "iso9660", "vfat", "ext4", "exfat" }) |m| if (std.mem.eql(u8, f, m)) return true;
    return false;
}

/// Lists the devices the user may be offered (`target_disk` is never one).
pub fn repoCandidates(arena: Allocator, p: Probe, target_disk: []const u8) Allocator.Error![]const RepoCandidate {
    var out: std.ArrayList(RepoCandidate) = .empty;
    for (p.disks) |d| {
        if (std.mem.eql(u8, d.name, target_disk) or std.mem.eql(u8, d.path, target_disk)) continue;
        if (std.mem.startsWith(u8, d.name, "zram") or std.mem.startsWith(u8, d.name, "ram") or std.mem.startsWith(u8, d.name, "loop")) continue;
        if (p.holdsLiveMedium(d)) continue;
        if (!d.mounted and mediumFs(d.fstype)) try out.append(arena, .{ .path = d.path, .fstype = d.fstype.?, .label = d.label, .size = d.size });
        for (d.partitions) |q| {
            if (q.mounted or !mediumFs(q.fstype)) continue;
            if (p.live_medium_source) |src| if (std.mem.eql(u8, src, q.path)) continue;
            try out.append(arena, .{ .path = q.path, .fstype = q.fstype.?, .label = q.label, .size = q.size });
        }
    }
    return out.items;
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

fn hasChildren(obj: json.ObjectMap) bool {
    const ch = obj.get("children") orelse return false;
    return ch == .array and ch.array.items.len > 0;
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
        // A holder on top of the partition (LUKS, LVM, RAID, device-mapper) uses it, mounted or not.
        .mounted = hasMount(obj.get("mountpoints")) or hasMount(obj.get("mountpoint")) or hasChildren(obj),
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
        // A child of the disk that is not a partition holds the whole disk.
        var held = false;
        if (o.get("children")) |ch| if (ch == .array) {
            for (ch.array.items) |c| {
                if (c != .object) continue;
                const ty = str(c.object.get("type")) orelse "part";
                if (!std.mem.eql(u8, ty, "part")) {
                    held = true;
                    continue;
                }
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
            .mounted = hasMount(o.get("mountpoints")) or held,
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
        .services = try fixtureServices(arena, o.get("services")),
        .selinux = if (o.get("selinux")) |v| flag(v) else false,
        .live_user = str(o.get("live_user")) orelse "rescue",
        .accounts = try fixtureStrings(arena, o.get("accounts")),
        .net_ifaces = try fixtureIfaces(arena, o.get("net_ifaces")),
        .net_stack = if (str(o.get("net_stack"))) |t| (std.meta.stringToEnum(NetStack, t) orelse .none) else .none,
        .live_connections = try fixtureStrings(arena, o.get("live_connections")),
        .tools = try fixtureStrings(arena, o.get("tools")),
        .kernel_builtin = try fixtureStrings(arena, o.get("kernel_builtin")),
        .paths = try fixtureStrings(arena, o.get("paths")),
    };
}

fn fixtureStrings(arena: Allocator, v: ?json.Value) ![]const []const u8 {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (val.array.items) |it| if (it == .string) try out.append(arena, it.string);
    return out.items;
}

fn fixtureIfaces(arena: Allocator, v: ?json.Value) ![]const NetIface {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var out: std.ArrayList(NetIface) = .empty;
    for (val.array.items) |it| {
        if (it != .object) continue;
        const name = str(it.object.get("name")) orelse continue;
        try out.append(arena, .{ .name = name, .wireless = flag(it.object.get("wireless")) });
    }
    return out.items;
}

fn fixtureServices(arena: Allocator, v: ?json.Value) ![]const Service {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var out: std.ArrayList(Service) = .empty;
    for (val.array.items) |it| {
        if (it != .object) continue;
        const o = it.object;
        const name = str(o.get("name")) orelse continue;
        try out.append(arena, .{
            .name = name,
            .label = str(o.get("label")) orelse "",
            .enabled = flag(o.get("enabled")),
            .in_usr = flag(o.get("in_usr")),
            .network = inList(&network_services, name),
            .core = inList(&core_services, name) or std.mem.startsWith(u8, name, "tty"),
            .missing_dep = str(o.get("missing_dep")),
        });
    }
    return out.items;
}

// ---------------------------------------------------------------- live

const lsblk_columns = "NAME,PATH,TYPE,SIZE,MODEL,TRAN,RO,PTTYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTTYPE,MOUNTPOINTS";

fn readSmall(arena: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

/// Where the initrd mounts the system image, unchanged by the live session (docs/ISO-REQUIREMENTS.md).
const image_mount = "/run/live/rootfs";

fn readIn(arena: Allocator, io: Io, root: []const u8, path: []const u8) ?[]u8 {
    return readSmall(arena, io, std.fmt.allocPrint(arena, "{s}{s}", .{ root, path }) catch return null);
}

fn existsIn(arena: Allocator, io: Io, root: []const u8, path: []const u8) bool {
    return linkPresent(io, std.fmt.allocPrint(arena, "{s}{s}", .{ root, path }) catch return false);
}

fn linkPresent(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Reads the running machine.
pub fn live(arena: Allocator, io: Io) !Probe {
    // lsblk reads the ids from udev's database, which lags behind a table that
    // was just written (cfdisk). No udevadm, or a failure: blkid fills in below.
    _ = std.process.run(arena, io, .{ .argv = &.{ "udevadm", "settle", "--timeout=30" } }) catch {};
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

    // What the new system will be is what the image holds, not what the live session made of
    // it. Without the image mount, the running system is the closest thing.
    const image: []const u8 = if (exists(io, image_mount ++ "/etc/passwd")) image_mount else "";
    const services = try readServices(arena, io, image);
    const sfs = "/run/live/medium/live/rootfs.sfs";
    const is_live = exists(io, sfs);
    const kernel = if (is_live) findKernel(arena, io, sfs) else null;
    const firmware: Firmware = if (exists(io, "/sys/firmware/efi")) .uefi else .bios;
    return .{
        .firmware = firmware,
        .efivars_rw = efivars_rw,
        .is_live = is_live,
        .live_medium_source = medium,
        .rootfs_size = rootfs_size,
        .kernel = kernel,
        .disks = try checkEsps(arena, io, firmware, try fillMissingIds(arena, io, try parseLsblk(arena, lsblk.stdout))),
        .live_user = liveUser(arena, io, image),
        .accounts = try readAccounts(arena, io, image),
        .services = services,
        .selinux = existsIn(arena, io, image, "/etc/selinux/config"),
        .net_ifaces = try readNetIfaces(arena, io),
        .net_stack = detectStack(arena, io, image, services),
        .live_connections = try readConnections(arena, io),
        .tools = try liveTools(arena, io),
        .kernel_builtin = try kernelBuiltin(arena, io, image, kernel),
        .paths = try livePaths(arena, io),
    };
}

/// For each partition lsblk gave no PARTUUID, reads the disk itself with
/// `blkid -p` (needs root; without it the values stay missing).
fn fillMissingIds(arena: Allocator, io: Io, disks: []const Disk) ![]const Disk {
    const out = try arena.dupe(Disk, disks);
    for (out) |*disk| {
        const parts = try arena.dupe(Partition, disk.partitions);
        for (parts) |*part| {
            if (part.partuuid != null) continue;
            const r = std.process.run(arena, io, .{ .argv = &.{ "blkid", "-p", "-o", "export", part.path } }) catch continue;
            if (r.term.success()) applyBlkid(part, r.stdout);
        }
        disk.partitions = parts;
    }
    return out;
}

/// Where a FAT partition is mounted read-only to look at it.
const esp_check_dir = "/run/dkrescue-install/espcheck";

/// On UEFI, looks on each unmounted FAT partition for `EFI/BOOT/BOOTX64.EFI` (SPEC.md 5.6).
/// One that can't be mounted (no root, a damaged filesystem) stays unknown, and the plan then
/// assumes the file is there.
fn checkEsps(arena: Allocator, io: Io, firmware: Firmware, disks: []const Disk) ![]const Disk {
    if (firmware != .uefi) return disks;
    const out = try arena.dupe(Disk, disks);
    for (out) |*disk| {
        const parts = try arena.dupe(Partition, disk.partitions);
        disk.partitions = parts;
        for (parts) |*part| {
            if (part.mounted or !std.mem.eql(u8, part.fstype orelse "", "vfat")) continue;
            Io.Dir.cwd().createDirPath(io, esp_check_dir) catch return out;
            const m = std.process.run(arena, io, .{ .argv = &.{ "mount", "-t", "vfat", "-o", "ro", part.path, esp_check_dir } }) catch continue;
            if (!m.term.success()) continue;
            part.has_bootx64 = hasFileCaseless(io, esp_check_dir, &.{ "EFI", "BOOT", "BOOTX64.EFI" });
            const u = std.process.run(arena, io, .{ .argv = &.{ "umount", esp_check_dir } }) catch return out;
            // Mounting over a mount that stayed would show the wrong partition.
            if (!u.term.success()) return out;
        }
    }
    return out;
}

/// Whether `names` exists below `root`, ignoring case as FAT firmware does. Null if a
/// directory can't be read.
pub fn hasFileCaseless(io: Io, root: []const u8, names: []const []const u8) ?bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    for (names, 0..) |want, n| {
        var it = dir.iterate();
        var buf: [256]u8 = undefined;
        const found: []const u8 = while (it.next(io) catch return null) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, want) and e.name.len <= buf.len) {
                @memcpy(buf[0..e.name.len], e.name);
                break buf[0..e.name.len];
            }
        } else return false;
        if (n + 1 == names.len) return true;
        const sub_dir = dir.openDir(io, found, .{ .iterate = true }) catch return null;
        dir.close(io);
        dir = sub_dir;
    }
    return false;
}

/// Fills the fields `part` lacks from `blkid -p -o export` output.
fn applyBlkid(part: *Partition, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = std.mem.trim(u8, line[eq + 1 ..], " \r");
        if (value.len == 0) continue;
        const field: *?[]const u8 = if (std.mem.eql(u8, key, "PART_ENTRY_UUID"))
            &part.partuuid
        else if (std.mem.eql(u8, key, "PART_ENTRY_TYPE"))
            &part.parttype
        else if (std.mem.eql(u8, key, "TYPE"))
            &part.fstype
        else if (std.mem.eql(u8, key, "UUID"))
            &part.uuid
        else
            continue;
        if (field.* == null) field.* = value;
    }
}

/// The optional programs (`fs.candidate_tools`) that are in PATH on the live disc.
fn liveTools(arena: Allocator, io: Io) ![]const []const u8 {
    const dirs = [_][]const u8{ "/usr/sbin", "/usr/bin", "/sbin", "/bin" };
    var out: std.ArrayList([]const u8) = .empty;
    for (fs_mod.candidate_tools ++ bl_mod.candidate_tools) |tool| {
        for (dirs) |dir| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, tool });
            if (exists(io, path)) {
                try out.append(arena, tool);
                break;
            }
        }
    }
    return out.items;
}

/// The `bootloader.candidate_paths` that exist on the live disc.
fn livePaths(arena: Allocator, io: Io) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (bl_mod.candidate_paths) |path| if (exists(io, path)) try out.append(arena, path);
    return out.items;
}

/// Which of `fs.kernel_symbols` are `=y` in `/boot/config-<version>` of the live system
/// (the system image the new system is copied from has the same file). None if the
/// config is not there: nothing is then claimed to be built in.
fn kernelBuiltin(arena: Allocator, io: Io, root: []const u8, kernel: ?[]const u8) ![]const []const u8 {
    const k = kernel orelse return &.{};
    const prefix = "vmlinuz-";
    if (!std.mem.startsWith(u8, k, prefix)) return &.{};
    const path = try std.fmt.allocPrint(arena, "/boot/config-{s}", .{k[prefix.len..]});
    const text = readIn(arena, io, root, path) orelse return &.{};
    return builtinSymbols(arena, text);
}

/// The `fs.kernel_symbols` that a kernel config text has as `CONFIG_<name>=y`.
pub fn builtinSymbols(arena: Allocator, config: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (fs_mod.kernel_symbols) |sym| {
        const want = try std.fmt.allocPrint(arena, "CONFIG_{s}=y", .{sym});
        var lines = std.mem.splitScalar(u8, config, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), want)) {
                try out.append(arena, sym);
                break;
            }
        }
    }
    return out.items;
}

/// Finds the newest `boot/vmlinuz-*` inside the system image.
fn findKernel(arena: Allocator, io: Io, sfs: []const u8) ?[]const u8 {
    const r = std.process.run(arena, io, .{ .argv = &.{ "unsquashfs", "-l", sfs } }) catch return null;
    if (!r.term.success()) return null;
    return pickKernel(r.stdout);
}

/// The newest kernel in an `unsquashfs -l` listing, by version number. Backup copies are skipped.
pub fn pickKernel(listing: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    next: while (lines.next()) |line| {
        const marker = "/boot/vmlinuz-";
        const i = std.mem.indexOf(u8, line, marker) orelse continue;
        const name = line[i + "/boot/".len ..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        for ([_][]const u8{ ".old", ".bak", ".orig", ".dpkg-old", "~" }) |suffix| {
            if (std.mem.endsWith(u8, name, suffix)) continue :next;
        }
        if (best == null or versionOrder(name, best.?) == .gt) best = name;
    }
    return best;
}

/// Compares names with runs of digits taken as numbers (6.12 is newer than 6.9). A release
/// candidate is older than its release.
fn versionOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const si = i;
            const sj = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            const x = std.mem.trimStart(u8, a[si..i], "0");
            const y = std.mem.trimStart(u8, b[sj..j], "0");
            if (x.len != y.len) return std.math.order(x.len, y.len);
            const o = std.mem.order(u8, x, y);
            if (o != .eq) return o;
        } else {
            if (a[i] != b[j]) {
                if (std.mem.startsWith(u8, a[i..], "-rc")) return .lt;
                if (std.mem.startsWith(u8, b[j..], "-rc")) return .gt;
                return std.math.order(a[i], b[j]);
            }
            i += 1;
            j += 1;
        }
    }
    if (std.mem.startsWith(u8, a[i..], "-rc")) return .lt;
    if (std.mem.startsWith(u8, b[j..], "-rc")) return .gt;
    return std.math.order(a.len - i, b.len - j);
}

// ---------------------------------------------------------------- tests

test "min sizes" {
    // 3 GiB image -> 3.75 GiB + 0.5 GiB = 4.25 -> 5 GiB
    try std.testing.expectEqual(5 * GiB, minDiskSize(3 * GiB));
    try std.testing.expectEqual(5 * GiB - 512 * MiB, minRootSize(3 * GiB));
}

test "applyBlkid fills only what lsblk left out" {
    var part: Partition = .{ .name = "sda2", .path = "/dev/sda2", .number = 2, .size = 1, .fstype = "vfat" };
    applyBlkid(&part,
        \\DEVNAME=/dev/sda2
        \\UUID=ABCD-1234
        \\TYPE=ext4
        \\PART_ENTRY_UUID=1a2b3c4d-02
        \\PART_ENTRY_TYPE=0xef
        \\
    );
    try std.testing.expectEqualStrings("1a2b3c4d-02", part.partuuid.?);
    try std.testing.expectEqualStrings("0xef", part.parttype.?);
    try std.testing.expectEqualStrings("ABCD-1234", part.uuid.?);
    try std.testing.expectEqualStrings("vfat", part.fstype.?);
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

test "the live user is the first ordinary login" {
    try std.testing.expectEqualStrings("live", firstOrdinaryUser("root:x:0:0::/root:/bin/sh\ngreetd:x:995:995::/var/lib/greetd:/bin/nologin\nlive:x:1000:1000::/home/live:/bin/bash\n").?);
    try std.testing.expect(firstOrdinaryUser("root:x:0:0::/root:/bin/sh\nnobody:x:65534:65534::/:/bin/false\n") == null);
}

test "a service whose dependency is not in the image is detected" {
    const svcs = [_]Service{ .{ .name = "dbus" }, .{ .name = "cupsd" } };
    try std.testing.expectEqualStrings("avahi-daemon", missingDependency("type = process\ndepends-on: dbus\ndepends-on: avahi-daemon\n", &svcs).?);
    try std.testing.expect(missingDependency("depends-on = dbus\nwaits-for: cupsd\nafter: nothing\n", &svcs) == null);
}

test "builtinSymbols finds =y, not =m or unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const syms = try builtinSymbols(a, "CONFIG_EXT4_FS=y\nCONFIG_BTRFS_FS=y\nCONFIG_XFS_FS=m\n# CONFIG_F2FS_FS is not set\n");
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqualStrings("BTRFS_FS", syms[0]);
    const none = try builtinSymbols(a, "CONFIG_BTRFS_FS=m\n");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "a disk used through LUKS, LVM or RAID is in use" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const disks = try parseLsblk(st.allocator(),
        \\{"blockdevices":[
        \\{"name":"sda","type":"disk","size":1,"children":[{"name":"sda1","type":"part","size":1,
        \\  "children":[{"name":"home","type":"crypt","mountpoints":["/mnt/home"]}]}]},
        \\{"name":"sdb","type":"disk","size":1,"children":[{"name":"sdb1","type":"part","size":1,
        \\  "children":[{"name":"md0","type":"raid1","mountpoints":[null]}]}]},
        \\{"name":"sdc","type":"disk","size":1,"children":[{"name":"vg-root","type":"lvm","mountpoints":["/x"]}]},
        \\{"name":"sdd","type":"disk","size":1,"children":[{"name":"sdd1","type":"part","size":1,"mountpoints":[null]}]}]}
    );
    const p: Probe = .{ .firmware = .uefi, .efivars_rw = true, .is_live = true, .live_medium_source = null, .rootfs_size = null, .kernel = null, .disks = disks };
    for (disks[0..3]) |d| try std.testing.expectEqual(@as(?Ineligible, .mounted), ineligible(p, d, false));
    try std.testing.expectEqual(@as(?Ineligible, null), ineligible(p, disks[3], false));
}

test "BOOTX64.EFI is found whatever its case, and its absence is known" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", st.allocator());
    const want = [_][]const u8{ "EFI", "BOOT", "BOOTX64.EFI" };
    try std.testing.expectEqual(@as(?bool, false), hasFileCaseless(std.testing.io, root, &want));
    try tmp.dir.createDirPath(std.testing.io, "efi/Boot");
    try std.testing.expectEqual(@as(?bool, false), hasFileCaseless(std.testing.io, root, &want));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "efi/Boot/bootx64.efi", .data = "x" });
    try std.testing.expectEqual(@as(?bool, true), hasFileCaseless(std.testing.io, root, &want));
    try std.testing.expectEqual(@as(?bool, null), hasFileCaseless(std.testing.io, "/nonexistent-dk", &want));
}

test "the newest kernel is picked by version, not by string order" {
    const pick = struct {
        fn f(comptime names: []const []const u8) []const u8 {
            comptime var listing: []const u8 = "";
            inline for (names) |n| listing = listing ++ "squashfs-root/boot/" ++ n ++ "\n";
            return pickKernel(listing).?;
        }
    }.f;
    try std.testing.expectEqualStrings("vmlinuz-6.12.8", pick(&.{ "vmlinuz-6.9.1", "vmlinuz-6.12.8", "vmlinuz-6.12.7" }));
    try std.testing.expectEqualStrings("vmlinuz-6.12", pick(&.{ "vmlinuz-6.12", "vmlinuz-6.12.old", "vmlinuz-6.13.bak" }));
    try std.testing.expectEqualStrings("vmlinuz-6.13", pick(&.{ "vmlinuz-6.13-rc2", "vmlinuz-6.13" }));
    try std.testing.expectEqualStrings("vmlinuz-6.19-dkrescue", pick(&.{ "vmlinuz-6.19-dkrescue", "vmlinuz-6.2-dkrescue" }));
    try std.testing.expect(pickKernel("squashfs-root/boot/config-6.1\n") == null);
}

test "services and accounts are read from the image tree given" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.createDirPath(io, "etc/dinit.d/boot.d");
    try tmp.dir.createDirPath(io, "usr/lib/dinit.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/dinit.d/dk-test-sshd", .data = "type = process\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/dinit.d/dk-test-cups", .data = "type = process\n" });
    // An absolute link, as the image has for /usr/lib services: it points inside the image.
    try tmp.dir.symLink(io, "/usr/lib/dinit.d/dk-test-cups", "etc/dinit.d/boot.d/dk-test-cups", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/passwd", .data = "root:x:0:0::/root:/bin/sh\nimg:x:1000:1000::/home/img:/bin/sh\n" });
    const sv = try readServices(arena, io, root);
    try std.testing.expectEqual(@as(usize, 2), sv.len);
    try std.testing.expect(findService(sv, "dk-test-cups").?.enabled);
    try std.testing.expect(!findService(sv, "dk-test-sshd").?.enabled);
    try std.testing.expectEqualStrings("img", liveUser(arena, io, root));
}

test "a medium's key is trusted only when the system already has the same key" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const key = [_][]const u8{"tests/repos/with-sets/keys/fenriros.pub"};
    try std.testing.expect(allTrusted(arena, std.testing.io, &key, &.{"tests/repos/with-sets/keys"}));
    try std.testing.expect(!allTrusted(arena, std.testing.io, &key, &.{ "tests/keys", "/nonexistent-dk" }));
    try std.testing.expectEqual(@as(usize, 64), keyDigest(arena, std.testing.io, key[0]).len);
}

test "a missing dependency is found through the services in between, cycles included" {
    var svcs = [_]Service{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" }, .{ .name = "d" } };
    markMissingDependencies(&svcs, &.{ "depends-on: b\n", "waits-for: c\ndepends-on: a\n", "depends-ms = gone\n", "depends-on: d\n" });
    for (svcs[0..3]) |s| try std.testing.expectEqualStrings("gone", s.missing_dep.?);
    try std.testing.expect(svcs[3].missing_dep == null);
}
