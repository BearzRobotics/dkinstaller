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
            if (cut == start) cut = start + width;
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
        const off = if (pos >= view_w) pos - view_w + 1 else 0;
        _ = ui.screen.text(r.x + 1, y, if (off < shown.len) shown[off..] else "", selected, view_w);
        ui.screen.cursor = .{ .x = @intCast(r.x + 1 + @as(i32, @intCast(pos - off))), .y = @intCast(y) };
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
    summary,
};

const Draft = struct {
    disk: ?Disk = null,
    partitioning: answers_mod.Partitioning = .auto,
    /// Partition by hand with cfdisk first, then continue as with existing partitions.
    manual: bool = false,
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
                if (try screenPartitioning(ui, p, env, &d)) go = if (d.manual) .cfdisk else if (d.partitioning == .auto) .hostname else .root;
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
                    go = .root_pw;
                }
            },
            .root_pw => {
                if (try screenPassword(ui, "Root password", &d.root_pw)) go = .user;
            },
            .user => {
                if (try input(ui, "User", "Name of the user to create. The user is put in the wheel, video and render groups and can use sudo.", d.user, .{ .validate = userError })) |v| {
                    d.user = v;
                    go = .user_pw;
                }
            },
            .user_pw => {
                const t = ui.fmt("Password for {s}", .{d.user});
                if (try screenPassword(ui, t, &d.user_pw)) go = .timezone;
            },
            .timezone => {
                if (try input(ui, "Timezone", "A zone name from /usr/share/zoneinfo, for example UTC or Europe/Berlin.", d.timezone, .{ .validate = timezoneError })) |v| {
                    d.timezone = v;
                    go = .keymap;
                }
            },
            .keymap => {
                if (try input(ui, "Console keymap", "Keymap for the text console, for example us or de.", d.keymap, .{ .validate = keymapError })) |v| {
                    d.keymap = v;
                    go = .summary;
                }
            },
            .summary => {
                if (try screenSummary(ui, p, env, &d)) |done| return done;
            },
        }
        if (go) |g| try stack.append(ui.arena, g) else _ = stack.pop();
    }
    return null;
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
        .{ .label = "Erase the disk and partition it automatically", .sub = "GPT: BIOS boot 1 MiB, ESP 512 MiB, root ext4 (the rest). Everything on the disk is lost." },
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

fn screenRoot(ui: *Ui, d: *Draft) !bool {
    const disk = d.disk.?;
    const list = try partitionItems(ui, disk.partitions, null);
    if (list.items.len == 0) {
        _ = try message(ui, "Root partition", &.{"The disk has no partitions."}, danger, "Esc: back");
        return false;
    }
    const pick = try menu(ui, "Root partition", "Which partition becomes /? It is always formatted as ext4 and everything on it is lost.", list.items, 0) orelse return false;
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
        if (q.size < 1024 * 1024) continue;
        if (std.mem.eql(u8, q.path, d.root.?.path)) continue;
        if (d.esp) |e| if (std.mem.eql(u8, q.path, e.path)) continue;
        try items.append(ui.arena, .{
            .label = ui.fmt("{s}  {s}", .{ q.path, fmtSize(ui.arena, q.size) }),
            .detail = q.fstype orelse "no filesystem",
            .sub = "Its type will be set to BIOS boot. It must not hold data you need.",
            .sub_attr = warn,
        });
        try idx.append(ui.arena, i);
    }
    if (items.items.len == 0) {
        _ = try message(ui, "BIOS boot partition", &.{"Booting a GPT disk on a BIOS machine needs a BIOS boot partition of at least 1 MiB, and there is none to use. Make one with fdisk or gdisk, then run the installer again."}, danger, "Esc: back");
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

fn buildAnswers(d: *const Draft) answers_mod.Answers {
    return .{
        .disk = d.disk.?.name,
        .partitioning = d.partitioning,
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
    };
}

/// Builds the summary, asks for the typed confirmation. Null means back.
fn screenSummary(ui: *Ui, p: Probe, env: Env, d: *const Draft) !?Done {
    const a = buildAnswers(d);
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
        try lines.append(ui.arena, .{ .text = "Layout: 1 MiB BIOS boot, 512 MiB ESP (FAT32), rest root (ext4)" });
    } else {
        try lines.append(ui.arena, .{ .text = ui.fmt("Root {s} will be FORMATTED (ext4); everything on it is lost.", .{d.root.?.path}), .attr = danger });
        if (d.esp) |e| {
            try lines.append(ui.arena, if (d.format_esp)
                .{ .text = ui.fmt("ESP {s} will be FORMATTED (FAT32).", .{e.path}), .attr = danger }
            else
                .{ .text = ui.fmt("ESP {s} is kept as it is.", .{e.path}) });
        }
        if (d.set_esp_type) try lines.append(ui.arena, .{ .text = "The ESP's partition type will be changed.", .attr = warn });
        if (d.set_bios_boot_type) try lines.append(ui.arena, .{ .text = ui.fmt("{s} will become the BIOS boot partition.", .{d.bios_boot.?.path}), .attr = warn });
    }
    try lines.append(ui.arena, .{ .text = ui.fmt("Hostname: {s}   User: {s}   Timezone: {s}   Keymap: {s}", .{ d.hostname, d.user, d.timezone, d.keymap }) });
    try lines.append(ui.arena, .{ .text = "Passwords: root set, user set" });
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

/// Runs `plan` with the progress screen, then the failure (SPEC.md 5.7) or
/// completion screen. Needs the real terminal.
pub fn install(ui: *Ui, io: Io, plan: plan_mod.Plan, info: []const u8) !InstallEnd {
    const t = ui.terminal.?;
    const progress = try ui.gpa.create(Progress);
    defer ui.gpa.destroy(progress);
    progress.* = .{ .ui = ui, .steps = plan.steps };
    var runner = try execute.Runner.init(ui.gpa, io, execute.log_path, .{
        .ctx = progress,
        .on_start = Progress.onStart,
        .on_line = Progress.onLine,
    });
    defer runner.deinit();
    runner.header(info);

    const outcome = try runner.run(plan.steps);
    switch (outcome) {
        .ok => {
            while (true) {
                const r = ui.frame("Installation complete", "R: reboot   L: return to the live system");
                _ = ui.screen.text(r.x, r.y, "DKRescue is installed.", good, @intCast(r.w));
                _ = ui.screen.text(r.x, r.y + 2, ui.fmt("The log is at {s} on the new system.", .{plan_mod.target_log["/run/dkrescue-install/target".len..]}), normal, @intCast(r.w));
                _ = ui.screen.text(r.x, r.y + 3, "Remove the installation medium before the computer restarts.", normal, @intCast(r.w));
                switch (try ui.key()) {
                    .char => |c| switch (c) {
                        'r', 'R' => return .reboot,
                        'l', 'L' => return .live,
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

    // checks Enter, disk (first = nvme0n1) Enter, auto Enter, hostname Enter,
    // root pw x2, user, user pw x2, timezone, keymap, summary Enter, confirm.
    const keys = [_]Key{ .enter, .enter, .enter, .enter } ++
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
    // checks, disk, partitioning, hostname; Esc to partitioning; Esc to disk;
    // Esc to checks; Esc quits.
    const keys = [_]Key{ .enter, .enter, .enter, .esc, .esc, .esc, .esc };
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
