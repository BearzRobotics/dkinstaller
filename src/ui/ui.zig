//! The screens (SPEC.md 5.1-5.5): widgets on top of `term`, and the flow
//! that fills in `Answers` and ends at the typed confirmation.
//! Esc goes back one screen at any point; nothing is written here.
//!
//! The UI talks only to `probe`, `answers`, `plan` and `files`. Keys come
//! from the real terminal or from a script, so the flow is testable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const term = @import("term.zig");
const probe_mod = @import("../probe.zig");
const answers_mod = @import("../answers.zig");
const plan_mod = @import("../plan.zig");
const files = @import("../files.zig");
const fs_mod = @import("../fs.zig");
const bl_mod = @import("../bootloader.zig");
const execute = @import("../execute.zig");

const Key = term.Key;
const Attr = term.Attr;
const Disk = probe_mod.Disk;
const Partition = probe_mod.Partition;
const Probe = probe_mod.Probe;

const normal: Attr = .{};
const bold: Attr = .{ .bold = true };
const selected: Attr = .{ .reverse = true };
const dim: Attr = .{ .fg = .black, .bold = true };
const danger: Attr = .{ .fg = .red, .bold = true };
const good: Attr = .{ .fg = .green, .bold = true };
const warn: Attr = .{ .fg = .yellow, .bold = true };

/// Where keys come from, and where the picture goes.
pub const Ui = struct {
    gpa: Allocator,
    /// Lives as long as the install session; every string is allocated here.
    arena: Allocator,
    screen: term.Screen,
    terminal: ?*term.Terminal = null,
    /// Scripted keys, for tests. Used when `terminal` is null.
    script: []const Key = &.{},
    script_i: usize = 0,
    /// For the few things the screens run themselves (mounting a repository).
    io: ?Io = null,

    fn key(self: *Ui) !Key {
        try self.present();
        if (self.terminal) |t| {
            const k = try t.readKey();
            if (k == .ctrl_c) return error.Quit;
            return k;
        }
        if (self.script_i >= self.script.len) return error.ScriptEnded;
        const k = self.script[self.script_i];
        self.script_i += 1;
        return k;
    }

    fn present(self: *Ui) !void {
        if (self.terminal) |t| try self.screen.render(t.writer());
    }

    fn fmt(self: *Ui, comptime f: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.arena, f, args) catch @panic("out of memory");
    }

    /// Clears the screen and draws the frame: title bar, box, hints.
    fn frame(self: *Ui, title: []const u8, hint: []const u8) Rect {
        const s = &self.screen;
        s.clear();
        const w: i32 = s.w;
        const h: i32 = s.h;
        s.fill(0, 0, w, 1, selected);
        _ = s.text(1, 0, "dkrescue-install", selected, @intCast(w - 2));
        s.box(1, 1, w - 2, h - 3, title, normal);
        _ = s.text(1, h - 1, hint, dim, @intCast(w - 2));
        return .{ .x = 3, .y = 2, .w = w - 6, .h = h - 5 };
    }
};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

// --------------------------------------------------------------- helpers

/// "238.5 GiB", "512 MiB".
pub fn fmtSize(arena: Allocator, bytes: u64) []const u8 {
    const gib: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (gib >= 1.0) return std.fmt.allocPrint(arena, "{d:.1} GiB", .{gib}) catch "?";
    return std.fmt.allocPrint(arena, "{d} MiB", .{bytes / (1024 * 1024)}) catch "?";
}

fn transportName(t: ?[]const u8) []const u8 {
    const s = t orelse return "";
    if (std.mem.eql(u8, s, "nvme")) return "NVMe";
    if (std.mem.eql(u8, s, "sata")) return "SATA";
    if (std.mem.eql(u8, s, "usb")) return "USB";
    return s;
}

/// What's on a disk, e.g. `NTFS "Windows", ext4 "home"`; null if empty.
pub fn describeContents(arena: Allocator, d: Disk) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (d.partitions) |p| {
        if (out.items.len > 0) out.appendSlice(arena, ", ") catch {};
        const fs = p.fstype orelse "partition";
        const piece = if (p.label) |l|
            std.fmt.allocPrint(arena, "{s} \"{s}\"", .{ fs, l }) catch fs
        else
            fs;
        out.appendSlice(arena, piece) catch {};
    }
    if (out.items.len == 0) {
        if (d.fstype) |fs| return std.fmt.allocPrint(arena, "{s}", .{fs}) catch null;
        if (d.table) |t| return std.fmt.allocPrint(arena, "empty {s} partition table", .{t}) catch null;
        return null;
    }
    return out.items;
}

/// Splits `s` into lines of at most `width` columns, on spaces.
fn wrap(arena: Allocator, s: []const u8, width: usize) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |para| {
        var start: usize = 0;
        while (para.len - start > width) {
            var cut = start + width;
            while (cut > start and para[cut] != ' ') cut -= 1;
            if (cut == start) {
                cut = start + width;
                // Not in the middle of a character.
                while (cut > start + 1 and (para[cut] & 0xC0) == 0x80) cut -= 1;
            }
            try lines.append(arena, std.mem.trimEnd(u8, para[start..cut], " "));
            start = cut;
            while (start < para.len and para[start] == ' ') start += 1;
        }
        try lines.append(arena, para[start..]);
    }
    return lines.items;
}

// --------------------------------------------------------------- widgets

/// One row of a menu.
pub const Item = struct {
    label: []const u8,
    /// Shown after the label, or on a second line when `sub` is set.
    detail: []const u8 = "",
    sub: ?[]const u8 = null,
    sub_attr: Attr = dim,
    enabled: bool = true,
};

/// A list to choose from. Returns the index, or null for Esc.
pub fn menu(ui: *Ui, title: []const u8, intro: []const u8, items: []const Item, start: usize) !?usize {
    var cur: usize = start;
    if (cur >= items.len or !items[cur].enabled) {
        cur = 0;
        while (cur < items.len and !items[cur].enabled) cur += 1;
    }
    var top: usize = 0;
    while (true) {
        const r = ui.frame(title, "Up/Down: move   Enter: choose   Esc: back");
        var y = r.y;
        const intro_lines = try wrap(ui.arena, intro, @intCast(r.w));
        for (intro_lines) |l| {
            _ = ui.screen.text(r.x, y, l, normal, @intCast(r.w));
            y += 1;
        }
        if (intro_lines.len > 0) y += 1;
        const avail: usize = @intCast(@max(1, r.y + r.h - y));
        // Keep the selection in view; rows may take two lines.
        if (cur < top) top = cur;
        while (true) {
            var used: usize = 0;
            for (items[top..], top..) |it, i| {
                used += if (it.sub != null) 2 else 1;
                if (i == cur) break;
            }
            if (used <= avail) break;
            top += 1;
        }
        var i = top;
        while (i < items.len) : (i += 1) {
            const it = items[i];
            const rows: i32 = if (it.sub != null) 2 else 1;
            if (y + rows > r.y + r.h) break;
            const is_cur = i == cur;
            var a = if (it.enabled) normal else dim;
            if (is_cur) a = selected;
            ui.screen.fill(r.x, y, r.w, 1, a);
            const n = ui.screen.text(r.x + 1, y, it.label, a, @intCast(r.w - 2));
            if (it.detail.len > 0) {
                _ = ui.screen.text(r.x + 3 + @as(i32, @intCast(n)), y, it.detail, a, @intCast(@max(0, r.w - 4 - @as(i32, @intCast(n)))));
            }
            if (it.sub) |sub| {
                var sa = it.sub_attr;
                if (is_cur) sa.reverse = true;
                ui.screen.fill(r.x, y + 1, r.w, 1, if (is_cur) selected else normal);
                _ = ui.screen.text(r.x + 3, y + 1, sub, sa, @intCast(r.w - 4));
            }
            y += rows;
        }
        if (top > 0) _ = ui.screen.text(r.x + r.w - 1, r.y, "^", dim, 1);
        if (i < items.len) _ = ui.screen.text(r.x + r.w - 1, r.y + r.h - 1, "v", dim, 1);

        switch (try ui.key()) {
            .up => {
                var j = cur;
                while (j > 0) {
                    j -= 1;
                    if (items[j].enabled) {
                        cur = j;
                        break;
                    }
                }
            },
            .down => {
                var j = cur + 1;
                while (j < items.len) : (j += 1) {
                    if (items[j].enabled) {
                        cur = j;
                        break;
                    }
                }
            },
            .enter => if (items.len > 0 and items[cur].enabled) return cur,
            .esc => return null,
            else => {},
        }
    }
}

/// Text field options.
pub const InputOpts = struct {
    /// Shown as `*`, and kept off the screen.
    secret: bool = false,
    /// Returns an error message if `s` isn't acceptable.
    validate: ?*const fn ([]const u8) ?[]const u8 = null,
    /// Enter is only accepted when the text equals this.
    expect: ?[]const u8 = null,
    mismatch: []const u8 = "That doesn't match.",
};

/// A one-line text field. Returns the text, or null for Esc.
pub fn input(ui: *Ui, title: []const u8, intro: []const u8, initial: []const u8, opts: InputOpts) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ui.arena, initial);
    var pos: usize = buf.items.len;
    var err_msg: ?[]const u8 = null;
    while (true) {
        const r = ui.frame(title, "Enter: accept   Esc: back");
        var y = r.y;
        for (try wrap(ui.arena, intro, @intCast(r.w))) |l| {
            _ = ui.screen.text(r.x, y, l, normal, @intCast(r.w));
            y += 1;
        }
        y += 1;
        ui.screen.fill(r.x, y, r.w, 1, selected);
        const shown = if (opts.secret) blk: {
            const stars = try ui.arena.alloc(u8, buf.items.len);
            @memset(stars, '*');
            break :blk stars;
        } else buf.items;
        const view_w: usize = @intCast(r.w - 2);
        // Scrolling and the cursor count characters, not bytes (a secret shows a `*` per byte).
        const col = term.columns(shown[0..pos]);
        const off = if (col >= view_w) col - view_w + 1 else 0;
        _ = ui.screen.text(r.x + 1, y, shown[term.byteAtColumn(shown, off)..], selected, view_w);
        ui.screen.cursor = .{ .x = @intCast(r.x + 1 + @as(i32, @intCast(col - off))), .y = @intCast(y) };
        if (err_msg) |m| _ = ui.screen.text(r.x, y + 2, m, danger, @intCast(r.w));

        switch (try ui.key()) {
            .char => |c| {
                if (c < 0x20 or c > 0x10ffff) continue;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &tmp) catch continue;
                try buf.insertSlice(ui.arena, pos, tmp[0..n]);
                pos += n;
                err_msg = null;
            },
            .backspace => if (pos > 0) {
                var p = pos - 1;
                while (p > 0 and (buf.items[p] & 0xC0) == 0x80) p -= 1;
                buf.replaceRange(ui.arena, p, pos - p, &.{}) catch {};
                pos = p;
                err_msg = null;
            },
            .delete => if (pos < buf.items.len) {
                var e = pos + 1;
                while (e < buf.items.len and (buf.items[e] & 0xC0) == 0x80) e += 1;
                buf.replaceRange(ui.arena, pos, e - pos, &.{}) catch {};
            },
            .left => if (pos > 0) {
                pos -= 1;
                while (pos > 0 and (buf.items[pos] & 0xC0) == 0x80) pos -= 1;
            },
            .right => if (pos < buf.items.len) {
                pos += 1;
                while (pos < buf.items.len and (buf.items[pos] & 0xC0) == 0x80) pos += 1;
            },
            .home => pos = 0,
            .end => pos = buf.items.len,
            .enter => {
                if (opts.expect) |want| {
                    if (!std.mem.eql(u8, buf.items, want)) {
                        err_msg = opts.mismatch;
                        continue;
                    }
                }
                if (opts.validate) |v| if (v(buf.items)) |m| {
                    err_msg = m;
                    continue;
                };
                return buf.items;
            },
            .esc => return null,
            else => {},
        }
    }
}

/// A message that waits for Enter (returns true) or Esc (returns false).
pub fn message(ui: *Ui, title: []const u8, lines: []const []const u8, attr: Attr, hint: []const u8) !bool {
    while (true) {
        const r = ui.frame(title, hint);
        var y = r.y;
        for (lines) |para| {
            for (try wrap(ui.arena, para, @intCast(r.w))) |l| {
                if (y >= r.y + r.h) break;
                _ = ui.screen.text(r.x, y, l, attr, @intCast(r.w));
                y += 1;
            }
        }
        switch (try ui.key()) {
            .enter => return true,
            .esc => return false,
            else => {},
        }
    }
}

/// One line of a scrollable view.
pub const Line = struct { text: []const u8, attr: Attr = normal };

/// A scrollable view. Enter returns true, Esc false.
pub fn viewer(ui: *Ui, title: []const u8, lines: []const Line, hint: []const u8) !bool {
    var top: usize = 0;
    while (true) {
        const r = ui.frame(title, hint);
        const rows: usize = @intCast(r.h);
        const max_top = if (lines.len > rows) lines.len - rows else 0;
        if (top > max_top) top = max_top;
        for (lines[top..], 0..) |l, i| {
            if (i >= rows) break;
            _ = ui.screen.text(r.x, r.y + @as(i32, @intCast(i)), l.text, l.attr, @intCast(r.w - 1));
        }
        if (top > 0) _ = ui.screen.text(r.x + r.w - 1, r.y, "^", dim, 1);
        if (top < max_top) _ = ui.screen.text(r.x + r.w - 1, r.y + r.h - 1, "v", dim, 1);
        switch (try ui.key()) {
            .up => if (top > 0) {
                top -= 1;
            },
            .down => if (top < max_top) {
                top += 1;
            },
            .page_up => top -|= rows - 1,
            .page_down => top = @min(max_top, top + rows - 1),
            .home => top = 0,
            .end => top = max_top,
            .enter => return true,
            .esc => return false,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ flow

/// Facts about the environment the installer was started in.
pub const Env = struct {
    is_root: bool,
    /// Programs from `plan.required_programs` that can't be found.
    missing: []const []const u8 = &.{},
    /// Dry run: missing programs are only a warning.
    dry_run: bool,
    ids: files.Ids,
    /// `cfdisk` is on this machine (5.3.2); without it the choice is greyed out.
    cfdisk: bool = false,
};

/// What the user decided.
pub const Done = struct {
    answers: answers_mod.Answers,
    plan: plan_mod.Plan,
};

const Scr = enum {
    checks,
    disk,
    partitioning,
    bootloader,
    root_fs,
    cfdisk,
    root,
    esp,
    esp_type,
    esp_format,
    bios_boot,
    hostname,
    root_pw,
    user,
    user_pw,
    timezone,
    keymap,
    network,
    services,
    ssh,
    other,
    repo_pick,
    packages,
    summary,
};

const Draft = struct {
    disk: ?Disk = null,
    partitioning: answers_mod.Partitioning = .auto,
    /// Partition by hand with cfdisk first, then continue as with existing partitions.
    manual: bool = false,
    /// The root filesystem (SPEC.md 5.3.4).
    root_fs: fs_mod.Fs = .ext4,
    /// The boot loader (SPEC.md 5.6.8).
    bootloader: bl_mod.Bootloader = .dklilo,
    root: ?Partition = null,
    esp: ?Partition = null,
    bios_boot: ?Partition = null,
    format_esp: bool = false,
    set_esp_type: bool = false,
    set_bios_boot_type: bool = false,
    hostname: []const u8 = "dkrescue",
    root_pw: []const u8 = "",
    user: []const u8 = "",
    user_pw: []const u8 = "",
    timezone: []const u8 = "UTC",
    keymap: []const u8 = "us",
    packages: []const []const u8 = &.{},
    keep_repo: bool = false,
    trust_medium_key: bool = false,
    /// Per probe service: switched on at boot (starts as the image has it).
    svc_on: []bool = &.{},
    ssh: ?answers_mod.Ssh = null,
    selinux: ?answers_mod.SelinuxMode = null,
    domain: ?[]const u8 = null,
    network: ?answers_mod.Network = null,
};

fn isEspType(t: ?[]const u8) bool {
    const s = t orelse return false;
    return std.ascii.eqlIgnoreCase(s, files.guid_esp) or std.ascii.eqlIgnoreCase(s, "0xef");
}

fn isBiosBootType(t: ?[]const u8) bool {
    const s = t orelse return false;
    return std.ascii.eqlIgnoreCase(s, files.guid_bios_boot);
}

fn hostnameError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validHostname(s)) null else "Not a valid hostname (letters, digits, hyphens and dots; no leading or trailing hyphen).";
}

fn domainError(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    return if (answers_mod.validHostname(s)) null else "Not a valid domain name.";
}

fn userError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validUsername(s)) null else "Not a valid user name (lowercase letters, digits, _ and -; starts with a letter or _).";
}

fn timezoneError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validTimezone(s)) null else "Not a valid zone name, for example Europe/Berlin.";
}

fn keymapError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validKeymap(s)) null else "Not a valid keymap name (letters, digits and . _ - +).";
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len > 0) null else "This can't be empty.";
}

/// Runs the screens. Returns null if the user backed out of the first
/// screen; error.Quit on Ctrl-C.
pub fn run(ui: *Ui, p_in: Probe, env: Env) !?Done {
    var p = p_in;
    var d: Draft = .{};
    var stack: std.ArrayList(Scr) = .empty;
    try stack.append(ui.arena, .checks);

    while (stack.items.len > 0) {
        const cur = stack.items[stack.items.len - 1];
        var go: ?Scr = null; // next screen; null = Esc, go back
        switch (cur) {
            .checks => {
                const ok = try screenChecks(ui, p, env);
                if (ok == .quit) return null;
                if (ok == .go) go = .disk;
            },
            .disk => {
                if (try screenDisk(ui, p, &d)) go = .partitioning;
            },
            .partitioning => {
                if (try screenPartitioning(ui, p, env, &d)) go = .bootloader;
            },
            .bootloader => {
                if (try screenBootloader(ui, p, &d)) go = .root_fs;
            },
            .root_fs => {
                if (try screenRootFs(ui, p, &d)) go = if (d.manual) .cfdisk else if (d.partitioning == .auto) .hostname else .root;
            },
            .cfdisk => {
                if (try screenCfdisk(ui, &p, &d)) go = .root;
            },
            .root => {
                if (try screenRoot(ui, &d)) go = .esp;
            },
            .esp => {
                if (try screenEsp(ui, p, &d)) go = afterEsp(p, &d, .esp);
            },
            .esp_type => {
                if (try screenEspType(ui, &d)) go = afterEsp(p, &d, .esp_type);
            },
            .esp_format => {
                if (try screenEspFormat(ui, &d)) go = afterEsp(p, &d, .esp_format);
            },
            .bios_boot => {
                if (try screenBiosBoot(ui, &d)) go = .hostname;
            },
            .hostname => {
                if (try input(ui, "Hostname", "Name for this computer.", d.hostname, .{ .validate = hostnameError })) |v| {
                    d.hostname = v;
                    // The domain is optional: empty means none. Esc comes back here.
                    if (try input(ui, "Domain", "Domain name of this network, for example example.org. Leave empty for none. /etc/hosts gets host.domain.", d.domain orelse "", .{ .validate = domainError })) |dom| {
                        d.domain = if (dom.len == 0) null else dom;
                        go = .root_pw;
                    }
                }
            },
            .root_pw => {
                if (try screenPassword(ui, "Root password", &d.root_pw)) go = .user;
            },
            .user => {
                if (try input(ui, "User", "Name of the user to create. The user is put in the wheel, video and render groups and can use sudo.", d.user, .{ .validate = userError })) |v| {
                    if (plan_mod.userTaken(p, v)) {
                        _ = try message(ui, "User", &.{ui.fmt("The system already has an account or group named {s}. Choose another name.", .{v})}, warn, "Enter: back");
                    } else {
                        d.user = v;
                        go = .user_pw;
                    }
                }
            },
            .user_pw => {
                const t = ui.fmt("Password for {s}", .{d.user});
                if (try screenPassword(ui, t, &d.user_pw)) go = .timezone;
            },
            .timezone => {
                if (try input(ui, "Timezone", "A zone name from /usr/share/zoneinfo, for example UTC or Europe/Berlin.", d.timezone, .{ .validate = timezoneError })) |v| {
                    if (zoneMissing(ui, v)) {
                        _ = try message(ui, "Timezone", &.{ui.fmt("There is no zone {s} in /usr/share/zoneinfo.", .{v})}, warn, "Enter: back");
                    } else {
                        d.timezone = v;
                        go = .keymap;
                    }
                }
            },
            .keymap => {
                if (try input(ui, "Console keymap", "Keymap for the text console, for example us or de.", d.keymap, .{ .validate = keymapError })) |v| {
                    d.keymap = v;
                    go = next(ui, p, &d, .keymap);
                }
            },
            .network => {
                if (try screenNetwork(ui, &p, &d)) go = next(ui, p, &d, .network);
            },
            .services => {
                if (try screenServices(ui, p, &d)) go = next(ui, p, &d, .services);
            },
            .ssh => {
                if (try screenSsh(ui, &p, &d)) go = next(ui, p, &d, .ssh);
            },
            .other => {
                if (try screenOther(ui, &d)) go = next(ui, p, &d, .other);
            },
            .repo_pick => {
                if (try screenRepoPick(ui, &p, env, &d)) go = if (p.repo != null) .packages else .summary;
            },
            .packages => {
                if (try screenPackages(ui, p.repo.?, &d)) go = .summary;
            },
            .summary => {
                if (try screenSummary(ui, p, env, &d)) |done| return done;
            },
        }
        if (go) |g| try stack.append(ui.arena, g) else _ = stack.pop();
    }
    return null;
}

/// The screen after `from`, skipping those that don't apply to this image:
/// services, ssh, the other options, the repository packages, the summary.
fn next(ui: *Ui, p: Probe, d: *Draft, from: Scr) Scr {
    var cur = from;
    while (true) {
        cur = switch (cur) {
            .keymap => .network,
            .network => .services,
            .services => .ssh,
            .ssh => .other,
            .other => .repo_pick,
            else => .summary,
        };
        switch (cur) {
            .network => if (p.net_stack != .none) return cur,
            .services => if (p.services.len > 0) return cur,
            .ssh => if (sshdTicked(p, d)) return cur else {
                d.ssh = null; // sshd may have been unticked after the SSH screens
            },
            .other => if (p.selinux) return cur,
            .repo_pick => {
                if (p.repo != null) return .packages;
                const cands = probe_mod.repoCandidates(ui.arena, p, if (d.disk) |dk| dk.name else "") catch return .summary;
                if (cands.len > 0) return cur;
            },
            else => return cur,
        }
    }
}

/// Whether sshd starts at boot as the services list now stands.
fn sshdTicked(p: Probe, d: *const Draft) bool {
    for (p.services, 0..) |sv, i| {
        if (std.mem.eql(u8, sv.name, "sshd")) return if (d.svc_on.len == p.services.len) d.svc_on[i] else sv.enabled;
    }
    return false;
}

/// The screen after the ESP choices, skipping those that don't apply.
fn afterEsp(p: Probe, d: *Draft, from: Scr) Scr {
    if (from == .esp) {
        if (d.esp) |e| {
            if (!isEspType(e.parttype)) return .esp_type;
            return .esp_format;
        }
    }
    if (from == .esp_type) {
        if (d.esp != null) return .esp_format;
    }
    // BIOS on GPT needs a BIOS boot partition.
    if (p.firmware == .bios) if (d.disk) |disk| if (disk.table) |t| if (std.mem.eql(u8, t, "gpt")) {
        for (disk.partitions) |q| if (isBiosBootType(q.parttype)) return .hostname;
        return .bios_boot;
    };
    return .hostname;
}

const CheckResult = enum { go, back, quit };

fn screenChecks(ui: *Ui, p: Probe, env: Env) !CheckResult {
    var lines: std.ArrayList(Line) = .empty;
    var fatal = false;
    const L = struct {
        fn add(l: *std.ArrayList(Line), u: *Ui, ok: bool, comptime f: []const u8, args: anytype) !void {
            const t = u.fmt(f, args);
            try l.append(u.arena, .{ .text = u.fmt("[{s}] {s}", .{ if (ok) "ok" else "!!", t }), .attr = if (ok) good else danger });
        }
    };
    try L.add(&lines, ui, env.is_root, "Running as root", .{});
    if (!env.is_root) fatal = true;
    try L.add(&lines, ui, p.is_live, "Running from the live disc", .{});
    if (!p.is_live) fatal = true;
    try lines.append(ui.arena, .{
        .text = ui.fmt("[ok] Firmware: {s}", .{if (p.firmware == .uefi) "UEFI" else "BIOS"}),
        .attr = good,
    });
    if (p.firmware == .uefi and !p.efivars_rw) {
        try lines.append(ui.arena, .{ .text = "[!!] EFI variables are not writable: only a removable-media install is possible", .attr = warn });
    }
    if (env.missing.len == 0) {
        try L.add(&lines, ui, true, "All required programs are present", .{});
    } else {
        for (env.missing) |m| {
            try lines.append(ui.arena, .{ .text = ui.fmt("[!!] Missing program: {s}", .{m}), .attr = if (env.dry_run) warn else danger });
        }
        if (!env.dry_run) fatal = true;
    }
    try lines.append(ui.arena, .{ .text = "" });
    if (fatal) {
        try lines.append(ui.arena, .{ .text = "The installer can't continue. Press Enter to quit.", .attr = danger });
        _ = try viewer(ui, "Checks", lines.items, "Enter: quit");
        return .quit;
    }
    try lines.append(ui.arena, .{ .text = "Nothing is written to any disk until you confirm the summary.", .attr = bold });
    const ok = try viewer(ui, "Checks", lines.items, "Enter: continue   Esc: quit");
    return if (ok) .go else .quit;
}

fn screenDisk(ui: *Ui, p: Probe, d: *Draft) !bool {
    var items: std.ArrayList(Item) = .empty;
    var disks: std.ArrayList(Disk) = .empty;
    // Eligible disks first, then the ones that aren't, with the reason.
    for ([_]bool{ true, false }) |want_ok| {
        for (p.disks) |disk| {
            const why = probe_mod.ineligible(p, disk, false);
            if ((why == null) != want_ok) continue;
            const head = ui.fmt("/dev/{s}  {s}  {s}  {s}", .{
                disk.name,            fmtSize(ui.arena, disk.size),
                disk.model orelse "", transportName(disk.transport),
            });
            if (why) |w| {
                try items.append(ui.arena, .{ .label = head, .sub = ui.fmt("not available: {s}", .{w.text()}), .enabled = false });
            } else if (probe_mod.ineligible(p, disk, true)) |w| {
                try items.append(ui.arena, .{ .label = head, .sub = ui.fmt("not available: {s}", .{w.text()}), .enabled = false });
            } else if (describeContents(ui.arena, disk)) |c| {
                try items.append(ui.arena, .{ .label = head, .sub = ui.fmt("contains data: {s}", .{c}), .sub_attr = warn });
            } else {
                try items.append(ui.arena, .{ .label = head, .sub = "empty" });
            }
            try disks.append(ui.arena, disk);
        }
    }
    if (items.items.len == 0) {
        _ = try message(ui, "Disk", &.{"No disks were found."}, danger, "Esc: back");
        return false;
    }
    const pick = try menu(ui, "Choose the disk to install to", "Disks that can't be used are listed with the reason.", items.items, 0) orelse return false;
    d.disk = disks.items[pick];
    d.root = null;
    d.esp = null;
    d.bios_boot = null;
    return true;
}

fn screenPartitioning(ui: *Ui, p: Probe, env: Env, d: *Draft) !bool {
    _ = p;
    const disk = d.disk.?;
    const has_table = disk.table != null;
    const items = [_]Item{
        .{ .label = "Erase the disk and partition it automatically", .sub = "GPT: BIOS boot 1 MiB, ESP 512 MiB, root (the rest; ext4 unless you choose another next). Everything on the disk is lost." },
        .{
            .label = "Partition by hand with cfdisk",
            .sub = if (env.cfdisk) "Runs cfdisk on the disk. This writes to the disk before the summary." else "cfdisk was not found.",
            .sub_attr = if (env.cfdisk) warn else dim,
            .enabled = env.cfdisk,
        },
        .{
            .label = "Use the existing partitions",
            .sub = if (has_table) "For a disk partitioned with fdisk, gdisk, parted or similar. Nothing is created or resized." else "The disk has no partition table.",
            .enabled = has_table,
        },
    };
    const pick = try menu(ui, ui.fmt("Partitioning /dev/{s}", .{disk.name}), "", &items, if (d.manual) 1 else if (d.partitioning == .existing and has_table) 2 else 0) orelse return false;
    d.manual = pick == 1;
    d.partitioning = if (pick == 0) .auto else .existing;
    return true;
}

/// 5.3.2: says that cfdisk writes right away, asks for the disk's name, runs
/// cfdisk on the real terminal, then probes again so the choices that follow
/// (5.3.3) see the new partitions.
fn screenCfdisk(ui: *Ui, p: *Probe, d: *Draft) !bool {
    const disk = d.disk.?;
    const prompt = ui.fmt("cfdisk changes /dev/{s} as soon as you choose Write in it; nothing asks again after that. Anything on the disk that you delete or resize is lost. To start cfdisk, type the disk's name ({s}) and press Enter.", .{ disk.name, disk.name });
    if (try input(ui, "Partition by hand", prompt, "", .{ .expect = disk.name, .mismatch = "That is not the disk's name." }) == null) return false;
    const t = ui.terminal orelse return error.NeedsTerminal;
    t.pause();
    var failed = false;
    if (std.process.spawn(t.io, .{ .argv = &.{ "cfdisk", disk.path } })) |child| {
        var c = child;
        const term_status = c.wait(t.io) catch null;
        failed = term_status == null or !term_status.?.success();
    } else |_| failed = true;
    t.unpause();
    ui.screen.invalidate();

    const fresh = probe_mod.live(ui.arena, t.io) catch {
        _ = try message(ui, "Partition by hand", &.{"The disk could not be read again after cfdisk. Quit and start the installer again."}, danger, "Enter or Esc: back");
        return false;
    };
    p.* = fresh;
    const nd = fresh.findDisk(disk.name) orelse return false;
    d.disk = nd;
    d.root = null;
    d.esp = null;
    d.bios_boot = null;
    if (failed) {
        _ = try message(ui, "Partition by hand", &.{"cfdisk did not exit cleanly. The disk was read again; check the partitions on the next screens."}, warn, "Enter: continue");
    }
    if (nd.table == null or nd.partitions.len == 0) {
        _ = try message(ui, "Partition by hand", &.{"The disk has no partitions. Go back and run cfdisk again, or choose automatic partitioning."}, danger, "Enter or Esc: back");
        return false;
    }
    return true;
}

fn partitionItems(ui: *Ui, parts: []const Partition, skip: ?[]const u8) !struct { items: []const Item, idx: []const usize } {
    var items: std.ArrayList(Item) = .empty;
    var idx: std.ArrayList(usize) = .empty;
    for (parts, 0..) |q, i| {
        if (skip) |s| if (std.mem.eql(u8, s, q.path)) continue;
        try items.append(ui.arena, .{
            .label = ui.fmt("{s}  {s}", .{ q.path, fmtSize(ui.arena, q.size) }),
            .detail = ui.fmt("{s}{s}{s}{s}", .{
                q.fstype orelse "no filesystem",
                if (q.label != null) " \"" else "",
                q.label orelse "",
                if (q.label != null) "\"" else "",
            }),
            .sub = if (q.parttype) |t| ui.fmt("type {s}", .{t}) else null,
        });
        try idx.append(ui.arena, i);
    }
    return .{ .items = items.items, .idx = idx.items };
}

/// The root filesystem (SPEC.md 5.3.4). Every filesystem is listed; one that cannot be
/// used is greyed with the reason (a missing tool, or what the installed system lacks).
fn screenBootloader(ui: *Ui, p: Probe, d: *Draft) !bool {
    var items: std.ArrayList(Item) = .empty;
    const fw: bl_mod.Firmware = if (p.firmware == .uefi) .uefi else .bios;
    for (bl_mod.all) |b| {
        const i = bl_mod.info(b);
        switch (try bl_mod.availability(ui.arena, b, fw, p.tools, p.paths)) {
            .ok => try items.append(ui.arena, .{
                .label = i.title,
                .sub = switch (b) {
                    .dklilo => "Reads ext2/3/4, btrfs and FAT; not XFS. BIOS and UEFI.",
                    .grub => "Reads ext2/3/4, btrfs and XFS. BIOS and UEFI.",
                    .@"systemd-boot" => "Boots kernels from the EFI System Partition, so any root the kernel can mount works.",
                },
            }),
            .unusable => |why| try items.append(ui.arena, .{
                .label = i.title,
                .sub = why,
                .sub_attr = warn,
                .enabled = false,
            }),
        }
    }
    const pick = try menu(ui, "Boot loader", "Which boot loader should start the new system? Greyed ones say what is missing.", items.items, @backingInt(d.bootloader)) orelse return false;
    d.bootloader = bl_mod.all[pick];
    // A root chosen under another loader may not be readable by this one: back to ext4, the one every loader reads.
    if (!bl_mod.canReadRoot(d.bootloader, d.root_fs)) d.root_fs = .ext4;
    return true;
}

fn screenRootFs(ui: *Ui, p: Probe, d: *Draft) !bool {
    var items: std.ArrayList(Item) = .empty;
    for (fs_mod.all) |f| {
        const i = fs_mod.info(f);
        const bc: fs_mod.BootCheck = .{ .readable = bl_mod.canReadRoot(d.bootloader, f), .loader = bl_mod.info(d.bootloader).name };
        const av = try fs_mod.availability(ui.arena, f, p.tools, p.kernel_builtin, bc);
        switch (av) {
            .ok => try items.append(ui.arena, .{
                .label = i.title,
                .sub = ui.fmt("Needs {s} (package {s}), found.", .{ i.tools[0], i.package }),
            }),
            .unusable => |why| try items.append(ui.arena, .{
                .label = i.title,
                .sub = why,
                .sub_attr = warn,
                .enabled = false,
            }),
        }
    }
    const pick = try menu(ui, "Root filesystem", "What should / be formatted as? Greyed ones say what is missing.", items.items, @backingInt(d.root_fs)) orelse return false;
    d.root_fs = fs_mod.all[pick];
    return true;
}

fn screenRoot(ui: *Ui, d: *Draft) !bool {
    const disk = d.disk.?;
    const list = try partitionItems(ui, disk.partitions, null);
    if (list.items.len == 0) {
        _ = try message(ui, "Root partition", &.{"The disk has no partitions."}, danger, "Esc: back");
        return false;
    }
    const pick = try menu(ui, "Root partition", ui.fmt("Which partition becomes /? It is always formatted as {s} and everything on it is lost.", .{fs_mod.info(d.root_fs).name}), list.items, 0) orelse return false;
    d.root = disk.partitions[list.idx[pick]];
    return true;
}

fn screenEsp(ui: *Ui, p: Probe, d: *Draft) !bool {
    const disk = d.disk.?;
    const root = d.root.?;
    const list = try partitionItems(ui, disk.partitions, root.path);
    var items: std.ArrayList(Item) = .empty;
    var idx: std.ArrayList(?usize) = .empty;
    var start: usize = 0;
    var esp_count: usize = 0;
    for (list.items, list.idx) |it, i| {
        if (isEspType(disk.partitions[i].parttype)) {
            esp_count += 1;
            start = items.items.len;
        }
        try items.append(ui.arena, it);
        try idx.append(ui.arena, i);
    }
    if (esp_count != 1) start = 0;
    if (p.firmware == .bios) {
        try items.append(ui.arena, .{ .label = "No EFI System Partition", .sub = "The disk will boot on BIOS machines only." });
        try idx.append(ui.arena, null);
    }
    const intro = if (p.firmware == .uefi) "Which partition is the EFI System Partition? It must be FAT." else "Which partition is the EFI System Partition? (Optional on BIOS machines.)";
    const pick = try menu(ui, "EFI System Partition", intro, items.items, start) orelse return false;
    d.esp = if (idx.items[pick]) |i| disk.partitions[i] else null;
    d.format_esp = false;
    d.set_esp_type = false;
    return true;
}

fn screenEspType(ui: *Ui, d: *Draft) !bool {
    const e = d.esp.?;
    const items = [_]Item{
        .{ .label = "Set its type to EFI System", .sub = "One sfdisk --part-type step, shown in the summary." },
        .{ .label = "Leave its type alone", .sub = "The install will be refused: firmware can't find an ESP with the wrong type." },
    };
    const pick = try menu(ui, "Wrong partition type", ui.fmt("{s} is not typed as an EFI System Partition (type {s}).", .{ e.path, e.parttype orelse "none" }), &items, 0) orelse return false;
    d.set_esp_type = pick == 0;
    return true;
}

fn screenEspFormat(ui: *Ui, d: *Draft) !bool {
    const e = d.esp.?;
    const items = [_]Item{
        .{ .label = "Keep it as it is", .sub = "Other systems' bootloaders on it are kept. It must already be FAT." },
        .{ .label = "Format it as FAT32", .sub = "Everything on it is lost.", .sub_attr = warn },
    };
    const pick = try menu(ui, "Format the ESP?", ui.fmt("{s}: {s}", .{ e.path, e.fstype orelse "no filesystem" }), &items, if (d.format_esp) 1 else 0) orelse return false;
    d.format_esp = pick == 1;
    return true;
}

fn screenBiosBoot(ui: *Ui, d: *Draft) !bool {
    const disk = d.disk.?;
    var items: std.ArrayList(Item) = .empty;
    var idx: std.ArrayList(usize) = .empty;
    for (disk.partitions, 0..) |q, i| {
        if (!plan_mod.biosBootCandidate(q)) continue;
        if (std.mem.eql(u8, q.path, d.root.?.path)) continue;
        if (d.esp) |e| if (std.mem.eql(u8, q.path, e.path)) continue;
        try items.append(ui.arena, .{
            .label = ui.fmt("{s}  {s}", .{ q.path, fmtSize(ui.arena, q.size) }),
            .detail = "no filesystem",
            .sub = "Its type will be set to BIOS boot and its contents overwritten.",
            .sub_attr = warn,
        });
        try idx.append(ui.arena, i);
    }
    if (items.items.len == 0) {
        _ = try message(ui, "BIOS boot partition", &.{"Booting a GPT disk on a BIOS machine needs a BIOS boot partition. Only a partition of 1 to 16 MiB with no filesystem can be used, and there is none. Make one with fdisk or gdisk, then run the installer again."}, danger, "Esc: back");
        return false;
    }
    const pick = try menu(ui, "BIOS boot partition", "A GPT disk on a BIOS machine needs a BIOS boot partition (1 MiB or more) for dklilo's stage 2.", items.items, 0) orelse return false;
    d.bios_boot = disk.partitions[idx.items[pick]];
    d.set_bios_boot_type = true;
    return true;
}

fn screenPassword(ui: *Ui, title: []const u8, out: *[]const u8) !bool {
    while (true) {
        const first = try input(ui, title, "Type the password. It can't be empty.", "", .{ .secret = true, .validate = nonEmpty }) orelse return false;
        const again = try input(ui, title, "Type it again to confirm.", "", .{ .secret = true, .expect = first, .mismatch = "The two passwords don't match." }) orelse continue;
        out.* = first;
        _ = again;
        return true;
    }
}

/// Offers the block devices that might hold a repository (never the target
/// disk); the chosen one is mounted read-only at /mnt/cdrom. True to go on
/// (with or without a repository), false for Esc.
fn screenRepoPick(ui: *Ui, p: *Probe, env: Env, d: *Draft) !bool {
    _ = env;
    const cands = try probe_mod.repoCandidates(ui.arena, p.*, if (d.disk) |dk| dk.name else "");
    while (true) {
        var items: std.ArrayList(Item) = .empty;
        try items.append(ui.arena, .{ .label = "No extra packages", .detail = "install the system as it is" });
        for (cands) |c| {
            try items.append(ui.arena, .{
                .label = c.path,
                .detail = ui.fmt("{s}  {s}  {s}", .{ c.fstype, c.label orelse "", fmtSize(ui.arena, c.size) }),
            });
        }
        const pick = try menu(ui, "Package repository", "Extra packages can be installed from a repository disc or USB stick (apks/<arch>/ with a signed index). Choose the device that holds it; it is mounted read-only at " ++ probe_mod.repo_mount_point ++ ". The target disk is never offered.", items.items, 0) orelse return false;
        if (pick == 0) return true;
        const c = cands[pick - 1];
        if (mountRepo(ui, p, c.path)) |why| {
            _ = try message(ui, "Package repository", &.{ui.fmt("{s}: {s}", .{ c.path, why })}, warn, "Enter: back");
            continue;
        }
        return true;
    }
}

/// Mounts `dev` read-only and looks for a repository on it. Returns why not,
/// or null with `p.repo` set.
fn mountDevice(ui: *Ui, dev: []const u8) ?[]const u8 {
    const mp = probe_mod.repo_mount_point;
    const io = ui.io orelse return "can't mount here";
    Io.Dir.cwd().createDirPath(io, mp) catch {};
    const r = std.process.run(ui.arena, io, .{ .argv = &.{ "mount", "-o", "ro", dev, mp } }) catch return "mount could not run";
    if (!r.term.success()) return ui.fmt("mount failed: {s}", .{std.mem.trim(u8, r.stderr, " \n")});
    return null;
}

fn mountRepo(ui: *Ui, p: *Probe, dev: []const u8) ?[]const u8 {
    const mp = probe_mod.repo_mount_point;
    if (mountDevice(ui, dev)) |why| return why;
    const io = ui.io.?;
    const repo = probe_mod.repoAt(ui.arena, io, mp, probe_mod.repoArch()) catch null;
    if (repo) |rp| {
        var rr = rp;
        rr.mounted_dev = dev;
        p.repo = rr;
        return null;
    }
    _ = std.process.run(ui.arena, io, .{ .argv = &.{ "umount", mp } }) catch {};
    return ui.fmt("no apks/{s}/ with an index on it", .{probe_mod.repoArch()});
}

fn packageError(s: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t,");
    while (it.next()) |t| if (!answers_mod.validPackageName(t)) return "Not a valid package name (letters, digits and . _ + -; not starting with -).";
    return null;
}

/// "Additional packages from <repo>": the sets from the medium to tick, or a
/// free-text list when it has none. Empty means none.
fn screenPackages(ui: *Ui, repo: probe_mod.Repo, d: *Draft) !bool {
    const title = ui.fmt("Additional packages from {s}", .{repo.root});
    if (repo.sets.len == 0) {
        while (true) {
            const typed = try input(ui, title, "This repository has no package sets. Type the names of the packages to install, separated by spaces, or leave empty for none.", "", .{ .validate = packageError }) orelse return false;
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, typed, " \t,");
            while (it.next()) |t| try list.append(ui.arena, t);
            d.packages = list.items;
            if (list.items.len == 0) return true;
            if (!try screenTrustKey(ui, repo, d)) continue;
            if (try screenKeepRepo(ui, d)) return true;
        }
    }
    const ticked = try ui.arena.alloc(bool, repo.sets.len);
    @memset(ticked, false);
    var cur: usize = 0;
    while (true) {
        var items: std.ArrayList(Item) = .empty;
        for (repo.sets, 0..) |set, i| {
            try items.append(ui.arena, .{
                .label = ui.fmt("[{c}] {s}", .{ @as(u8, if (ticked[i]) 'x' else ' '), set.name }),
                .detail = set.description,
            });
        }
        try items.append(ui.arena, .{ .label = "Done", .detail = "install the ticked sets (none ticked: no extra packages)" });
        const pick = try menu(ui, title, "Enter ticks or unticks a set. Choose Done when finished.", items.items, cur) orelse return false;
        cur = pick;
        if (pick < repo.sets.len) {
            ticked[pick] = !ticked[pick];
            continue;
        }
        var list: std.ArrayList([]const u8) = .empty;
        for (repo.sets, 0..) |set, i| if (ticked[i]) try list.appendSlice(ui.arena, set.packages);
        d.packages = list.items;
        if (list.items.len == 0) return true;
        if (!try screenTrustKey(ui, repo, d)) continue;
        if (try screenKeepRepo(ui, d)) return true;
    }
}

/// Asks before using a key only the medium vouches for. False: don't (back to the packages).
fn screenTrustKey(ui: *Ui, repo: probe_mod.Repo, d: *Draft) !bool {
    d.trust_medium_key = false;
    if (repo.keys.len == 0 or repo.keys_trusted) return true;
    const digest = if (ui.io) |io| probe_mod.keyDigest(ui.arena, io, repo.keys[0]) else "(unreadable)";
    const intro = ui.fmt("This repository is signed with a key the system does not already trust, so only the medium itself vouches for its packages, and their scripts run as root. Use it only if you know where the medium came from. {d} key(s); the first: {s} SHA-256 {s}", .{ repo.keys.len, repo.keys[0], digest });
    const ok = try yesNo(ui, "Unknown signing key", intro, "trust this medium's key", "go back (choose no packages to skip)", false) orelse return false;
    d.trust_medium_key = ok;
    return ok;
}

fn screenKeepRepo(ui: *Ui, d: *Draft) !bool {
    const items = [_]Item{
        .{ .label = "No", .detail = "leave /etc/apk/repositories alone" },
        .{ .label = "Yes", .detail = "add it, commented out, with an explanation" },
    };
    const pick = try menu(ui, "Keep this repository in the installed system?", "The packages are installed offline from the medium. If you keep the repository, the installed system gets a commented-out line for it in /etc/apk/repositories, for use when the medium is mounted again.", &items, if (d.keep_repo) 1 else 0) orelse return false;
    d.keep_repo = pick == 1;
    return true;
}

/// True when zoneinfo is there and has no such zone (a bare image with no
/// zoneinfo accepts any valid name).
fn zoneMissing(ui: *Ui, zone: []const u8) bool {
    const io = ui.io orelse return false;
    Io.Dir.accessAbsolute(io, "/usr/share/zoneinfo", .{}) catch return false;
    const path = ui.fmt("/usr/share/zoneinfo/{s}", .{zone});
    Io.Dir.accessAbsolute(io, path, .{}) catch return true;
    return false;
}

// ---- services, ssh, other

fn ipError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validCidr(s)) null else "Not an address with prefix, for example 192.168.1.5/24 or 2001:db8::5/64.";
}

fn optIpError(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    return if (answers_mod.validIp(s)) null else "Not an IP address.";
}

fn dnsError(s: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t,");
    while (it.next()) |t| if (!answers_mod.validIp(t)) return "Not a list of IP addresses (separated by spaces).";
    return null;
}

fn ssidError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validSsid(s)) null else "1-32 printable characters, no backslash or double quote.";
}

fn pskError(s: []const u8) ?[]const u8 {
    return if (answers_mod.validPsk(s)) null else "8-63 printable characters, no backslash or double quote.";
}

/// SSIDs in range, from nmcli or iw on the live system; empty if neither works.
fn scanWifi(ui: *Ui, p: Probe) ![]const []const u8 {
    const io = ui.io orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    if (std.process.run(ui.arena, io, .{ .argv = &.{ "nmcli", "-t", "-f", "SSID", "device", "wifi", "list" } })) |r| {
        if (r.term.success()) {
            var it = std.mem.splitScalar(u8, r.stdout, '\n');
            while (it.next()) |l| if (l.len > 0 and answers_mod.validSsid(l)) try addUnique(ui, &out, l);
            return out.items;
        }
    } else |_| {}
    for (p.net_ifaces) |ifc| {
        if (!ifc.wireless) continue;
        const r = std.process.run(ui.arena, io, .{ .argv = &.{ "iw", "dev", ifc.name, "scan" } }) catch continue;
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |l| {
            const t = std.mem.trim(u8, l, " \t");
            if (std.mem.startsWith(u8, t, "SSID: ") and answers_mod.validSsid(t[6..])) try addUnique(ui, &out, t[6..]);
        }
    }
    return out.items;
}

fn addUnique(ui: *Ui, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
    try list.append(ui.arena, s);
}

/// Tries the connection on the live system. Returns the result line. The passphrase goes to
/// NetworkManager in a root-only connection file: a command line can be read by any user. The
/// file is in /run; after a success the live session stays connected.
fn testWifi(ui: *Ui, wf: answers_mod.Wifi) []const u8 {
    const io = ui.io orelse return "can't test here";
    const id = "dk-wifi-test";
    const dir = "/run/NetworkManager/system-connections";
    const path = dir ++ "/" ++ id ++ ".nmconnection";
    const text = plan_mod.wifiKeyfile(ui.arena, id, "6b2f0c3e-8d1a-4a57-9c2e-1f4b7a9d0e31", wf) catch return "out of memory";
    Io.Dir.cwd().createDirPath(io, dir) catch return "can't write the test connection; not tested.";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } }) catch return "can't write the test connection; not tested.";
    const steps = [_][]const []const u8{ &.{ "nmcli", "connection", "load", path }, &.{ "nmcli", "connection", "up", "id", id } };
    for (steps) |argv| {
        const r = std.process.run(ui.arena, io, .{ .argv = argv }) catch {
            Io.Dir.cwd().deleteFile(io, path) catch {};
            return "nmcli is not available on the live system; not tested.";
        };
        if (!r.term.success()) {
            _ = std.process.run(ui.arena, io, .{ .argv = &.{ "nmcli", "connection", "delete", "id", id } }) catch {};
            Io.Dir.cwd().deleteFile(io, path) catch {};
            return ui.fmt("Failed: {s}", .{std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n")});
        }
    }
    return "Connected. The live session stays connected until it is restarted.";
}

/// The network screens: how (guided, copy the live connection, manual, skip),
/// then for guided: each wired interface, DNS, search domain, WiFi. Esc goes
/// back a step; the first Esc leaves.
fn screenNetwork(ui: *Ui, p: *Probe, d: *Draft) !bool {
    var net: answers_mod.Network = d.network orelse .{};
    var ifaces: std.ArrayList(answers_mod.Iface) = .empty;
    var step: usize = 0;
    while (true) {
        switch (step) {
            0 => {
                var items: std.ArrayList(Item) = .empty;
                var map: std.ArrayList(u8) = .empty; // item -> 0 guided 1 copy 2 manual 3 shell 4 skip
                try items.append(ui.arena, .{ .label = "Guided (DHCP/static/WiFi)", .detail = "choose per interface, DNS and WiFi" });
                try map.append(ui.arena, 0);
                if (p.net_stack == .networkmanager and p.live_connections.len > 0) {
                    try items.append(ui.arena, .{ .label = "Copy the live session's connection", .detail = "the one you set up in this live session" });
                    try map.append(ui.arena, 1);
                }
                try items.append(ui.arena, .{ .label = "Manual: configure nothing, network services off", .detail = "set it up after the first boot" });
                try map.append(ui.arena, 2);
                try items.append(ui.arena, .{ .label = "Manual: configure by hand now", .detail = "a shell in the new system during the install" });
                try map.append(ui.arena, 3);
                try items.append(ui.arena, .{ .label = "Skip: as the image has it", .detail = "DHCP on wired interfaces by the system's own default" });
                try map.append(ui.arena, 4);
                const stack_name = switch (p.net_stack) {
                    .networkmanager => "NetworkManager",
                    .dhcpcd => "dhcpcd and wpa_supplicant",
                    .none => "none",
                };
                const pick = try menu(ui, "Network", ui.fmt("The new system uses {s}. How do you want to set up its network?", .{stack_name}), items.items, 0) orelse return false;
                switch (map.items[pick]) {
                    0 => {
                        net.mode = .guided;
                        step = 1;
                    },
                    1 => {
                        var ci: std.ArrayList(Item) = .empty;
                        for (p.live_connections) |c| try ci.append(ui.arena, .{ .label = c });
                        const cp = try menu(ui, "Live connection", "Choose the connection to copy to the new system.", ci.items, 0) orelse continue;
                        net = .{ .mode = .copy, .copy = p.live_connections[cp] };
                        d.network = net;
                        return true;
                    },
                    2 => {
                        d.network = .{ .mode = .manual };
                        return true;
                    },
                    3 => {
                        d.network = .{ .mode = .@"manual-shell" };
                        return true;
                    },
                    else => {
                        d.network = null;
                        return true;
                    },
                }
            },
            1 => { // wired interfaces
                ifaces.clearRetainingCapacity();
                var i: usize = 0;
                var back = false;
                for (p.net_ifaces) |ifc| {
                    if (ifc.wireless) continue;
                    const items = [_]Item{
                        .{ .label = "DHCP", .detail = "automatic (default)" },
                        .{ .label = "Static", .detail = "address, gateway" },
                        .{ .label = "Disabled", .detail = "not brought up" },
                    };
                    const pick = try menu(ui, ui.fmt("Interface {s}", .{ifc.name}), "How should this interface get its address?", &items, 0) orelse {
                        back = true;
                        break;
                    };
                    i += 1;
                    if (pick == 0) {
                        try ifaces.append(ui.arena, .{ .name = ifc.name, .kind = .dhcp });
                    } else if (pick == 2) {
                        try ifaces.append(ui.arena, .{ .name = ifc.name, .kind = .disabled });
                    } else {
                        const addr = try input(ui, ui.fmt("{s}: address", .{ifc.name}), "Address and prefix length, IPv4 or IPv6, for example 192.168.1.5/24.", "", .{ .validate = ipError }) orelse {
                            back = true;
                            break;
                        };
                        const gw = try input(ui, ui.fmt("{s}: gateway", .{ifc.name}), "Default gateway (same family as the address). Leave empty for none.", "", .{ .validate = optIpError }) orelse {
                            back = true;
                            break;
                        };
                        try ifaces.append(ui.arena, .{ .name = ifc.name, .kind = .static, .address = addr, .gateway = if (gw.len > 0) gw else null });
                    }
                }
                if (back) {
                    step = 0;
                    continue;
                }
                net.ifaces = ifaces.items;
                step = 2;
            },
            2 => {
                const joined = try std.mem.join(ui.arena, " ", net.dns);
                const v = try input(ui, "DNS servers", "DNS servers for these connections, IPv4 or IPv6, separated by spaces. Leave empty to take them from DHCP.", joined, .{ .validate = dnsError }) orelse {
                    step = 1;
                    continue;
                };
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.tokenizeAny(u8, v, " \t,");
                while (it.next()) |t| try list.append(ui.arena, t);
                net.dns = list.items;
                step = 3;
            },
            3 => {
                const v = try input(ui, "Search domain", "DNS search domain. Leave empty for none.", net.search orelse "", .{ .validate = domainError }) orelse {
                    step = 2;
                    continue;
                };
                net.search = if (v.len == 0) null else v;
                var any_wifi = false;
                for (p.net_ifaces) |ifc| if (ifc.wireless) {
                    any_wifi = true;
                };
                if (net.ifaces.len == 0 and net.dns.len > 0) net.dns = &.{};
                if (!any_wifi) {
                    d.network = net;
                    return true;
                }
                step = 4;
            },
            else => { // WiFi
                var items: std.ArrayList(Item) = .empty;
                try items.append(ui.arena, .{ .label = "No WiFi", .detail = "skip" });
                try items.append(ui.arena, .{ .label = "Type the network name", .detail = "a hidden network, or one not listed" });
                const found = try scanWifi(ui, p.*);
                for (found) |n| try items.append(ui.arena, .{ .label = n });
                const pick = try menu(ui, "WiFi", "Connect to a wireless network. Networks in range are listed when the live system can scan.", items.items, 0) orelse {
                    step = 3;
                    continue;
                };
                if (pick == 0) {
                    net.wifi = null;
                    d.network = net;
                    return true;
                }
                var hidden = false;
                const ssid = if (pick == 1) blk: {
                    hidden = true;
                    break :blk try input(ui, "WiFi name", "The network name (SSID).", "", .{ .validate = ssidError }) orelse continue;
                } else found[pick - 2];
                const psk = try input(ui, ui.fmt("Passphrase for {s}", .{ssid}), "The WPA passphrase (8-63 characters). It is never shown or logged.", "", .{ .secret = true, .validate = pskError }) orelse continue;
                if (pick != 1) hidden = (try yesNo(ui, "Hidden network", "Is this network hidden (does it not announce its name)?", "hidden", "visible", false)) orelse continue;
                const wf: answers_mod.Wifi = .{ .ssid = ssid, .psk = psk, .hidden = hidden };
                if (try yesNo(ui, "Test the connection", "Try to connect now, on the live system?", "test it", "skip the test", false) orelse false) {
                    _ = try message(ui, "WiFi test", &.{testWifi(ui, wf)}, normal, "Enter: continue");
                }
                net.wifi = wf;
                d.network = net;
                return true;
            },
        }
    }
}

fn netService(name: []const u8) bool {
    for (probe_mod.net_service_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn serviceItems(ui: *Ui, p: Probe, d: *Draft) ![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const mode: ?answers_mod.NetMode = if (d.network) |n| n.mode else null;
    for (p.services, 0..) |sv, i| {
        const net_svc = netService(sv.name);
        const note: []const u8 = if (net_svc and mode == .@"manual-shell") "   (set by hand)" else if (net_svc and mode == .manual) "   (off: manual network)" else if (sv.network) "   (network server)" else if (sv.missing_dep != null) "   (missing dependency)" else if (sv.core) "   (needed)" else "";
        const shown = if (net_svc and mode == .manual) false else d.svc_on[i];
        try items.append(ui.arena, .{
            .label = ui.fmt("[{c}] {s}{s}", .{ @as(u8, if (shown) 'x' else ' '), sv.name, note }),
            .detail = sv.label,
            .enabled = !sv.core and (sv.enabled or sv.missing_dep == null) and !(net_svc and (mode == .manual or mode == .@"manual-shell")),
        });
    }
    try items.append(ui.arena, .{ .label = "Done", .detail = "keep these choices" });
    return items.items;
}

/// Ticks the dinit services that start at boot. Starts as the image has them.
fn screenServices(ui: *Ui, p: Probe, d: *Draft) !bool {
    if (d.svc_on.len != p.services.len) {
        d.svc_on = try ui.arena.alloc(bool, p.services.len);
        for (p.services, 0..) |sv, i| d.svc_on[i] = sv.enabled;
    }
    var cur: usize = 0;
    while (true) {
        const items = try serviceItems(ui, p, d);
        const pick = try menu(ui, "Services", "Services started at boot. Enter ticks or unticks one. Servers that listen on the network are marked; they stay as the image has them unless you change them.", items, cur) orelse return false;
        cur = pick;
        if (pick == p.services.len) return true;
        d.svc_on[pick] = !d.svc_on[pick];
    }
}

fn yesNo(ui: *Ui, title: []const u8, intro: []const u8, yes: []const u8, no: []const u8, start_yes: bool) !?bool {
    const items = [_]Item{ .{ .label = "Yes", .detail = yes }, .{ .label = "No", .detail = no } };
    const pick = try menu(ui, title, intro, &items, if (start_yes) 0 else 1) orelse return null;
    return pick == 0;
}

/// Runs `ssh-keygen -l -f` on `key`; null when it is a key, else why not.
/// If ssh-keygen can't be run the key is accepted on its syntax.
fn checkKey(ui: *Ui, key: []const u8) ?[]const u8 {
    const io = ui.io orelse return null;
    const dir = "/run/dkrescue-install";
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    const path = dir ++ "/key-check.pub";
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ui.fmt("{s}\n", .{key}) }) catch return null;
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const r = std.process.run(ui.arena, io, .{ .argv = &.{ "ssh-keygen", "-l", "-f", path } }) catch return null;
    if (r.term.success()) return null;
    return ui.fmt("ssh-keygen: {s}", .{std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n")});
}

fn keyError(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    return if (answers_mod.validPubKey(std.mem.trim(u8, s, " \t"))) null else "Not an OpenSSH public key line (ssh-ed25519 AAAA... comment).";
}

/// A key file from a mounted medium. Null: back; "" never.
fn pickKeyFile(ui: *Ui, p: *Probe, d: *Draft) !?[]const u8 {
    const io = ui.io orelse return null;
    while (true) {
        const found = try probe_mod.findPubFiles(ui.arena, io, &probe_mod.key_roots);
        var items: std.ArrayList(Item) = .empty;
        for (found) |f| try items.append(ui.arena, .{ .label = f });
        try items.append(ui.arena, .{ .label = "Type a path...", .detail = "a key file on a medium that is already mounted" });
        try items.append(ui.arena, .{ .label = "Mount a disc or USB stick...", .detail = "read-only at " ++ probe_mod.repo_mount_point });
        const pick = try menu(ui, "Key file", "Public key files found on mounted media (/mnt/cdrom, /media, ...).", items.items, 0) orelse return null;
        var path: []const u8 = undefined;
        if (pick < found.len) {
            path = found[pick];
        } else if (pick == found.len) {
            path = try input(ui, "Key file", "Path of a public key file.", "", .{ .validate = nonEmpty }) orelse continue;
        } else {
            const cands = try probe_mod.repoCandidates(ui.arena, p.*, if (d.disk) |dk| dk.name else "");
            var ci: std.ArrayList(Item) = .empty;
            for (cands) |c| try ci.append(ui.arena, .{ .label = c.path, .detail = ui.fmt("{s}  {s}  {s}", .{ c.fstype, c.label orelse "", fmtSize(ui.arena, c.size) }) });
            const cp = try menu(ui, "Mount", "Choose the device to mount read-only. The target disk is not offered.", ci.items, 0) orelse continue;
            if (mountDevice(ui, cands[cp].path)) |why| _ = try message(ui, "Mount", &.{why}, warn, "Enter: back");
            continue;
        }
        const text = Io.Dir.cwd().readFileAlloc(io, path, ui.arena, .limited(64 * 1024)) catch {
            _ = try message(ui, "Key file", &.{ui.fmt("Can't read {s}.", .{path})}, warn, "Enter: back");
            continue;
        };
        const line = probe_mod.firstKeyLine(text) orelse {
            _ = try message(ui, "Key file", &.{"The file has no key line."}, warn, "Enter: back");
            continue;
        };
        const key = std.mem.trim(u8, line, " \t");
        if (!answers_mod.validPubKey(key)) {
            _ = try message(ui, "Key file", &.{"That is not an OpenSSH public key."}, warn, "Enter: back");
            continue;
        }
        return key;
    }
}

/// The SSH screens, shown only when sshd is ticked in the services list: root
/// login, password login, the user's key. Esc goes back a step; the first Esc
/// leaves.
fn screenSsh(ui: *Ui, p: *Probe, d: *Draft) !bool {
    var s: answers_mod.Ssh = d.ssh orelse .{};
    s.enable = true;
    var step: usize = 0;
    while (true) {
        switch (step) {
            0 => {
                const items = [_]Item{
                    .{ .label = "Keep the image's SSH settings", .detail = "sshd starts at boot" },
                    .{ .label = "Set up SSH", .detail = "root login, passwords, keys" },
                };
                const pick = try menu(ui, "SSH", "Remote login over ssh. The sshd settings go in a drop-in file in /etc/ssh/sshd_config.d/; sshd_config itself is not rewritten.", &items, if (d.ssh != null) 1 else 0) orelse return false;
                if (pick == 0) {
                    d.ssh = null;
                    return true;
                }
                step = 2;
            },
            2 => {
                const items = [_]Item{
                    .{ .label = "no", .detail = "root can't log in over ssh (default)" },
                    .{ .label = "prohibit-password", .detail = "root with a key only" },
                    .{ .label = "yes", .detail = "root with a password too (not recommended)" },
                };
                const pick = try menu(ui, "Root login over ssh", "May root log in over ssh?", &items, @backingInt(s.root_login)) orelse {
                    step = 0;
                    continue;
                };
                s.root_login = @fromBackingInt(@intCast(pick));
                step = 3;
            },
            3 => {
                const pw = try yesNo(ui, "Password login over ssh", "Allow logging in over ssh with a password?", "passwords and keys both work", "keys only (set up a key next)", s.password_auth) orelse {
                    step = 2;
                    continue;
                };
                s.password_auth = pw;
                step = 4;
            },
            4 => {
                const items = [_]Item{
                    .{ .label = "No key", .detail = "no authorized_keys for the new user" },
                    .{ .label = "Paste a public key", .detail = "one line: ssh-ed25519 AAAA... comment" },
                    .{ .label = "Read a key file", .detail = "from a mounted disc or USB stick" },
                    .{ .label = "Generate a key pair", .detail = "ed25519, for the new user; the fingerprint is shown at the end" },
                };
                const pick = try menu(ui, "Key for the new user", "A public key lets the user log in over ssh without a password.", &items, 0) orelse {
                    step = 3;
                    continue;
                };
                s.authorized_key = null;
                s.generate_key = false;
                switch (pick) {
                    0 => {},
                    1 => {
                        while (true) {
                            const typed = try input(ui, "Public key", "Paste the public key (one line).", "", .{ .validate = keyError }) orelse break;
                            const k = std.mem.trim(u8, typed, " \t");
                            if (k.len == 0) break;
                            if (checkKey(ui, k)) |why| {
                                _ = try message(ui, "Public key", &.{why}, warn, "Enter: back");
                                continue;
                            }
                            s.authorized_key = k;
                            break;
                        }
                    },
                    2 => if (try pickKeyFile(ui, p, d)) |k| {
                        if (checkKey(ui, k)) |why| {
                            _ = try message(ui, "Public key", &.{why}, warn, "Enter: back");
                        } else s.authorized_key = k;
                    },
                    else => s.generate_key = true,
                }
                step = 5;
            },
            else => {
                if (!s.password_auth and s.authorized_key == null and !s.generate_key) {
                    const ok = try yesNo(ui, "No way to log in over ssh", "Passwords are off and no key is set up: nobody could log in over ssh. Go on anyway?", "go on, I will add a key later", "go back and choose a key or allow passwords", false) orelse {
                        step = 4;
                        continue;
                    };
                    if (!ok) {
                        step = 4;
                        continue;
                    }
                    s.allow_lockout = true;
                } else s.allow_lockout = false;
                d.ssh = s;
                return true;
            },
        }
    }
}

/// SELinux mode, starting at "as the image has it". NTP and the firewall are
/// chosen in the services list.
fn screenOther(ui: *Ui, d: *Draft) !bool {
    const items = [_]Item{
        .{ .label = "As the image has it", .detail = "permissive: denials are logged, not enforced" },
        .{ .label = "permissive", .detail = "log denials only" },
        .{ .label = "enforcing", .detail = "enforce the policy" },
        .{ .label = "disabled", .detail = "no SELinux" },
    };
    const pick = try menu(ui, "SELinux mode", "Written to /etc/selinux/config in the new system.", &items, if (d.selinux) |m| @as(usize, @backingInt(m)) + 1 else 0) orelse return false;
    d.selinux = if (pick == 0) null else @fromBackingInt(@intCast(pick - 1));
    return true;
}

fn ssh_on_summary(a: answers_mod.Answers, p: Probe) bool {
    if (a.ssh) |sh| if (sh.enable) |e| return e;
    for (a.services_enable) |n| if (std.mem.eql(u8, n, "sshd")) return true;
    for (a.services_disable) |n| if (std.mem.eql(u8, n, "sshd")) return false;
    if (probe_mod.findService(p.services, "sshd")) |sv| return sv.enabled;
    return false;
}

fn buildAnswers(ui: *Ui, d: *const Draft, p: Probe) !answers_mod.Answers {
    var en: std.ArrayList([]const u8) = .empty;
    var dis: std.ArrayList([]const u8) = .empty;
    const nm: ?answers_mod.NetMode = if (d.network) |n| n.mode else null;
    if (d.svc_on.len == p.services.len) for (p.services, 0..) |sv, i| {
        if (netService(sv.name) and (nm == .manual or nm == .@"manual-shell")) continue;
        if (d.svc_on[i] and !sv.enabled) try en.append(ui.arena, sv.name);
        if (!d.svc_on[i] and sv.enabled) try dis.append(ui.arena, sv.name);
    };
    return .{
        .domain = d.domain,
        .network = d.network,
        .services_enable = en.items,
        .services_disable = dis.items,
        .ssh = d.ssh,
        .selinux = d.selinux,
        .disk = d.disk.?.name,
        .partitioning = d.partitioning,
        .root_fs = d.root_fs,
        .bootloader = d.bootloader,
        .root = if (d.root) |r| r.name else null,
        .esp = if (d.esp) |e| e.name else null,
        .bios_boot = if (d.bios_boot) |b| b.name else null,
        .format_esp = d.format_esp,
        .set_esp_type = d.set_esp_type,
        .set_bios_boot_type = d.set_bios_boot_type,
        .hostname = d.hostname,
        .root_pw = .{ .plain = d.root_pw },
        .user = d.user,
        .user_pw = .{ .plain = d.user_pw },
        .timezone = d.timezone,
        .keymap = d.keymap,
        .packages = d.packages,
        .keep_repo = d.keep_repo,
        .trust_medium_key = d.trust_medium_key,
    };
}

/// Builds the summary, asks for the typed confirmation. Null means back.
fn screenSummary(ui: *Ui, p: Probe, env: Env, d: *const Draft) !?Done {
    const a = try buildAnswers(ui, d, p);
    const disk = d.disk.?;
    const result = try plan_mod.build(ui.arena, p, a, env.ids);
    const plan = switch (result) {
        .plan => |pl| pl,
        .refused => |why| {
            _ = try message(ui, "This can't be installed", &.{why}, danger, "Enter or Esc: back");
            return null;
        },
    };

    var lines: std.ArrayList(Line) = .empty;
    try lines.append(ui.arena, .{ .text = ui.fmt("Disk: /dev/{s}  {s}  {s}", .{ disk.name, fmtSize(ui.arena, disk.size), disk.model orelse "" }), .attr = bold });
    if (d.partitioning == .auto) {
        try lines.append(ui.arena, .{ .text = "The whole disk will be ERASED:", .attr = danger });
        if (describeContents(ui.arena, disk)) |c| {
            try lines.append(ui.arena, .{ .text = ui.fmt("  found: {s}", .{c}), .attr = danger });
        } else try lines.append(ui.arena, .{ .text = "  (nothing found on it)", .attr = dim });
        try lines.append(ui.arena, .{ .text = ui.fmt("Layout: 1 MiB BIOS boot, 512 MiB ESP (FAT32), rest root ({s})", .{fs_mod.info(d.root_fs).name}) });
    } else {
        try lines.append(ui.arena, .{ .text = ui.fmt("Root {s} will be FORMATTED ({s}); everything on it is lost.", .{ d.root.?.path, fs_mod.info(d.root_fs).name }), .attr = danger });
        if (d.esp) |e| {
            try lines.append(ui.arena, if (d.format_esp)
                .{ .text = ui.fmt("ESP {s} will be FORMATTED (FAT32).", .{e.path}), .attr = danger }
            else
                .{ .text = ui.fmt("ESP {s} is kept as it is.", .{e.path}) });
        }
        if (d.set_esp_type) try lines.append(ui.arena, .{ .text = "The ESP's partition type will be changed.", .attr = warn });
        if (d.set_bios_boot_type) try lines.append(ui.arena, .{ .text = ui.fmt("{s} will become the BIOS boot partition; its contents are OVERWRITTEN.", .{d.bios_boot.?.path}), .attr = danger });
    }
    try lines.append(ui.arena, .{ .text = ui.fmt("Boot loader: {s}   Root filesystem: {s}", .{ bl_mod.info(d.bootloader).name, fs_mod.info(d.root_fs).name }) });
    try lines.append(ui.arena, .{ .text = ui.fmt("Hostname: {s}   User: {s}   Timezone: {s}   Keymap: {s}", .{ d.hostname, d.user, d.timezone, d.keymap }) });
    try lines.append(ui.arena, .{ .text = "Passwords: root set, user set" });
    if (a.network) |n| {
        switch (n.mode) {
            .guided => {
                try lines.append(ui.arena, .{ .text = ui.fmt("Network: {d} interface setting(s){s}", .{ n.ifaces.len, if (n.wifi != null) ", WiFi (passphrase hidden)" else "" }) });
            },
            .copy => try lines.append(ui.arena, .{ .text = ui.fmt("Network: copy the live connection {s}", .{n.copy orelse "?"}) }),
            .manual => {
                try lines.append(ui.arena, .{ .text = "Network: NOT configured; network services off.", .attr = warn });
                try lines.append(ui.arena, .{ .text = "  The installed system has no network until you configure it.", .attr = warn });
                if (p.services.len > 0) if (ssh_on_summary(a, p)) try lines.append(ui.arena, .{ .text = "  sshd is enabled but will have nothing to listen on.", .attr = warn });
            },
            .@"manual-shell" => {
                try lines.append(ui.arena, .{ .text = "Network: configured by hand in a shell during the install.", .attr = warn });
                try lines.append(ui.arena, .{ .text = "  Without your changes the installed system has no network.", .attr = warn });
                if (ssh_on_summary(a, p)) try lines.append(ui.arena, .{ .text = "  sshd is enabled but will have nothing to listen on without a network.", .attr = warn });
            },
        }
    }
    for (a.services_enable) |n| try lines.append(ui.arena, .{ .text = ui.fmt("Service enabled at boot: {s}", .{n}) });
    for (a.services_disable) |n| try lines.append(ui.arena, .{ .text = ui.fmt("Service disabled at boot: {s}", .{n}) });
    if (a.ssh) |sh| try lines.append(ui.arena, .{ .text = ui.fmt("SSH: sshd {s}, root login {s}, passwords {s}, key: {s}", .{
        if (sh.enable) |e| (if (e) "on" else "off") else "as is",
        @tagName(sh.root_login),
        if (sh.password_auth) "allowed" else "off",
        if (sh.authorized_key != null) "given" else if (sh.generate_key) "generated" else "none",
    }), .attr = if (!sh.password_auth and sh.authorized_key == null and !sh.generate_key) warn else normal });
    if (a.ntp) |v| try lines.append(ui.arena, .{ .text = ui.fmt("NTP: {s}", .{if (v) "on" else "off"}) });
    if (a.firewall) |v| try lines.append(ui.arena, .{ .text = ui.fmt("Firewall: {s}", .{if (v) "on" else "off"}) });
    if (a.selinux) |m| try lines.append(ui.arena, .{ .text = ui.fmt("SELinux mode: {s}", .{@tagName(m)}) });
    if (d.packages.len > 0) {
        try lines.append(ui.arena, .{ .text = ui.fmt("Extra packages: {d} from {s}{s}", .{ d.packages.len, if (p.repo) |r| r.root else "?", if (d.keep_repo) " (repository kept, commented out)" else "" }) });
    }
    try lines.append(ui.arena, .{ .text = ui.fmt("Firmware: {s}", .{if (p.firmware == .uefi) "UEFI" else "BIOS"}) });
    try lines.append(ui.arena, .{ .text = "" });
    try lines.append(ui.arena, .{ .text = "Commands that will run:", .attr = bold });

    var w: Io.Writer.Allocating = .init(ui.arena);
    try plan.writeDryRun(&w.writer);
    var it = std.mem.splitScalar(u8, w.written(), '\n');
    while (it.next()) |l| {
        const attr: Attr = if (std.mem.startsWith(u8, l, "# ")) bold else normal;
        try lines.append(ui.arena, .{ .text = l, .attr = attr });
    }

    if (!try viewer(ui, "Summary", lines.items, "Up/Down, PgUp/PgDn: scroll   Enter: continue   Esc: back")) return null;

    const prompt = ui.fmt("This will erase data on /dev/{s}. To go on, type the disk's name ({s}) and press Enter.", .{ disk.name, disk.name });
    const typed = try input(ui, "Confirm", prompt, "", .{ .expect = disk.name, .mismatch = "That is not the disk's name." });
    if (typed == null) return null;
    return .{ .answers = a, .plan = plan };
}

// --------------------------------------------------------------- install

/// What the user chose when the install ended.
pub const InstallEnd = enum { reboot, live, quit };

const out_cols = 200;
const out_rows = 40;

/// What the progress screen shows while steps run.
const Progress = struct {
    ui: *Ui,
    steps: []const plan_mod.Step,
    stack: probe_mod.NetStack = .none,
    cur: usize = 0,
    text: []const u8 = "",
    /// Percentage from a progress-only output line (unsquashfs), if any.
    pct: ?u8 = null,
    lines: [out_rows][out_cols]u8 = undefined,
    lens: [out_rows]usize = @splat(0),
    count: usize = 0,

    fn onStart(ctx: ?*anyopaque, index: usize, _: plan_mod.Step, text: []const u8) void {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        self.cur = index;
        self.text = text;
        self.pct = null;
        self.draw();
    }

    fn onLine(ctx: ?*anyopaque, line: []const u8) void {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        if (execute.isPercent(line)) {
            self.pct = std.fmt.parseInt(u8, std.mem.trim(u8, line, " \t"), 10) catch null;
        } else {
            const slot = self.count % out_rows;
            const n = @min(line.len, out_cols);
            @memcpy(self.lines[slot][0..n], line[0..n]);
            self.lens[slot] = n;
            self.count += 1;
        }
        self.draw();
    }

    /// A soft step failed: show it with its output, and ask. Enter goes on.
    fn onSoftFail(ctx: ?*anyopaque, f: execute.Failure) bool {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        const ui = self.ui;
        while (true) {
            const r = ui.frame("A step had a problem", "Enter: continue the installation   Q: stop here");
            var y = r.y;
            _ = ui.screen.text(r.x, y, ui.fmt("Step {d}: {s}", .{ f.index + 1, f.desc }), warn, @intCast(r.w));
            y += 1;
            _ = ui.screen.text(r.x, y, ui.fmt("$ {s}", .{f.text}), dim, @intCast(r.w));
            y += 1;
            _ = ui.screen.text(r.x, y, f.reason, danger, @intCast(r.w));
            y += 2;
            for (f.tail) |l| {
                if (y >= r.y + r.h - 3) break;
                _ = ui.screen.text(r.x, y, l, normal, @intCast(r.w));
                y += 1;
            }
            _ = ui.screen.text(r.x, r.y + r.h - 2, "The base system is already installed. Going on is usually right.", normal, @intCast(r.w));
            _ = ui.screen.text(r.x, r.y + r.h - 1, ui.fmt("Log: {s}", .{execute.log_path}), dim, @intCast(r.w));
            const k = ui.key() catch return true;
            switch (k) {
                .enter => return true,
                .char => |c| if (c == 'q' or c == 'Q') return false,
                else => {},
            }
        }
    }

    /// The `shell` step: pause the screens, offer the shell and the editor.
    fn onShell(ctx: ?*anyopaque) void {
        const self: *Progress = @ptrCast(@alignCast(ctx.?));
        handConfig(self.ui, self.stack);
    }

    fn draw(self: *Progress) void {
        const ui = self.ui;
        const r = ui.frame("Installing", "Please wait. Nothing here can be interrupted safely.");
        const s = &ui.screen;
        const total = self.steps.len;
        const done_frac = self.cur * 100 / @max(total, 1);
        // The window of steps: two before, the current one, two after.
        var y = r.y;
        const first = self.cur -| 2;
        const last = @min(total, self.cur + 3);
        for (self.steps[first..last], first..) |st, i| {
            const mark: []const u8 = if (i < self.cur) "[ok]" else if (i == self.cur) "[..]" else "[  ]";
            const attr: Attr = if (i < self.cur) good else if (i == self.cur) bold else dim;
            _ = s.text(r.x, y, mark, attr, 4);
            _ = s.text(r.x + 5, y, st.desc, attr, @intCast(r.w - 5));
            y += 1;
        }
        y += 1;
        // Bar: the step count, and within a step the percentage if there is one.
        const bar_w: i32 = @min(r.w - 12, 60);
        const sub: usize = if (self.pct) |pc| pc else 0;
        const frac = (done_frac * 10 + sub * 10 / @max(total, 1)) / 10;
        const filled: i32 = @intCast(@as(usize, @intCast(bar_w)) * @min(frac, 100) / 100);
        _ = s.text(r.x, y, "[", normal, 1);
        for (0..@as(usize, @intCast(bar_w))) |i| {
            s.put(r.x + 1 + @as(i32, @intCast(i)), y, if (@as(i32, @intCast(i)) < filled) '#' else '-', normal);
        }
        _ = s.text(r.x + 1 + bar_w, y, "]", normal, 1);
        _ = s.text(r.x + 3 + bar_w, y, ui.fmt("{d}/{d}", .{ self.cur + 1, total }), normal, 8);
        y += 2;
        _ = s.text(r.x, y, ui.fmt("$ {s}", .{self.text}), dim, @intCast(r.w));
        y += 1;
        // The newest output lines that fit.
        const room: usize = @intCast(@max(0, r.y + r.h - y));
        const shown = @min(@min(room, self.count), out_rows);
        var k: usize = 0;
        while (k < shown) : (k += 1) {
            const slot = (self.count - shown + k) % out_rows;
            _ = s.text(r.x, y + @as(i32, @intCast(k)), self.lines[slot][0..self.lens[slot]], normal, @intCast(r.w));
        }
        ui.present() catch {};
    }
};

const edit_candidates = [_][]const u8{
    "/etc/NetworkManager/NetworkManager.conf", "/etc/dhcpcd.conf", "/etc/wpa_supplicant/wpa_supplicant.conf",
    "/etc/resolv.conf",                        "/etc/hosts",       "/etc/hostname",
};

/// Pauses the screens and runs `argv` in the target (shell or editor).
fn inTarget(ui: *Ui, stack: probe_mod.NetStack, argv: []const []const u8, banner: bool, installed: ?plan_mod.Plan) void {
    const io = ui.io orelse return;
    const t = ui.terminal orelse return;
    t.pause();
    if (banner) {
        const text = execute.shellBanner(ui.arena, stack) catch "";
        std.debug.print("{s}", .{text});
    }
    const why = if (installed) |pl| execute.shellInInstalled(ui.gpa, io, pl, argv) else execute.chrootRun(ui.gpa, io, argv);
    if (why) |w| std.debug.print("\n{s}\nPress Enter.\n", .{w});
    if (why != null) {
        var b: [1]u8 = undefined;
        _ = std.posix.read(0, &b) catch 0;
    }
    t.unpause();
    ui.screen.invalidate();
}

/// "Configure by hand": a shell in the target, or an editor on a config file,
/// until the user chooses to go on.
fn handConfig(ui: *Ui, stack: probe_mod.NetStack) void {
    const io = ui.io orelse return;
    while (true) {
        const items = [_]Item{
            .{ .label = "Open a shell in the new system", .detail = "chroot with /proc /sys /dev /run; type exit to come back" },
            .{ .label = "Edit a config file", .detail = "with $EDITOR (vi if unset)" },
            .{ .label = "Done: continue the installation" },
        };
        const pick = menu(ui, "Configure by hand", "The new system is mounted. Configure the network (and anything else) here; the installer carries on when you choose Done.", &items, 0) catch return orelse return;
        switch (pick) {
            0 => inTarget(ui, stack, &.{ "/bin/bash", "-l" }, true, null),
            1 => {
                var list: std.ArrayList(Item) = .empty;
                for (edit_candidates) |f| {
                    const full = ui.fmt("{s}{s}", .{ plan_mod.target, f });
                    Io.Dir.accessAbsolute(io, full, .{}) catch continue;
                    list.append(ui.arena, .{ .label = f }) catch return;
                }
                list.append(ui.arena, .{ .label = "Type a path..." }) catch return;
                const fp = menu(ui, "Edit a file", "Choose a file in the new system.", list.items, 0) catch return orelse continue;
                var path = list.items[fp].label;
                if (fp == list.items.len - 1) {
                    path = (input(ui, "Edit a file", "Path inside the new system, for example /etc/hosts.", "/etc/", .{ .validate = nonEmpty }) catch return) orelse continue;
                }
                inTarget(ui, stack, &.{ "/bin/sh", "-c", "exec ${EDITOR:-vi} \"$1\"", "sh", path }, false, null);
            },
            else => return,
        }
    }
}

/// Runs `plan` with the progress screen, then the failure (SPEC.md 5.7) or
/// completion screen. Needs the real terminal.
pub fn install(ui: *Ui, io: Io, plan: plan_mod.Plan, info: []const u8, stack: probe_mod.NetStack) !InstallEnd {
    const t = ui.terminal.?;
    const progress = try ui.gpa.create(Progress);
    defer ui.gpa.destroy(progress);
    progress.* = .{ .ui = ui, .steps = plan.steps, .stack = stack };
    var runner = try execute.Runner.init(ui.gpa, io, execute.log_path, .{
        .ctx = progress,
        .on_start = Progress.onStart,
        .on_line = Progress.onLine,
        .on_soft_fail = Progress.onSoftFail,
        .on_shell = Progress.onShell,
    });
    defer runner.deinit();
    runner.header(info);

    const outcome = try runner.run(plan.steps);
    switch (outcome) {
        .ok => {
            while (true) {
                const r = ui.frame("Installation complete", "R: reboot   L: live system   S: shell in the installed system");
                _ = ui.screen.text(r.x, r.y, "DKRescue is installed.", good, @intCast(r.w));
                _ = ui.screen.text(r.x, r.y + 2, ui.fmt("The log is at {s} on the new system.", .{plan_mod.target_log["/run/dkrescue-install/target".len..]}), normal, @intCast(r.w));
                _ = ui.screen.text(r.x, r.y + 3, "Remove the installation medium before the computer restarts.", normal, @intCast(r.w));
                var wy = r.y + 5;
                if (runner.notes.items.len > 0) {
                    _ = ui.screen.text(r.x, wy, "Key fingerprints:", bold, @intCast(r.w));
                    wy += 1;
                    for (runner.notes.items) |n| {
                        if (wy >= r.y + r.h - 1) break;
                        _ = ui.screen.text(r.x + 2, wy, n, normal, @intCast(r.w - 2));
                        wy += 1;
                    }
                    wy += 1;
                }
                if (runner.warnings.items.len > 0) {
                    _ = ui.screen.text(r.x, wy, "Warnings (the system is installed and should boot):", warn, @intCast(r.w));
                    wy += 1;
                    for (runner.warnings.items) |w| {
                        if (wy >= r.y + r.h - 1) break;
                        _ = ui.screen.text(r.x, wy, ui.fmt("- {s}: {s}", .{ w.desc, w.reason }), warn, @intCast(r.w));
                        wy += 1;
                        if (w.tail.len > 0 and wy < r.y + r.h - 1) {
                            _ = ui.screen.text(r.x + 2, wy, w.tail[w.tail.len - 1], dim, @intCast(r.w - 2));
                            wy += 1;
                        }
                    }
                }
                switch (try ui.key()) {
                    .char => |c| switch (c) {
                        'r', 'R' => return .reboot,
                        'l', 'L' => return .live,
                        's', 'S' => inTarget(ui, stack, &.{ "/bin/bash", "-l" }, true, plan),
                        else => {},
                    },
                    else => {},
                }
            }
        },
        .failed => |f| {
            while (true) {
                const r = ui.frame("The installation stopped", "S: open a shell   Q: quit (unmounts the target)");
                var y = r.y;
                _ = ui.screen.text(r.x, y, ui.fmt("Step {d}: {s}", .{ f.index + 1, f.desc }), danger, @intCast(r.w));
                y += 1;
                _ = ui.screen.text(r.x, y, ui.fmt("$ {s}", .{f.text}), dim, @intCast(r.w));
                y += 1;
                _ = ui.screen.text(r.x, y, f.reason, danger, @intCast(r.w));
                y += 2;
                for (f.tail) |l| {
                    if (y >= r.y + r.h - 3) break;
                    _ = ui.screen.text(r.x, y, l, normal, @intCast(r.w));
                    y += 1;
                }
                y = r.y + r.h - 2;
                _ = ui.screen.text(r.x, y, ui.fmt("Log: {s}", .{execute.log_path}), normal, @intCast(r.w));
                _ = ui.screen.text(r.x, y + 1, ui.fmt("Target mounted at {s}. Quit keeps a log copy in its /var/log.", .{plan_mod.target}), normal, @intCast(r.w));
                switch (try ui.key()) {
                    .char => |c| switch (c) {
                        's', 'S' => {
                            t.pause();
                            std.debug.print("\nThe target is mounted at {s}. Type exit to return.\n", .{plan_mod.target});
                            if (std.process.spawn(io, .{ .argv = &.{"/bin/sh"} })) |child| {
                                var ch = child;
                                _ = ch.wait(io) catch {};
                            } else |_| {}
                            t.unpause();
                            ui.screen.invalidate();
                        },
                        'q', 'Q' => {
                            runner.cleanup();
                            return .quit;
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        },
    }
}

/// For `--answers` without `--yes-really-erase`: the plan, then the typed
/// confirmation (SPEC.md 7). Returns false if the user backed out.
pub fn confirmPlan(ui: *Ui, disk: Disk, plan: plan_mod.Plan) !bool {
    var lines: std.ArrayList(Line) = .empty;
    try lines.append(ui.arena, .{ .text = ui.fmt("Disk: /dev/{s}  {s}  {s}", .{ disk.name, fmtSize(ui.arena, disk.size), disk.model orelse "" }), .attr = bold });
    if (describeContents(ui.arena, disk)) |c| {
        try lines.append(ui.arena, .{ .text = ui.fmt("Found on it (will be lost): {s}", .{c}), .attr = danger });
    } else try lines.append(ui.arena, .{ .text = "(nothing found on it)", .attr = dim });
    try lines.append(ui.arena, .{ .text = "" });
    var w: Io.Writer.Allocating = .init(ui.arena);
    try plan.writeDryRun(&w.writer);
    var it = std.mem.splitScalar(u8, w.written(), '\n');
    while (it.next()) |l| try lines.append(ui.arena, .{ .text = l, .attr = if (std.mem.startsWith(u8, l, "# ")) bold else normal });
    if (!try viewer(ui, "Summary", lines.items, "Up/Down, PgUp/PgDn: scroll   Enter: continue   Esc: quit")) return false;
    const prompt = ui.fmt("This will erase data on /dev/{s}. To go on, type the disk's name ({s}) and press Enter.", .{ disk.name, disk.name });
    return (try input(ui, "Confirm", prompt, "", .{ .expect = disk.name, .mismatch = "That is not the disk's name." })) != null;
}

// ----------------------------------------------------------------- tests

fn testKeys(comptime s: []const u8) [s.len]Key {
    var out: [s.len]Key = undefined;
    for (s, 0..) |c, i| out[i] = .{ .char = c };
    return out;
}

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

fn testUi(gpa: Allocator, arena: Allocator, keys: []const Key) !Ui {
    return .{ .gpa = gpa, .arena = arena, .screen = try term.Screen.init(gpa, 80, 24, false), .script = keys };
}

test "full flow, automatic layout, ends at a typed confirmation" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");

    // checks Enter, disk (first = nvme0n1) Enter, auto Enter, hostname Enter, domain Enter,
    // root pw x2, user, user pw x2, timezone, keymap, summary Enter, confirm.
    // checks, disk, partitioning, boot loader (default dklilo), root filesystem (default ext4), hostname, domain
    const keys = [_]Key{ .enter, .enter, .enter, .enter, .enter, .enter, .enter } ++
        testKeys("rootpw") ++ [_]Key{.enter} ++ testKeys("rootpw") ++ [_]Key{.enter} ++
        testKeys("dakota") ++ [_]Key{.enter} ++
        testKeys("userpw") ++ [_]Key{.enter} ++ testKeys("userpw") ++ [_]Key{.enter} ++
        [_]Key{ .enter, .enter, .enter } ++
        testKeys("nvme0n1") ++ [_]Key{.enter};
    var ui = try testUi(gpa, arena, &keys);
    defer ui.screen.deinit(gpa);
    const done = (try run(&ui, p, .{ .is_root = true, .dry_run = true, .ids = test_ids })).?;
    try std.testing.expectEqualStrings("nvme0n1", done.answers.disk);
    try std.testing.expectEqualStrings("dakota", done.answers.user);
    try std.testing.expectEqualStrings("rootpw", done.answers.root_pw.plain);
    try std.testing.expect(done.plan.steps.len > 20);
}

test "Esc goes back one screen at a time" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    // checks, disk, partitioning, boot loader, root filesystem, hostname; Esc back through each of them to the checks;
    // Esc to checks; Esc quits.
    const keys = [_]Key{ .enter, .enter, .enter, .enter, .enter, .esc, .esc, .esc, .esc, .esc, .esc };
    var ui = try testUi(gpa, arena, &keys);
    defer ui.screen.deinit(gpa);
    const done = try run(&ui, p, .{ .is_root = true, .dry_run = true, .ids = test_ids });
    try std.testing.expect(done == null);
    try std.testing.expectEqual(keys.len, ui.script_i);
}

test "wrong confirmation is not accepted; ineligible disks are shown with a reason" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    var ui = try testUi(gpa, arena, &[_]Key{.enter});
    defer ui.screen.deinit(gpa);
    _ = run(&ui, p, .{ .is_root = true, .dry_run = true, .ids = test_ids }) catch |e| {
        try std.testing.expectEqual(error.ScriptEnded, e);
    };
    const t = try ui.screen.toText(gpa);
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "holds the live medium") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "has a mounted partition") != null);
}

test "not root is fatal on the checks screen" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-nvme-blank.json");
    var ui = try testUi(gpa, arena, &[_]Key{.enter});
    defer ui.screen.deinit(gpa);
    const done = try run(&ui, p, .{ .is_root = false, .dry_run = false, .ids = test_ids });
    try std.testing.expect(done == null);
    const t = try ui.screen.toText(gpa);
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "can't continue") != null);
}

fn downs(comptime n: usize) [n]Key {
    return @splat(.down);
}

test "the screen after the services: SSH only when sshd is ticked, then only SELinux" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    var p = try loadFixture(arena, "uefi-services.json");
    var ui = try testUi(gpa, arena, &[_]Key{});
    defer ui.screen.deinit(gpa);
    var d: Draft = .{ .ssh = .{} };
    // The fixture has sshd off: no SSH screen, and earlier SSH answers are dropped.
    try std.testing.expectEqual(Scr.other, next(&ui, p, &d, .services));
    try std.testing.expect(d.ssh == null);
    d.svc_on = try arena.alloc(bool, p.services.len);
    for (p.services, 0..) |sv, i| d.svc_on[i] = sv.enabled or std.mem.eql(u8, sv.name, "sshd");
    try std.testing.expectEqual(Scr.ssh, next(&ui, p, &d, .services));
    // Without SELinux there is nothing left to ask, firewalld or not.
    p.selinux = false;
    try std.testing.expect(next(&ui, p, &d, .ssh) != .other);
}

test "full flow with services, ssh and network screens: manual network, key paste, confirm" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    const arena = st.allocator();
    const p = try loadFixture(arena, "uefi-services.json");
    // checks, disk, auto, hostname, domain "lab.test", root pw x2, user, user pw x2, timezone, keymap,
    // network: Manual (nothing) = 3rd item (Guided, Copy, Manual), then the services list: the
    // cursor starts on sshd (the first that can be switched), Enter ticks it, Done is last;
    // ssh: Set up SSH, root no, password yes, no key; SELinux as the image has it; summary; confirm.
    const keys = [_]Key{ .enter, .enter, .enter, .enter, .enter, .enter } ++ testKeys("lab.test") ++ [_]Key{.enter} ++
        testKeys("rootpw") ++ [_]Key{.enter} ++ testKeys("rootpw") ++ [_]Key{.enter} ++
        testKeys("dakota") ++ [_]Key{.enter} ++
        testKeys("userpw") ++ [_]Key{.enter} ++ testKeys("userpw") ++ [_]Key{.enter} ++
        [_]Key{ .enter, .enter } ++
        downs(2) ++ [_]Key{.enter} ++
        [_]Key{.enter} ++ downs(11) ++ [_]Key{.enter} ++
        [_]Key{ .down, .enter, .enter, .enter, .enter } ++
        [_]Key{.enter} ++
        [_]Key{.enter} ++
        testKeys("nvme0n1") ++ [_]Key{.enter};
    var ui = try testUi(gpa, arena, &keys);
    defer ui.screen.deinit(gpa);
    const done = (try run(&ui, p, .{ .is_root = true, .dry_run = true, .ids = test_ids })).?;
    try std.testing.expectEqualStrings("lab.test", done.answers.domain.?);
    try std.testing.expectEqual(answers_mod.NetMode.manual, done.answers.network.?.mode);
    try std.testing.expect(done.answers.ssh != null);
    try std.testing.expectEqual(answers_mod.RootLogin.no, done.answers.ssh.?.root_login);
    try std.testing.expectEqual(@as(usize, 1), done.answers.services_enable.len);
    try std.testing.expectEqualStrings("sshd", done.answers.services_enable[0]);
    var w: Io.Writer.Allocating = .init(arena);
    try done.plan.writeDryRun(&w.writer);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "left unconfigured") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "PermitRootLogin no") != null);
}

fn repeated(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

test "long non-ASCII input scrolls by characters and keeps the cursor in place" {
    const gpa = std.testing.allocator;
    var st = std.heap.ArenaAllocator.init(gpa);
    defer st.deinit();
    var ui = try testUi(gpa, st.allocator(), &[_]Key{.enter});
    defer ui.screen.deinit(gpa);
    const long = comptime repeated("é€", 60);
    try std.testing.expectEqualStrings(long, (try input(&ui, "t", "word-without-spaces-" ++ comptime repeated("é", 100), long, .{})).?);
    try std.testing.expect(ui.screen.cursor.?.x < ui.screen.w);
}
