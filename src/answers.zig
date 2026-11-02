//! The user's choices, and the answers-file (INI) parser.
//! Implements SPEC.md 5.3, 5.4, 6.1 and 7.
//!
//! File format:
//!
//!     [install]
//!     disk = nvme0n1
//!     partitioning = auto            # or: existing
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
            } else return fail(diag, "unknown key in [system]");
        } else return fail(diag, "key outside a known section");
    }

    diag.line = 0;
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
