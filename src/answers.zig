//! The user's choices, and the answers-file (TOML) parser.
//! Implements SPEC.md 5.3, 5.4, 6.1 and 7.
//!
//! File format: TOML, one table per section. The complete, commented example is
//! tests/auto/example.toml (also in docs/AUTOINSTALL.md). Sections:
//!
//!     [install]     disk, partitioning ("auto" or "existing"), root_fs, bootloader, confirm_erase, when_done
//!     [partitions]  root, esp, bios_boot, format_esp, set_esp_type, set_bios_boot_type
//!     [system]      hostname, domain, root_hash, user, user_hash, timezone, keymap,
//!                   ntp, firewall, selinux
//!     [services]    enable = ["name"], disable = ["name"]
//!     [ssh]         enable, root_login, password_auth, authorized_key, generate_key,
//!                   allow_lockout
//!     [network]     mode, copy, dns = [..], search, wifi_ssid, wifi_psk, wifi_hidden,
//!                   and one [[network.iface]] (name, kind, address, gateway) per interface
//!     [packages]    install = ["name"], keep_repo, trust_medium_key
//!     [post]        commands = ["sh -c command", ...]
//!
//! Passwords are crypt(3) hashes, never plain text. Unknown sections and keys
//! are errors. A syntax error reports line and column; a wrong value names its
//! section and key.

const std = @import("std");
const fs_mod = @import("fs.zig");
const bl_mod = @import("bootloader.zig");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

/// How the disk is partitioned (manual `cfdisk` ends up as `existing`).
pub const Partitioning = enum { auto, existing };

/// A password as given: an answers file holds only hashes; the screens
/// hold what was typed and pass it to `chpasswd` on standard input.
pub const Password = union(enum) {
    /// crypt(3) hash, `openssl passwd -6` format.
    hash: []const u8,
    /// Typed at the screens. Never printed or logged.
    plain: []const u8,
};

/// How the network is set up (SPEC.md 5.x, network).
pub const NetMode = enum {
    /// Per-interface DHCP / static / disabled, WiFi, DNS.
    guided,
    /// Copy the live session's NetworkManager connection.
    copy,
    /// Configure nothing; the network services are switched off.
    manual,
    /// Configure by hand in a shell chrooted into the target, during the
    /// install. Unattended runs only record the intent (no shell is opened).
    @"manual-shell",
};

pub const IfaceKind = enum { dhcp, static, disabled };

pub const Iface = struct {
    name: []const u8,
    kind: IfaceKind = .dhcp,
    /// `address/prefix`, IPv4 or IPv6 (static only).
    address: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
};

pub const Wifi = struct {
    ssid: []const u8,
    /// Never printed, logged or shown.
    psk: []const u8,
    hidden: bool = false,
};

pub const Network = struct {
    mode: NetMode = .guided,
    /// copy: file name in the live /etc/NetworkManager/system-connections.
    copy: ?[]const u8 = null,
    ifaces: []const Iface = &.{},
    dns: []const []const u8 = &.{},
    search: ?[]const u8 = null,
    wifi: ?Wifi = null,
};

fn ipv4(s: []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |o| : (n += 1) {
        if (o.len == 0 or o.len > 3) return false;
        const v = std.fmt.parseInt(u16, o, 10) catch return false;
        if (v > 255) return false;
    }
    return n == 4;
}

fn ipv6(s: []const u8) bool {
    if (s.len < 2 or s.len > 45 or std.mem.count(u8, s, ":") < 2) return false;
    var dbl: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "::")) |at| : (i = at + 1) dbl += 1;
    if (dbl > 1) return false;
    var groups: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |g| {
        if (g.len == 0) continue;
        if (g.len > 4) return false;
        for (g) |c| if (!std.ascii.isHex(c)) return false;
        groups += 1;
    }
    return if (dbl == 1) groups <= 7 else groups == 8;
}

/// An IPv4 or IPv6 address.
pub fn validIp(s: []const u8) bool {
    return ipv4(s) or ipv6(s);
}

/// `ADDRESS/PREFIX`.
pub fn validCidr(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const addr = s[0..slash];
    const prefix = std.fmt.parseInt(u8, s[slash + 1 ..], 10) catch return false;
    if (ipv4(addr)) return prefix >= 1 and prefix <= 32;
    if (ipv6(addr)) return prefix >= 1 and prefix <= 128;
    return false;
}

pub fn isV6(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') != null;
}

/// A kernel interface name.
pub fn validIfaceName(n: []const u8) bool {
    if (n.len == 0 or n.len > 15) return false;
    for (n) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

/// 1-32 printable ASCII characters, no backslash or double quote (they would
/// need escaping in both NetworkManager and wpa_supplicant files).
pub fn validSsid(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    for (s) |c| if (c < 0x20 or c > 0x7e or c == '\\' or c == '"') return false;
    return true;
}

/// A WPA passphrase: 8-63 printable ASCII characters, same restriction.
pub fn validPsk(s: []const u8) bool {
    if (s.len < 8 or s.len > 63) return false;
    for (s) |c| if (c < 0x20 or c > 0x7e or c == '\\' or c == '"') return false;
    return true;
}

/// What an autoinstall does at the end.
pub const WhenDone = enum { reboot, poweroff, shell };

pub const SelinuxMode = enum { permissive, enforcing, disabled };

pub const RootLogin = enum {
    no,
    @"prohibit-password",
    yes,
};

/// The SSH screen's answers.
pub const Ssh = struct {
    /// Null: leave the service as the image has it.
    enable: ?bool = null,
    root_login: RootLogin = .no,
    password_auth: bool = true,
    /// A public key line for the new user's authorized_keys.
    authorized_key: ?[]const u8 = null,
    /// Generate an ed25519 pair for the user and authorize it.
    generate_key: bool = false,
    /// Accept `password_auth = false` with no key (locks everyone out of ssh).
    allow_lockout: bool = false,
};

/// A one-line OpenSSH public key: `type base64 [comment]`. The UI also runs
/// `ssh-keygen -l -f` on it; this catches what must never reach a file.
pub fn validPubKey(k: []const u8) bool {
    if (std.mem.indexOfAny(u8, k, "\n\r") != null) return false;
    var it = std.mem.tokenizeScalar(u8, k, ' ');
    const kind = it.next() orelse return false;
    const body = it.next() orelse return false;
    if (!(std.mem.startsWith(u8, kind, "ssh-") or std.mem.startsWith(u8, kind, "ecdsa-") or std.mem.startsWith(u8, kind, "sk-"))) return false;
    for (body) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/' and c != '=') return false;
    return body.len >= 16;
}

/// Everything the user decides.
pub const Answers = struct {
    /// Kernel name of the target disk, e.g. "nvme0n1".
    disk: []const u8,
    partitioning: Partitioning,
    /// The root filesystem (SPEC.md 5.3.4): ext4 by default.
    root_fs: fs_mod.Fs = .ext4,
    /// The boot loader (SPEC.md 5.6.8): dklilo by default.
    bootloader: bl_mod.Bootloader = .dklilo,
    /// Existing path: root partition, ESP and BIOS boot partition names.
    root: ?[]const u8 = null,
    esp: ?[]const u8 = null,
    bios_boot: ?[]const u8 = null,
    /// Format the (existing) ESP. Root is always formatted.
    format_esp: bool = false,
    /// Rewrite the partition type of the chosen ESP / BIOS boot partition.
    set_esp_type: bool = false,
    set_bios_boot_type: bool = false,
    hostname: []const u8 = "dkrescue",
    root_pw: Password,
    user: []const u8,
    user_pw: Password,
    timezone: []const u8 = "UTC",
    keymap: ?[]const u8 = null,
    /// Autoinstall: the disk (path, kernel name or by-id link) the file allows to be erased.
    confirm_erase: ?[]const u8 = null,
    when_done: WhenDone = .reboot,
    /// Commands run with `sh -c` in the new system, after configuration (soft).
    post: []const []const u8 = &.{},
    /// Domain name for /etc/hosts (host.domain); null: none.
    domain: ?[]const u8 = null,
    /// Null: the network screen was skipped; nothing is configured.
    network: ?Network = null,
    /// Null: as the image has it.
    ntp: ?bool = null,
    firewall: ?bool = null,
    selinux: ?SelinuxMode = null,
    /// Services to switch on or off (names from the image), on top of the above.
    services_enable: []const []const u8 = &.{},
    services_disable: []const []const u8 = &.{},
    /// Null: the SSH screen was not used; nothing about sshd is written.
    ssh: ?Ssh = null,
    /// Extra packages to install from the repository medium (empty: none).
    packages: []const []const u8 = &.{},
    /// Leave a (commented-out) line for the repository in the new system.
    keep_repo: bool = false,
    /// Accept a repository signed with a key the system does not already trust.
    trust_medium_key: bool = false,
};

/// Where and why parsing failed.
pub const Diag = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// RFC 1123 hostname: dot-separated labels of 1-63 letters, digits and
/// hyphens, none starting or ending with a hyphen; 253 characters at most.
pub fn validHostname(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63) return false;
        if (l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// `useradd`'s default rule: `[a-z_][a-z0-9_-]*$?`, 32 characters at most.
pub fn validUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    const body = if (name[name.len - 1] == '$') name[0 .. name.len - 1] else name;
    if (body.len == 0) return false;
    if (!(std.ascii.isLower(body[0]) or body[0] == '_')) return false;
    for (body[1..]) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// A crypt(3) hash such as `$6$salt$hash`. Rejects anything that is
/// obviously a plain-text password.
pub fn validHash(h: []const u8) bool {
    if (h.len < 8 or h[0] != '$') return false;
    const second = std.mem.indexOfScalarPos(u8, h, 1, '$') orelse return false;
    if (second == 1) return false;
    return std.mem.indexOfScalarPos(u8, h, second + 1, '$') != null;
}

/// Zone names are relative paths under /usr/share/zoneinfo.
pub fn validTimezone(tz: []const u8) bool {
    if (tz.len == 0 or tz[0] == '/' or tz[0] == '.' or tz[tz.len - 1] == '/') return false;
    if (std.mem.indexOf(u8, tz, "..") != null) return false;
    for (tz) |c| if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '_' and c != '-' and c != '+') return false;
    return true;
}

/// A keymap name `loadkeys` can find under /usr/share/keymaps: letters,
/// digits and `. _ - +`, not starting with `-` (it would read as an option).
pub fn validKeymap(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-' and c != '+') return false;
    return true;
}

/// A dinit service name: a file name in /etc/dinit.d.
pub fn validServiceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-' or name[0] == '.') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '+' and c != '-' and c != '@') return false;
    return true;
}

/// An apk package name, as typed: letters, digits and `. _ + -`, not starting
/// with `-` (it would read as an option).
pub fn validPackageName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '-') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '+' and c != '-') return false;
    return true;
}

/// Parses an answers file (TOML). Strings are copied into `arena`. On
/// failure `diag.message` says what was wrong: the line and column for a
/// syntax error, the section and key for a wrong value.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diag) !Answers {
    var tdiag: toml.Diagnostic = .{};
    const doc = toml.Document.parse(arena, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.line = tdiag.line;
            return fail(diag, try std.fmt.allocPrint(arena, "column {d}: {s}", .{ tdiag.column, tdiag.message }));
        },
    };
    const root = doc.root;
    var p: Parser = .{ .arena = arena, .diag = diag };
    try p.only(root, &.{ "install", "partitions", "system", "services", "ssh", "network", "packages", "post" }, "");

    var a: Answers = .{
        .disk = "",
        .partitioning = .auto,
        .root_pw = .{ .hash = "" },
        .user = "",
        .user_pw = .{ .hash = "" },
    };

    const install = try p.section(root, "install") orelse return fail(diag, "[install] is required");
    try p.only(install, &.{ "disk", "partitioning", "root_fs", "bootloader", "confirm_erase", "when_done" }, "install");
    a.disk = try p.str(install, "install", "disk") orelse return fail(diag, "[install] disk is required");
    a.partitioning = try p.enumv(Partitioning, install, "install", "partitioning", "auto or existing") orelse
        return fail(diag, "[install] partitioning is required");
    if (try p.str(install, "install", "confirm_erase")) |v| {
        if (v.len == 0 or v[0] != '/' and !validIfaceName(v)) return fail(diag, "confirm_erase must be a device path or a kernel name");
        a.confirm_erase = v;
    }
    if (try p.enumv(WhenDone, install, "install", "when_done", "reboot, poweroff or shell")) |v| a.when_done = v;
    if (try p.enumv(fs_mod.Fs, install, "install", "root_fs", "ext4, ext3, ext2, btrfs, xfs or zfs")) |v| a.root_fs = v;
    if (try p.enumv(bl_mod.Bootloader, install, "install", "bootloader", "dklilo, grub or systemd-boot")) |v| a.bootloader = v;

    if (try p.section(root, "partitions")) |t| {
        try p.only(t, &.{ "root", "esp", "bios_boot", "format_esp", "set_esp_type", "set_bios_boot_type" }, "partitions");
        a.root = try p.str(t, "partitions", "root");
        a.esp = try p.str(t, "partitions", "esp");
        a.bios_boot = try p.str(t, "partitions", "bios_boot");
        if (try p.boolean(t, "partitions", "format_esp")) |v| a.format_esp = v;
        if (try p.boolean(t, "partitions", "set_esp_type")) |v| a.set_esp_type = v;
        if (try p.boolean(t, "partitions", "set_bios_boot_type")) |v| a.set_bios_boot_type = v;
    }

    const sys = try p.section(root, "system") orelse return fail(diag, "[system] is required");
    try p.only(sys, &.{ "hostname", "domain", "root_hash", "user", "user_hash", "timezone", "keymap", "ntp", "firewall", "selinux" }, "system");
    if (try p.str(sys, "system", "hostname")) |v| {
        if (!validHostname(v)) return fail(diag, "invalid hostname");
        a.hostname = v;
    }
    if (try p.str(sys, "system", "domain")) |v| {
        if (!validHostname(v)) return fail(diag, "invalid domain");
        a.domain = v;
    }
    const root_hash = try p.str(sys, "system", "root_hash") orelse return fail(diag, "[system] root_hash is required");
    if (!validHash(root_hash)) return fail(diag, "root_hash is not a crypt hash (passwords are never plain text)");
    a.root_pw = .{ .hash = root_hash };
    a.user = try p.str(sys, "system", "user") orelse return fail(diag, "[system] user is required");
    if (!validUsername(a.user)) return fail(diag, "invalid user name");
    const user_hash = try p.str(sys, "system", "user_hash") orelse return fail(diag, "[system] user_hash is required");
    if (!validHash(user_hash)) return fail(diag, "user_hash is not a crypt hash (passwords are never plain text)");
    a.user_pw = .{ .hash = user_hash };
    if (try p.str(sys, "system", "timezone")) |v| {
        if (!validTimezone(v)) return fail(diag, "invalid timezone");
        a.timezone = v;
    }
    if (try p.str(sys, "system", "keymap")) |v| {
        if (!validKeymap(v)) return fail(diag, "invalid keymap name");
        a.keymap = v;
    }
    a.ntp = try p.boolean(sys, "system", "ntp");
    a.firewall = try p.boolean(sys, "system", "firewall");
    a.selinux = try p.enumv(SelinuxMode, sys, "system", "selinux", "permissive, enforcing or disabled");

    if (try p.section(root, "services")) |t| {
        try p.only(t, &.{ "enable", "disable" }, "services");
        a.services_enable = try p.strings(t, "services", "enable", validServiceName, "invalid service name");
        a.services_disable = try p.strings(t, "services", "disable", validServiceName, "invalid service name");
    }

    if (try p.section(root, "ssh")) |t| {
        try p.only(t, &.{ "enable", "root_login", "password_auth", "authorized_key", "generate_key", "allow_lockout" }, "ssh");
        var s: Ssh = .{};
        s.enable = try p.boolean(t, "ssh", "enable");
        if (try p.enumv(RootLogin, t, "ssh", "root_login", "no, prohibit-password or yes")) |v| s.root_login = v;
        if (try p.boolean(t, "ssh", "password_auth")) |v| s.password_auth = v;
        if (try p.str(t, "ssh", "authorized_key")) |v| {
            if (!validPubKey(v)) return fail(diag, "authorized_key is not an OpenSSH public key line");
            s.authorized_key = v;
        }
        if (try p.boolean(t, "ssh", "generate_key")) |v| s.generate_key = v;
        if (try p.boolean(t, "ssh", "allow_lockout")) |v| s.allow_lockout = v;
        a.ssh = s;
    }

    if (try p.section(root, "network")) |t| {
        try p.only(t, &.{ "mode", "copy", "iface", "dns", "search", "wifi_ssid", "wifi_psk", "wifi_hidden" }, "network");
        var n: Network = .{};
        if (try p.enumv(NetMode, t, "network", "mode", "guided, copy, manual or manual-shell")) |v| n.mode = v;
        if (try p.str(t, "network", "copy")) |v| {
            if (v.len == 0 or std.mem.indexOfScalar(u8, v, '/') != null or v[0] == '.') return fail(diag, "invalid connection file name");
            n.copy = v;
        }
        if (t.get("iface")) |v| {
            const arr = switch (v) {
                .array => |x| x,
                else => return fail(diag, "[network] iface must be an array of tables: [[network.iface]]"),
            };
            var list: std.ArrayList(Iface) = .empty;
            for (arr.items.items) |item| {
                const it = switch (item) {
                    .table => |x| x,
                    else => return fail(diag, "[network] iface entries must be tables: [[network.iface]]"),
                };
                try p.only(it, &.{ "name", "kind", "address", "gateway" }, "network.iface");
                const name = try p.str(it, "network.iface", "name") orelse return fail(diag, "[[network.iface]] needs a name");
                if (!validIfaceName(name)) return fail(diag, "invalid interface name");
                var ifc: Iface = .{ .name = name };
                ifc.kind = try p.enumv(IfaceKind, it, "network.iface", "kind", "dhcp, static or disabled") orelse
                    return fail(diag, "[[network.iface]] needs kind = dhcp, static or disabled");
                const addr = try p.str(it, "network.iface", "address");
                const gw = try p.str(it, "network.iface", "gateway");
                if (ifc.kind == .static) {
                    const ad = addr orelse return fail(diag, "a static interface needs address = \"ADDRESS/PREFIX\"");
                    if (!validCidr(ad)) return fail(diag, "invalid ADDRESS/PREFIX");
                    ifc.address = ad;
                    if (gw) |g| {
                        if (!validIp(g) or isV6(g) != isV6(ad)) return fail(diag, "invalid gateway (same family as the address)");
                        ifc.gateway = g;
                    }
                } else if (addr != null or gw != null) return fail(diag, "address and gateway are only for kind = static");
                try list.append(arena, ifc);
            }
            n.ifaces = list.items;
        }
        n.dns = try p.strings(t, "network", "dns", validIp, "invalid DNS server address");
        if (try p.str(t, "network", "search")) |v| {
            if (!validHostname(v)) return fail(diag, "invalid search domain");
            n.search = v;
        }
        const ssid = try p.str(t, "network", "wifi_ssid");
        const psk = try p.str(t, "network", "wifi_psk");
        if (ssid) |v| if (!validSsid(v)) return fail(diag, "invalid SSID (1-32 printable characters, no backslash or quote)");
        if (psk) |v| if (!validPsk(v)) return fail(diag, "invalid WiFi passphrase (8-63 printable characters, no backslash or quote)");
        if ((ssid == null) != (psk == null)) return fail(diag, "[network] wifi_ssid and wifi_psk go together");
        if (ssid) |sid| n.wifi = .{ .ssid = sid, .psk = psk.?, .hidden = try p.boolean(t, "network", "wifi_hidden") orelse false };
        if (n.mode == .copy and n.copy == null) return fail(diag, "[network] mode = copy needs copy = FILE");
        a.network = n;
    }

    if (try p.section(root, "packages")) |t| {
        try p.only(t, &.{ "install", "keep_repo", "trust_medium_key" }, "packages");
        a.packages = try p.strings(t, "packages", "install", validPackageName, "invalid package name");
        if (try p.boolean(t, "packages", "keep_repo")) |v| a.keep_repo = v;
        if (try p.boolean(t, "packages", "trust_medium_key")) |v| a.trust_medium_key = v;
    }

    if (try p.section(root, "post")) |t| {
        try p.only(t, &.{"commands"}, "post");
        a.post = try p.strings(t, "post", "commands", nonEmpty, "empty command");
    }

    if (a.partitioning == .existing and a.root == null) return fail(diag, "[partitions] root is required for existing partitioning");
    return a;
}

fn nonEmpty(s: []const u8) bool {
    return s.len != 0;
}

/// Reads typed values out of the parsed document, with errors that name the
/// section and key.
const Parser = struct {
    arena: Allocator,
    diag: *Diag,

    fn bad(self: Parser, comptime fmt: []const u8, args: anytype) error{ BadAnswers, OutOfMemory } {
        return fail(self.diag, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn only(self: Parser, t: *const toml.Table, known: []const []const u8, what: []const u8) !void {
        for (t.entries.keys()) |k| {
            const ok = for (known) |n| {
                if (std.mem.eql(u8, k, n)) break true;
            } else false;
            if (ok) continue;
            if (what.len == 0) return self.bad("unknown section '{s}'", .{k});
            return self.bad("unknown key '{s}' in [{s}]", .{ k, what });
        }
    }

    fn section(self: Parser, t: *const toml.Table, name: []const u8) !?*const toml.Table {
        const v = t.get(name) orelse return null;
        return switch (v) {
            .table => |x| x,
            else => self.bad("'{s}' must be a [{s}] section", .{ name, name }),
        };
    }

    fn str(self: Parser, t: *const toml.Table, sec: []const u8, key: []const u8) !?[]const u8 {
        const v = t.get(key) orelse return null;
        return switch (v) {
            .string => |s| try self.arena.dupe(u8, s),
            else => self.bad("[{s}] {s} must be a string, not {s}", .{ sec, key, v.typeName() }),
        };
    }

    fn boolean(self: Parser, t: *const toml.Table, sec: []const u8, key: []const u8) !?bool {
        const v = t.get(key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => self.bad("[{s}] {s} must be true or false, not {s}", .{ sec, key, v.typeName() }),
        };
    }

    fn enumv(self: Parser, comptime E: type, t: *const toml.Table, sec: []const u8, key: []const u8, choices: []const u8) !?E {
        const s = try self.str(t, sec, key) orelse return null;
        return std.meta.stringToEnum(E, s) orelse self.bad("[{s}] {s} must be {s}", .{ sec, key, choices });
    }

    /// A list of strings, each checked by `ok`; absent means empty.
    fn strings(self: Parser, t: *const toml.Table, sec: []const u8, key: []const u8, ok: *const fn ([]const u8) bool, msg: []const u8) ![]const []const u8 {
        const v = t.get(key) orelse return &.{};
        const arr = switch (v) {
            .array => |x| x,
            else => return self.bad("[{s}] {s} must be a list of strings, not {s}", .{ sec, key, v.typeName() }),
        };
        const out = try self.arena.alloc([]const u8, arr.items.items.len);
        for (arr.items.items, out) |item, *dst| {
            const s = switch (item) {
                .string => |x| x,
                else => return self.bad("[{s}] {s} entries must be strings, not {s}", .{ sec, key, item.typeName() }),
            };
            if (!ok(s)) return self.bad("[{s}] {s}: {s}: '{s}'", .{ sec, key, msg, s });
            dst.* = try self.arena.dupe(u8, s);
        }
        return out;
    }
};

fn fail(diag: *Diag, msg: []const u8) error{BadAnswers} {
    diag.message = msg;
    return error.BadAnswers;
}

test "validators" {
    try std.testing.expect(validHostname("dkrescue"));
    try std.testing.expect(validHostname("a-b.example"));
    try std.testing.expect(!validHostname("-a"));
    try std.testing.expect(!validHostname("a_b"));
    try std.testing.expect(!validHostname(""));
    try std.testing.expect(validUsername("dakota"));
    try std.testing.expect(validUsername("_x-1$"));
    try std.testing.expect(!validUsername("Dakota"));
    try std.testing.expect(!validUsername("1abc"));
    try std.testing.expect(validHash("$6$salt$abcdef"));
    try std.testing.expect(!validHash("hunter2"));
    try std.testing.expect(validTimezone("Europe/Berlin"));
    try std.testing.expect(!validTimezone("../etc/passwd"));
}

test "parse a full answers file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const a = try parse(arena_state.allocator(),
        \\[install]
        \\disk = "sda"
        \\partitioning = "existing"
        \\[partitions]
        \\root = "sda3"
        \\esp = "sda2"
        \\format_esp = true
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
        \\timezone = "Europe/Berlin"
    , &diag);
    try std.testing.expectEqualStrings("sda", a.disk);
    try std.testing.expectEqual(Partitioning.existing, a.partitioning);
    try std.testing.expect(a.format_esp);
    try std.testing.expectEqualStrings("dkrescue", a.hostname);
    try std.testing.expectEqualStrings("Europe/Berlin", a.timezone);
}

test "root_fs: default ext4; a name from the list; anything else is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tail =
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
    ;
    var diag: Diag = .{};
    const d = try parse(arena, "[install]\ndisk = \"sda\"\npartitioning = \"auto\"\n" ++ tail, &diag);
    try std.testing.expectEqual(fs_mod.Fs.ext4, d.root_fs);
    const b = try parse(arena, "[install]\ndisk = \"sda\"\npartitioning = \"auto\"\nroot_fs = \"btrfs\"\n" ++ tail, &diag);
    try std.testing.expectEqual(fs_mod.Fs.btrfs, b.root_fs);
    try std.testing.expectError(error.BadAnswers, parse(arena, "[install]\ndisk = \"sda\"\npartitioning = \"auto\"\nroot_fs = \"ntfs\"\n" ++ tail, &diag));
}

test "parse the packages section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const base =
        \\[install]
        \\disk = "sda"
        \\partitioning = "auto"
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
        \\[packages]
        \\install = ["nano", "htop", "git"]
        \\keep_repo = true
    ;
    const a = try parse(arena_state.allocator(), base, &diag);
    try std.testing.expectEqual(@as(usize, 3), a.packages.len);
    try std.testing.expectEqualStrings("htop", a.packages[1]);
    try std.testing.expect(a.keep_repo);
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(), base ++ "\ninstall = -oops", &diag));
    try std.testing.expect(!validPackageName("--root"));
    try std.testing.expect(validPackageName("libstdc++"));
}

test "parse services, ssh and the optional system keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const a = try parse(arena_state.allocator(),
        \\[install]
        \\disk = "sda"
        \\partitioning = "auto"
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
        \\ntp = false
        \\firewall = true
        \\selinux = "enforcing"
        \\[services]
        \\enable = ["cupsd"]
        \\disable = ["avahi-daemon", "bluetoothd"]
        \\[ssh]
        \\enable = true
        \\root_login = "prohibit-password"
        \\password_auth = false
        \\authorized_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@host"
    , &diag);
    try std.testing.expectEqual(false, a.ntp.?);
    try std.testing.expectEqual(SelinuxMode.enforcing, a.selinux.?);
    try std.testing.expectEqual(@as(usize, 2), a.services_disable.len);
    try std.testing.expectEqual(RootLogin.@"prohibit-password", a.ssh.?.root_login);
    try std.testing.expect(!a.ssh.?.password_auth);
    try std.testing.expect(a.ssh.?.authorized_key != null);
    try std.testing.expect(!validPubKey("ssh-rsa"));
    try std.testing.expect(!validPubKey("hello world AAAAAAAAAAAAAAAAAAAA"));
}

test "network validators and section" {
    try std.testing.expect(validCidr("192.168.1.5/24"));
    try std.testing.expect(!validCidr("192.168.1.5"));
    try std.testing.expect(!validCidr("300.1.1.1/24"));
    try std.testing.expect(validCidr("2001:db8::5/64"));
    try std.testing.expect(!validCidr("2001:db8::5::1/64"));
    try std.testing.expect(validIp("::1") and validIp("9.9.9.9") and !validIp("host"));
    try std.testing.expect(validPsk("password1") and !validPsk("short") and !validSsid("a\"b"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const a = try parse(arena_state.allocator(),
        \\[install]
        \\disk = "sda"
        \\partitioning = "auto"
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
        \\domain = "example.org"
        \\[network]
        \\dns = ["1.1.1.1", "9.9.9.9"]
        \\wifi_ssid = "Home"
        \\wifi_psk = "hunter2hunter2"
        \\
        \\[[network.iface]]
        \\name = "eth0"
        \\kind = "static"
        \\address = "192.168.1.5/24"
        \\gateway = "192.168.1.1"
        \\
        \\[[network.iface]]
        \\name = "eth1"
        \\kind = "disabled"
        \\
    , &diag);
    try std.testing.expectEqual(@as(usize, 2), a.network.?.ifaces.len);
    try std.testing.expectEqual(IfaceKind.static, a.network.?.ifaces[0].kind);
    try std.testing.expectEqualStrings("Home", a.network.?.wifi.?.ssid);
    try std.testing.expectEqualStrings("example.org", a.domain.?);
}

test "autoinstall keys and post commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const a = try parse(arena_state.allocator(),
        \\[install]
        \\disk = "largest"
        \\partitioning = "auto"
        \\confirm_erase = "/dev/disk/by-id/nvme-X"
        \\when_done = "poweroff"
        \\[system]
        \\root_hash = "$6$salt$roothash"
        \\user = "dakota"
        \\user_hash = "$6$salt$userhash"
        \\[post]
        \\commands = ["echo one > /etc/one", "echo two > /etc/two"]
    , &diag);
    try std.testing.expectEqualStrings("largest", a.disk);
    try std.testing.expectEqualStrings("/dev/disk/by-id/nvme-X", a.confirm_erase.?);
    try std.testing.expectEqual(WhenDone.poweroff, a.when_done);
    try std.testing.expectEqual(@as(usize, 2), a.post.len);
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(), "[install]\nwhen_done = explode\n", &diag));
}

test "parse rejects plain-text passwords and names the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(),
        \\[install]
        \\disk = "sda"
        \\partitioning = "auto"
        \\[system]
        \\root_hash = "hunter2"
    , &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "root_hash") != null);
    // A syntax error carries the line; a wrong value names the section and key instead.
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(), "[install]\ndisk = \n", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
}
