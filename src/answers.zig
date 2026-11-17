//! The user's choices, and the answers-file (INI) parser.
//! Implements SPEC.md 5.3, 5.4, 6.1 and 7.
//!
//! File format:
//!
//!     [install]
//!     disk = nvme0n1
//!     partitioning = auto            # or: existing
//!     confirm_erase = /dev/nvme0n1   # autoinstall: must name the disk that is erased
//!     when_done = reboot             # autoinstall: reboot, poweroff or shell
//!
//!     [partitions]                   # existing only
//!     root = nvme0n1p3
//!     esp = nvme0n1p2
//!     bios_boot = nvme0n1p1
//!     format_esp = false
//!     set_esp_type = false
//!     set_bios_boot_type = false
//!
//!     [system]
//!     hostname = dkrescue
//!     root_hash = $6$...
//!     user = dakota
//!     user_hash = $6$...
//!     timezone = UTC
//!     keymap = us
//!
//!     ntp = true                     # optional: NTP service on/off (omitted: as the image has it)
//!     firewall = true                # optional: firewalld on/off
//!     selinux = permissive           # optional: permissive, enforcing or disabled
//!
//!     [services]                     # optional: switch dinit services (omitted: as the image has them)
//!     enable = cupsd
//!     disable = avahi-daemon
//!
//!     [ssh]                          # optional: absent = leave sshd as the image has it
//!     enable = true
//!     root_login = no                # no, prohibit-password or yes
//!     password_auth = false
//!     authorized_key = ssh-ed25519 AAAA... user@host   # for the new user
//!     generate_key = false           # make an ed25519 pair for the user
//!     allow_lockout = false          # allow password_auth = false with no key
//!
//!     domain = example.org           # optional: hosts gets host.domain
//!
//!     [network]                      # optional: absent = nothing configured, as the image defaults
//!     mode = guided                  # guided, copy (the live session's connection), manual (nothing, services off)
//!                                    # or manual-shell (a chroot shell during the install; unattended: skipped)
//!     copy = Wired connection 1      # mode = copy: a file in the live /etc/NetworkManager/system-connections
//!     iface = eth0 dhcp              # repeatable: NAME dhcp | disabled | static ADDR/PREFIX [GATEWAY]
//!     iface = eth1 static 192.168.1.5/24 192.168.1.1
//!     dns = 1.1.1.1 2606:4700:4700::1111
//!     search = example.org
//!     wifi_ssid = Home               # WiFi: the passphrase is never printed or logged
//!     wifi_psk = correct horse battery
//!     wifi_hidden = false
//!
//!     [post]                         # optional: commands run in the new system, last
//!     commands = echo hello > /etc/motd   # repeatable; each runs with sh -c in a chroot (no /proc); a failure is a warning
//!
//!     [packages]                     # optional: from the repository medium
//!     install = nano htop            # package names, space separated
//!     keep_repo = false              # leave the repository, commented out, in /etc/apk/repositories

const std = @import("std");
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
    if (tz.len == 0 or tz[0] == '/' or tz[0] == '.') return false;
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

fn parseBool(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "0")) return false;
    return null;
}

/// Parses an answers file. Strings are copied into `arena`. On failure
/// `diag` says which line was wrong.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diag) !Answers {
    var disk: ?[]const u8 = null;
    var partitioning: ?Partitioning = null;
    var a: Answers = .{
        .disk = "",
        .partitioning = .auto,
        .root_pw = .{ .hash = "" },
        .user = "",
        .user_pw = .{ .hash = "" },
    };
    var have_root_hash = false;
    var have_user = false;
    var have_user_hash = false;
    var ssh_v: Ssh = .{};
    var ssh_seen = false;
    var post: std.ArrayList([]const u8) = .empty;
    var net_v: Network = .{};
    var net_seen = false;
    var ifaces: std.ArrayList(Iface) = .empty;
    var wifi_ssid: ?[]const u8 = null;
    var wifi_psk: ?[]const u8 = null;
    var wifi_hidden = false;

    var section: []const u8 = "";
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        diag.line = line_no;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return fail(diag, "unterminated section header");
            section = line[1 .. line.len - 1];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail(diag, "expected key = value");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        line = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = try arena.dupe(u8, line);

        if (std.mem.eql(u8, section, "install")) {
            if (std.mem.eql(u8, key, "disk")) {
                disk = value;
            } else if (std.mem.eql(u8, key, "partitioning")) {
                partitioning = std.meta.stringToEnum(Partitioning, value) orelse
                    return fail(diag, "partitioning must be auto or existing");
            } else if (std.mem.eql(u8, key, "confirm_erase")) {
                if (value.len == 0 or value[0] != '/' and !validIfaceName(value)) return fail(diag, "confirm_erase must be a device path or a kernel name");
                a.confirm_erase = value;
            } else if (std.mem.eql(u8, key, "when_done")) {
                a.when_done = std.meta.stringToEnum(WhenDone, value) orelse return fail(diag, "when_done must be reboot, poweroff or shell");
            } else return fail(diag, "unknown key in [install]");
        } else if (std.mem.eql(u8, section, "partitions")) {
            if (std.mem.eql(u8, key, "root")) {
                a.root = value;
            } else if (std.mem.eql(u8, key, "esp")) {
                a.esp = value;
            } else if (std.mem.eql(u8, key, "bios_boot")) {
                a.bios_boot = value;
            } else if (std.mem.eql(u8, key, "format_esp")) {
                a.format_esp = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "set_esp_type")) {
                a.set_esp_type = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "set_bios_boot_type")) {
                a.set_bios_boot_type = parseBool(value) orelse return fail(diag, "expected true or false");
            } else return fail(diag, "unknown key in [partitions]");
        } else if (std.mem.eql(u8, section, "system")) {
            if (std.mem.eql(u8, key, "hostname")) {
                if (!validHostname(value)) return fail(diag, "invalid hostname");
                a.hostname = value;
            } else if (std.mem.eql(u8, key, "root_hash")) {
                if (!validHash(value)) return fail(diag, "root_hash is not a crypt hash (passwords are never plain text)");
                a.root_pw = .{ .hash = value };
                have_root_hash = true;
            } else if (std.mem.eql(u8, key, "user")) {
                if (!validUsername(value)) return fail(diag, "invalid user name");
                a.user = value;
                have_user = true;
            } else if (std.mem.eql(u8, key, "user_hash")) {
                if (!validHash(value)) return fail(diag, "user_hash is not a crypt hash (passwords are never plain text)");
                a.user_pw = .{ .hash = value };
                have_user_hash = true;
            } else if (std.mem.eql(u8, key, "timezone")) {
                if (!validTimezone(value)) return fail(diag, "invalid timezone");
                a.timezone = value;
            } else if (std.mem.eql(u8, key, "keymap")) {
                if (!validKeymap(value)) return fail(diag, "invalid keymap name");
                a.keymap = value;
            } else if (std.mem.eql(u8, key, "domain")) {
                if (!validHostname(value)) return fail(diag, "invalid domain");
                a.domain = value;
            } else if (std.mem.eql(u8, key, "ntp")) {
                a.ntp = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "firewall")) {
                a.firewall = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "selinux")) {
                a.selinux = std.meta.stringToEnum(SelinuxMode, value) orelse return fail(diag, "selinux must be permissive, enforcing or disabled");
            } else return fail(diag, "unknown key in [system]");
        } else if (std.mem.eql(u8, section, "network")) {
            net_seen = true;
            if (std.mem.eql(u8, key, "mode")) {
                net_v.mode = std.meta.stringToEnum(NetMode, value) orelse return fail(diag, "mode must be guided, copy, manual or manual-shell");
            } else if (std.mem.eql(u8, key, "copy")) {
                if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null or value[0] == '.') return fail(diag, "invalid connection file name");
                net_v.copy = value;
            } else if (std.mem.eql(u8, key, "iface")) {
                var it = std.mem.tokenizeScalar(u8, value, ' ');
                const name = it.next() orelse return fail(diag, "iface needs a name");
                const kind = it.next() orelse return fail(diag, "iface needs dhcp, static or disabled");
                if (!validIfaceName(name)) return fail(diag, "invalid interface name");
                var ifc: Iface = .{ .name = name };
                ifc.kind = std.meta.stringToEnum(IfaceKind, kind) orelse return fail(diag, "iface kind must be dhcp, static or disabled");
                if (ifc.kind == .static) {
                    const addr = it.next() orelse return fail(diag, "static needs ADDRESS/PREFIX");
                    if (!validCidr(addr)) return fail(diag, "invalid ADDRESS/PREFIX");
                    ifc.address = addr;
                    if (it.next()) |gw| {
                        if (!validIp(gw) or isV6(gw) != isV6(addr)) return fail(diag, "invalid gateway (same family as the address)");
                        ifc.gateway = gw;
                    }
                }
                try ifaces.append(arena, ifc);
            } else if (std.mem.eql(u8, key, "dns")) {
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.tokenizeAny(u8, value, " \t,");
                while (it.next()) |t| {
                    if (!validIp(t)) return fail(diag, "invalid DNS server address");
                    try list.append(arena, t);
                }
                net_v.dns = list.items;
            } else if (std.mem.eql(u8, key, "search")) {
                if (!validHostname(value)) return fail(diag, "invalid search domain");
                net_v.search = value;
            } else if (std.mem.eql(u8, key, "wifi_ssid")) {
                if (!validSsid(value)) return fail(diag, "invalid SSID (1-32 printable characters, no backslash or quote)");
                wifi_ssid = value;
            } else if (std.mem.eql(u8, key, "wifi_psk")) {
                if (!validPsk(value)) return fail(diag, "invalid WiFi passphrase (8-63 printable characters, no backslash or quote)");
                wifi_psk = value;
            } else if (std.mem.eql(u8, key, "wifi_hidden")) {
                wifi_hidden = parseBool(value) orelse return fail(diag, "expected true or false");
            } else return fail(diag, "unknown key in [network]");
        } else if (std.mem.eql(u8, section, "post")) {
            if (!std.mem.eql(u8, key, "commands")) return fail(diag, "unknown key in [post]");
            if (value.len == 0) return fail(diag, "empty command");
            try post.append(arena, value);
        } else if (std.mem.eql(u8, section, "services")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, value, " \t,");
            while (it.next()) |t| {
                if (!validServiceName(t)) return fail(diag, "invalid service name");
                try list.append(arena, t);
            }
            if (std.mem.eql(u8, key, "enable")) {
                a.services_enable = list.items;
            } else if (std.mem.eql(u8, key, "disable")) {
                a.services_disable = list.items;
            } else return fail(diag, "unknown key in [services]");
        } else if (std.mem.eql(u8, section, "ssh")) {
            const ssh = &ssh_v;
            ssh_seen = true;
            if (std.mem.eql(u8, key, "enable")) {
                ssh.enable = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "root_login")) {
                ssh.root_login = std.meta.stringToEnum(RootLogin, value) orelse return fail(diag, "root_login must be no, prohibit-password or yes");
            } else if (std.mem.eql(u8, key, "password_auth")) {
                ssh.password_auth = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "authorized_key")) {
                if (!validPubKey(value)) return fail(diag, "authorized_key is not an OpenSSH public key line");
                ssh.authorized_key = value;
            } else if (std.mem.eql(u8, key, "generate_key")) {
                ssh.generate_key = parseBool(value) orelse return fail(diag, "expected true or false");
            } else if (std.mem.eql(u8, key, "allow_lockout")) {
                ssh.allow_lockout = parseBool(value) orelse return fail(diag, "expected true or false");
            } else return fail(diag, "unknown key in [ssh]");
        } else if (std.mem.eql(u8, section, "packages")) {
            if (std.mem.eql(u8, key, "install")) {
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.tokenizeAny(u8, value, " \t,");
                while (it.next()) |t| {
                    if (!validPackageName(t)) return fail(diag, "invalid package name");
                    try list.append(arena, t);
                }
                a.packages = list.items;
            } else if (std.mem.eql(u8, key, "keep_repo")) {
                a.keep_repo = parseBool(value) orelse return fail(diag, "expected true or false");
            } else return fail(diag, "unknown key in [packages]");
        } else return fail(diag, "key outside a known section");
    }

    diag.line = 0;
    if (ssh_seen) a.ssh = ssh_v;
    a.post = post.items;
    if (net_seen) {
        net_v.ifaces = ifaces.items;
        if ((wifi_ssid == null) != (wifi_psk == null)) return fail(diag, "[network] wifi_ssid and wifi_psk go together");
        if (wifi_ssid) |sid| net_v.wifi = .{ .ssid = sid, .psk = wifi_psk.?, .hidden = wifi_hidden };
        if (net_v.mode == .copy and net_v.copy == null) return fail(diag, "[network] mode = copy needs copy = FILE");
        a.network = net_v;
    }
    a.disk = disk orelse return fail(diag, "[install] disk is required");
    a.partitioning = partitioning orelse return fail(diag, "[install] partitioning is required");
    if (!have_root_hash) return fail(diag, "[system] root_hash is required");
    if (!have_user) return fail(diag, "[system] user is required");
    if (!have_user_hash) return fail(diag, "[system] user_hash is required");
    if (a.partitioning == .existing and a.root == null) return fail(diag, "[partitions] root is required for existing partitioning");
    return a;
}

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
        \\disk = sda
        \\partitioning = existing
        \\[partitions]
        \\root = sda3
        \\esp = sda2
        \\format_esp = yes
        \\[system]
        \\root_hash = $6$salt$roothash
        \\user = dakota
        \\user_hash = $6$salt$userhash
        \\timezone = Europe/Berlin
    , &diag);
    try std.testing.expectEqualStrings("sda", a.disk);
    try std.testing.expectEqual(Partitioning.existing, a.partitioning);
    try std.testing.expect(a.format_esp);
    try std.testing.expectEqualStrings("dkrescue", a.hostname);
    try std.testing.expectEqualStrings("Europe/Berlin", a.timezone);
}

test "parse the packages section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const base =
        \\[install]
        \\disk = sda
        \\partitioning = auto
        \\[system]
        \\root_hash = $6$salt$roothash
        \\user = dakota
        \\user_hash = $6$salt$userhash
        \\[packages]
        \\install = nano  htop,git
        \\keep_repo = yes
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
        \\disk = sda
        \\partitioning = auto
        \\[system]
        \\root_hash = $6$salt$roothash
        \\user = dakota
        \\user_hash = $6$salt$userhash
        \\ntp = no
        \\firewall = yes
        \\selinux = enforcing
        \\[services]
        \\enable = cupsd
        \\disable = avahi-daemon bluetoothd
        \\[ssh]
        \\enable = yes
        \\root_login = prohibit-password
        \\password_auth = no
        \\authorized_key = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@host
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
        \\disk = sda
        \\partitioning = auto
        \\[system]
        \\root_hash = $6$salt$roothash
        \\user = dakota
        \\user_hash = $6$salt$userhash
        \\domain = example.org
        \\[network]
        \\iface = eth0 static 192.168.1.5/24 192.168.1.1
        \\iface = eth1 disabled
        \\dns = 1.1.1.1 9.9.9.9
        \\wifi_ssid = Home
        \\wifi_psk = hunter2hunter2
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
        \\disk = largest
        \\partitioning = auto
        \\confirm_erase = /dev/disk/by-id/nvme-X
        \\when_done = poweroff
        \\[system]
        \\root_hash = $6$salt$roothash
        \\user = dakota
        \\user_hash = $6$salt$userhash
        \\[post]
        \\commands = echo one > /etc/one
        \\commands = echo two > /etc/two
    , &diag);
    try std.testing.expectEqualStrings("largest", a.disk);
    try std.testing.expectEqualStrings("/dev/disk/by-id/nvme-X", a.confirm_erase.?);
    try std.testing.expectEqual(WhenDone.poweroff, a.when_done);
    try std.testing.expectEqual(@as(usize, 2), a.post.len);
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(), "[install]\nwhen_done = explode\n", &diag));
}

test "parse rejects plain-text passwords and reports the line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.BadAnswers, parse(arena_state.allocator(),
        \\[install]
        \\disk = sda
        \\partitioning = auto
        \\[system]
        \\root_hash = hunter2
    , &diag));
    try std.testing.expectEqual(@as(usize, 5), diag.line);
}
