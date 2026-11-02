//! Terminal layer: raw mode, key decoding, a cell grid and ANSI output.
//! Our own small layer instead of libvaxis (SPEC.md 4.1). It works at 80x24
//! on the Linux console, xterm-compatible terminals and serial lines, uses
//! 16 colours only, and always has a non-colour cue (reverse video).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

// ------------------------------------------------------------------ keys

/// A decoded key press.
pub const Key = union(enum) {
    char: u21,
    enter,
    esc,
    tab,
    backtab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    ctrl_c,
    none,
};

/// Result of decoding the front of a byte buffer.
pub const Decoded = struct { key: Key, len: usize };

/// Decodes one key from the front of `bytes`. Returns null if `bytes` is an
/// incomplete sequence (the caller should read more). A lone ESC is `.esc`:
/// the caller decides, by waiting briefly, whether more bytes follow.
pub fn decode(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    const b = bytes[0];
    switch (b) {
        0x1b => {
            if (bytes.len == 1) return .{ .key = .esc, .len = 1 };
            if (bytes[1] == '[' or bytes[1] == 'O') {
                // CSI / SS3: parameters, then a final byte 0x40-0x7e.
                var i: usize = 2;
                // Linux console function keys: ESC [ [ A
                if (i < bytes.len and bytes[i] == '[') i += 1;
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x3f) i += 1;
                if (i >= bytes.len) return null;
                const final = bytes[i];
                const params = bytes[2..i];
                const key: Key = switch (final) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    'Z' => .backtab,
                    '~' => if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) .home else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) .end else if (std.mem.eql(u8, params, "3")) .delete else if (std.mem.eql(u8, params, "5")) .page_up else if (std.mem.eql(u8, params, "6")) .page_down else .none,
                    else => .none,
                };
                return .{ .key = key, .len = i + 1 };
            }
            // ESC followed by something else: Alt+key. Treat as Esc, keep the rest.
            return .{ .key = .esc, .len = 1 };
        },
        '\r', '\n' => return .{ .key = .enter, .len = 1 },
        '\t' => return .{ .key = .tab, .len = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .len = 1 },
        0x03 => return .{ .key = .ctrl_c, .len = 1 },
        0x00...0x02, 0x04...0x07, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f => return .{ .key = .none, .len = 1 },
        else => {},
    }
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .key = .none, .len = 1 };
    if (bytes.len < n) return null;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .key = .none, .len = n };
    return .{ .key = .{ .char = cp }, .len = n };
}

// ----------------------------------------------------------------- cells

/// The eight ANSI colours, or the terminal default.
pub const Color = enum(u8) { default = 9, black = 0, red, green, yellow, blue, magenta, cyan, white };

/// How a cell looks. Anything shown with colour also differs without it.
pub const Attr = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    reverse: bool = false,

    pub fn eql(a: Attr, b: Attr) bool {
        return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold and a.reverse == b.reverse;
    }
};

/// One character cell.
pub const Cell = struct {
    ch: u21 = ' ',
    attr: Attr = .{},
};

/// A grid of cells. Draw into it, then `render` it.
pub const Screen = struct {
    w: u16,
    h: u16,
    cells: []Cell,
    /// What the terminal currently shows, to send only changed rows.
    shown: []Cell,
    shown_valid: bool = false,
    /// `+-|` instead of Unicode line characters.
    ascii: bool = false,
    /// Where the cursor goes after rendering, or null to hide it.
    cursor: ?struct { x: u16, y: u16 } = null,

    /// Allocates a w x h screen.
    pub fn init(gpa: Allocator, w: u16, h: u16, ascii: bool) !Screen {
        const n = @as(usize, w) * h;
        const cells = try gpa.alloc(Cell, n);
        errdefer gpa.free(cells);
        const shown = try gpa.alloc(Cell, n);
        @memset(cells, .{});
        @memset(shown, .{});
        return .{ .w = w, .h = h, .cells = cells, .shown = shown, .ascii = ascii };
    }

    pub fn deinit(self: *Screen, gpa: Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.shown);
    }

    /// Blanks the grid.
    pub fn clear(self: *Screen) void {
        @memset(self.cells, .{});
        self.cursor = null;
    }

    /// Sets one cell; out-of-range positions are ignored.
    pub fn put(self: *Screen, x: i32, y: i32, ch: u21, attr: Attr) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        self.cells[@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))] = .{ .ch = ch, .attr = attr };
    }

    /// Writes UTF-8 text from (x, y), clipped to `max` columns. Returns the
    /// number of columns written.
    pub fn text(self: *Screen, x: i32, y: i32, s: []const u8, attr: Attr, max: usize) usize {
        var n: usize = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (n >= max) break;
            self.put(x + @as(i32, @intCast(n)), y, cp, attr);
            n += 1;
        }
        return n;
    }

    /// Fills a rectangle.
    pub fn fill(self: *Screen, x: i32, y: i32, w: i32, h: i32, attr: Attr) void {
        var j: i32 = 0;
        while (j < h) : (j += 1) {
            var i: i32 = 0;
            while (i < w) : (i += 1) self.put(x + i, y + j, ' ', attr);
        }
    }

    /// Draws a titled box and clears its inside.
    pub fn box(self: *Screen, x: i32, y: i32, w: i32, h: i32, title: []const u8, attr: Attr) void {
        const tl: u21 = if (self.ascii) '+' else 0x250c;
        const tr: u21 = if (self.ascii) '+' else 0x2510;
        const bl: u21 = if (self.ascii) '+' else 0x2514;
        const br: u21 = if (self.ascii) '+' else 0x2518;
        const hz: u21 = if (self.ascii) '-' else 0x2500;
        const vt: u21 = if (self.ascii) '|' else 0x2502;
        self.fill(x, y, w, h, attr);
        self.put(x, y, tl, attr);
        self.put(x + w - 1, y, tr, attr);
        self.put(x, y + h - 1, bl, attr);
        self.put(x + w - 1, y + h - 1, br, attr);
        var i: i32 = 1;
        while (i < w - 1) : (i += 1) {
            self.put(x + i, y, hz, attr);
            self.put(x + i, y + h - 1, hz, attr);
        }
        i = 1;
        while (i < h - 1) : (i += 1) {
            self.put(x, y + i, vt, attr);
            self.put(x + w - 1, y + i, vt, attr);
        }
        if (title.len > 0 and w > 6) {
            var a = attr;
            a.bold = true;
            _ = self.text(x + 2, y, " ", a, 1);
            const n = self.text(x + 3, y, title, a, @intCast(w - 8));
            _ = self.text(x + 3 + @as(i32, @intCast(n)), y, " ", a, 1);
        }
    }

    /// The grid as plain text, one line per row, trailing blanks trimmed.
    /// For tests.
    pub fn toText(self: *const Screen, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [4]u8 = undefined;
        for (0..self.h) |y| {
            const row = self.cells[y * self.w ..][0..self.w];
            var last: usize = 0;
            for (row, 0..) |c, i| if (c.ch != ' ') {
                last = i + 1;
            };
            for (row[0..last]) |c| {
                const n = std.unicode.utf8Encode(c.ch, &buf) catch 1;
                try out.appendSlice(gpa, buf[0..n]);
            }
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// Writes the escape sequences that bring the terminal in line with the
    /// grid. Rows that haven't changed are skipped.
    pub fn render(self: *Screen, w: *Io.Writer) Io.Writer.Error!void {
        var cur: ?Attr = null;
        var buf: [4]u8 = undefined;
        try w.writeAll("\x1b[?25l");
        for (0..self.h) |y| {
            const row = self.cells[y * self.w ..][0..self.w];
            const old = self.shown[y * self.w ..][0..self.w];
            if (self.shown_valid and cellsEql(row, old)) continue;
            try w.print("\x1b[{d};1H", .{y + 1});
            var last: usize = row.len;
            // Trailing default blanks are cleared with EL instead.
            while (last > 0 and row[last - 1].ch == ' ' and row[last - 1].attr.eql(.{})) last -= 1;
            for (row[0..last]) |c| {
                if (cur == null or !cur.?.eql(c.attr)) {
                    try writeSgr(w, c.attr);
                    cur = c.attr;
                }
                const n = std.unicode.utf8Encode(c.ch, &buf) catch {
                    try w.writeByte('?');
                    continue;
                };
                try w.writeAll(buf[0..n]);
            }
            try w.writeAll("\x1b[0m\x1b[K");
            cur = null;
        }
        @memcpy(self.shown, self.cells);
        self.shown_valid = true;
        if (self.cursor) |c| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ c.y + 1, c.x + 1 });
        try w.flush();
    }

    /// Forgets what the terminal shows, so the next render repaints it all.
    pub fn invalidate(self: *Screen) void {
        self.shown_valid = false;
    }
};

fn cellsEql(a: []const Cell, b: []const Cell) bool {
    for (a, b) |x, y| if (x.ch != y.ch or !x.attr.eql(y.attr)) return false;
    return true;
}

fn writeSgr(w: *Io.Writer, a: Attr) !void {
    try w.writeAll("\x1b[0");
    if (a.bold) try w.writeAll(";1");
    if (a.reverse) try w.writeAll(";7");
    if (a.fg != .default) try w.print(";{d}", .{30 + @backingInt(a.fg)});
    if (a.bg != .default) try w.print(";{d}", .{40 + @backingInt(a.bg)});
    try w.writeByte('m');
}

// -------------------------------------------------------------- terminal

/// The controlling terminal in raw mode. `deinit` restores it.
pub const Terminal = struct {
    io: Io,
    saved: ?posix.termios = null,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,
    out_buf: [8192]u8 = undefined,
    out: Io.File.Writer = undefined,

    /// Enters raw mode and the alternate screen.
    pub fn init(self: *Terminal, io: Io) !void {
        self.* = .{ .io = io };
        self.out = .init(.stdout(), io, &self.out_buf);
        const orig = try posix.tcgetattr(posix.STDIN_FILENO);
        self.saved = orig;
        var raw = orig;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.INLCR = false;
        raw.iflag.BRKINT = false;
        raw.iflag.ISTRIP = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(linux.V.MIN)] = 1;
        raw.cc[@backingInt(linux.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        try self.out.interface.writeAll("\x1b[?1049h\x1b[2J");
        try self.out.interface.flush();
    }

    /// Leaves the alternate screen and restores the terminal.
    pub fn deinit(self: *Terminal) void {
        self.out.interface.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        self.out.interface.flush() catch {};
        if (self.saved) |s| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, s) catch {};
    }

    /// Hands the terminal back (normal mode, main screen), for a shell or a
    /// program that draws itself. `unpause` takes it again.
    pub fn pause(self: *Terminal) void {
        self.out.interface.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        self.out.interface.flush() catch {};
        if (self.saved) |s| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, s) catch {};
    }

    /// Back to raw mode and the alternate screen after `pause`.
    pub fn unpause(self: *Terminal) void {
        var raw = self.saved orelse return;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.INLCR = false;
        raw.iflag.BRKINT = false;
        raw.iflag.ISTRIP = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(linux.V.MIN)] = 1;
        raw.cc[@backingInt(linux.V.TIME)] = 0;
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
        self.pending_len = 0;
        self.out.interface.writeAll("\x1b[?1049h\x1b[2J") catch {};
        self.out.interface.flush() catch {};
    }

    /// The writer to render into.
    pub fn writer(self: *Terminal) *Io.Writer {
        return &self.out.interface;
    }

    /// Terminal size; 80x24 if it can't be asked (serial lines).
    pub fn size(self: *Terminal) struct { w: u16, h: u16 } {
        _ = self;
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .w = 80, .h = 24 };
        return .{ .w = ws.col, .h = ws.row };
    }

    fn fill(self: *Terminal, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        if (timeout_ms >= 0) {
            const n = try posix.poll(&fds, timeout_ms);
            if (n == 0) return false;
        }
        const room = self.pending[self.pending_len..];
        if (room.len == 0) return true;
        const n = try posix.read(posix.STDIN_FILENO, room);
        if (n == 0) return error.EndOfStream;
        self.pending_len += n;
        return true;
    }

    /// Blocks for the next key. A lone ESC is told apart from the start of
    /// an escape sequence by waiting 50 ms for more bytes.
    pub fn readKey(self: *Terminal) !Key {
        while (true) {
            if (self.pending_len == 0) _ = try self.fill(-1);
            if (self.pending[0] == 0x1b and self.pending_len == 1) {
                _ = try self.fill(50);
            }
            if (decode(self.pending[0..self.pending_len])) |d| {
                std.mem.copyForwards(u8, self.pending[0..], self.pending[d.len..self.pending_len]);
                self.pending_len -= d.len;
                if (d.key == .none) continue;
                return d.key;
            }
            // Incomplete sequence: read more.
            if (!try self.fill(200)) {
                self.pending_len = 0; // give up on a broken sequence
            }
        }
    }
};

// ----------------------------------------------------------------- tests

test "decode keys" {
    try std.testing.expectEqual(Key.up, decode("\x1b[A").?.key);
    try std.testing.expectEqual(Key.down, decode("\x1bOB").?.key);
    try std.testing.expectEqual(Key.page_down, decode("\x1b[6~").?.key);
    try std.testing.expectEqual(Key.backtab, decode("\x1b[Z").?.key);
    try std.testing.expectEqual(Key.up, decode("\x1b[[A").?.key);
    try std.testing.expectEqual(Key.esc, decode("\x1b").?.key);
    try std.testing.expectEqual(Key.enter, decode("\r").?.key);
    try std.testing.expectEqual(Key.backspace, decode("\x7f").?.key);
    try std.testing.expect(decode("\x1b[") == null);
    const d = decode("\xc3\xa9x").?;
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqual(@as(u21, 0xe9), d.key.char);
    // An unknown CSI is consumed whole and ignored.
    const u = decode("\x1b[15;5~").?;
    try std.testing.expectEqual(Key.none, u.key);
    try std.testing.expectEqual(@as(usize, 7), u.len);
}

test "screen box and text in unicode and ascii" {
    const gpa = std.testing.allocator;
    var s = try Screen.init(gpa, 10, 3, false);
    defer s.deinit(gpa);
    s.box(0, 0, 10, 3, "", .{});
    _ = s.text(1, 1, "hi", .{}, 8);
    const t = try s.toText(gpa);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("┌────────┐\n│hi      │\n└────────┘\n", t);
    s.ascii = true;
    s.clear();
    s.box(0, 0, 10, 3, "", .{});
    const t2 = try s.toText(gpa);
    defer gpa.free(t2);
    try std.testing.expectEqualStrings("+--------+\n|        |\n+--------+\n", t2);
}

test "render skips unchanged rows" {
    const gpa = std.testing.allocator;
    var s = try Screen.init(gpa, 5, 2, true);
    defer s.deinit(gpa);
    _ = s.text(0, 0, "abc", .{}, 5);
    var a: Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    try s.render(&a.writer);
    try std.testing.expect(std.mem.indexOf(u8, a.written(), "abc") != null);
    a.clearRetainingCapacity();
    _ = s.text(0, 1, "x", .{}, 5);
    try s.render(&a.writer);
    try std.testing.expect(std.mem.indexOf(u8, a.written(), "abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, a.written(), "x") != null);
}
