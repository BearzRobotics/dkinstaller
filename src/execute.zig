//! Runs a plan's steps one by one, streams their output, writes the log and
//! stops at the first failure. Implements SPEC.md 5.6, 5.7 and 6.4.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const plan_mod = @import("plan.zig");
const probe_mod = @import("probe.zig");
const answers_mod = @import("answers.zig");

const Step = plan_mod.Step;

/// Where the log is kept while installing (SPEC.md 6.4).
pub const log_path = plan_mod.log_path;

/// How many output lines a failure keeps for display.
const tail_len = 12;

/// Receives progress while steps run. All callbacks are optional.
pub const Observer = struct {
    ctx: ?*anyopaque = null,
    /// A step is about to run; `text` is its command line or file path.
    on_start: ?*const fn (ctx: ?*anyopaque, index: usize, step: Step, text: []const u8) void = null,
    /// One line (or one `\r`-terminated progress update) of output.
    on_line: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
    /// A step finished successfully.
    on_done: ?*const fn (ctx: ?*anyopaque, index: usize) void = null,
    /// A soft step (`Step.soft`) failed. Return true to go on, false to stop
    /// the install as for any failure. Without it the install goes on.
    on_soft_fail: ?*const fn (ctx: ?*anyopaque, failure: Failure) bool = null,
    /// A `shell` step: let the user configure the target by hand. Without it
    /// (unattended) the step is skipped and the log says so.
    on_shell: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// A soft step that failed; kept for the final screen and the log.
pub const Warning = struct {
    desc: []const u8,
    reason: []const u8,
    /// The last lines of output (may be empty).
    tail: []const []const u8,
};

/// Why the install stopped (SPEC.md 5.7).
pub const Failure = struct {
    index: usize,
    desc: []const u8,
    /// Command line, or the file that couldn't be written.
    text: []const u8,
    /// "exited with code 1", "terminated with signal KILL", or an error name.
    reason: []const u8,
    /// The last lines of output.
    tail: []const []const u8,
};

/// How a run ended.
pub const Outcome = union(enum) {
    ok,
    failed: Failure,
};

/// One run of a plan. Owns the log and remembers what it mounted, so the
/// user can be handed a shell with the target in place, or quit cleanly.
pub const Runner = struct {
    gpa: Allocator,
    io: Io,
    /// Holds everything allocated for results (failure text, tails).
    arena: std.heap.ArenaAllocator,
    log: ?Io.File = null,
    observer: Observer = .{},
    /// Mount points made by this run, newest last.
    mounted: std.ArrayList([]const u8) = .empty,
    tail: std.ArrayList([]const u8) = .empty,
    /// Soft failures so far (owned by `gpa`, freed by `deinit`).
    warnings: std.ArrayList(Warning) = .empty,
    /// Output lines worth showing at the end: key fingerprints (`SHA256:`).
    notes: std.ArrayList([]const u8) = .empty,

    /// Opens (truncating) the log at `path`; its directory is created.
    pub fn init(gpa: Allocator, io: Io, path: []const u8, observer: Observer) !Runner {
        var r: Runner = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .observer = observer };
        errdefer r.arena.deinit();
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        r.log = try Io.Dir.cwd().createFile(io, path, .{});
        return r;
    }

    /// Closes the log. Does not unmount: call `cleanup` first.
    pub fn deinit(self: *Runner) void {
        if (self.log) |f| f.close(self.io);
        for (self.mounted.items) |m| self.gpa.free(m);
        self.mounted.deinit(self.gpa);
        for (self.warnings.items) |w| {
            self.gpa.free(w.desc);
            self.gpa.free(w.reason);
            for (w.tail) |l| self.gpa.free(l);
            self.gpa.free(w.tail);
        }
        self.warnings.deinit(self.gpa);
        for (self.notes.items) |n| self.gpa.free(n);
        self.notes.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Runs `steps` in order and stops at the first that fails.
    pub fn run(self: *Runner, steps: []const Step) !Outcome {
        for (steps, 0..) |step, i| {
            _ = self.arena.reset(.retain_capacity);
            self.tail = .empty;
            const text = try self.stepText(step);
            var sb: [32]u8 = undefined;
            self.logPrint("\n== {d}/{d} {s}   [{s}]\n", .{ i + 1, steps.len, step.desc, self.stamp(&sb) });
            self.logPrint("$ {s}\n", .{text});
            switch (step.action) {
                .write_file => |w| if (w.secret) self.logPrint("    | (contents hidden)\n", .{}) else self.logBlock(w.contents),
                .command => |c| if (c.stdin) |in| if (!c.secret_stdin) self.logBlock(in),
                .shell, .note => {},
            }
            if (!conditionHolds(self.io, step.when)) {
                self.logPrint("-- skipped: its condition does not hold (not needed on this system)\n", .{});
                self.sync();
                if (self.observer.on_done) |f| f(self.observer.ctx, i);
                continue;
            }
            self.sync();
            if (self.observer.on_start) |f| f(self.observer.ctx, i, step, text);

            const reason: ?[]const u8 = switch (step.action) {
                .command => |c| try self.runCommand(c),
                .write_file => |w| self.writeFile(w),
                .note => null,
                .shell => blk: {
                    if (self.observer.on_shell) |f| {
                        f(self.observer.ctx);
                        self.logPrint("-- the user's shell session ended\n", .{});
                    } else self.logPrint("-- skipped: unattended, no shell is opened (network configuration is left to the user)\n", .{});
                    break :blk null;
                },
            };
            if (reason) |why| {
                if (step.soft) {
                    self.logPrint("-- warning: {s} (the install goes on)\n", .{why});
                    const failure: Failure = .{
                        .index = i,
                        .desc = step.desc,
                        .text = text,
                        .reason = why,
                        .tail = self.tail.items,
                    };
                    self.addWarning(failure);
                    const go_on = if (self.observer.on_soft_fail) |f| f(self.observer.ctx, failure) else true;
                    if (go_on) {
                        self.sync();
                        if (self.observer.on_done) |f| f(self.observer.ctx, i);
                        continue;
                    }
                    self.logPrint("-- stopped at the user's request\n", .{});
                }
                self.logPrint("-- failed: {s}\n", .{why});
                self.logRemaining(steps[i + 1 ..]);
                self.sync();
                return .{ .failed = .{
                    .index = i,
                    .desc = step.desc,
                    .text = text,
                    .reason = why,
                    .tail = try self.arena.allocator().dupe([]const u8, self.tail.items),
                } };
            }
            self.logPrint("-- ok\n", .{});
            self.sync();
            self.trackMounts(step);
            if (self.observer.on_done) |f| f(self.observer.ctx, i);
        }
        return .ok;
    }

    fn addWarning(self: *Runner, f: Failure) void {
        const desc = self.gpa.dupe(u8, f.desc) catch return;
        const reason = self.gpa.dupe(u8, f.reason) catch return;
        const tail = self.gpa.alloc([]const u8, f.tail.len) catch return;
        var n: usize = 0;
        for (f.tail) |l| {
            tail[n] = self.gpa.dupe(u8, l) catch break;
            n += 1;
        }
        self.warnings.append(self.gpa, .{ .desc = desc, .reason = reason, .tail = tail[0..n] }) catch {};
    }

    /// The steps that did not run, as the commands to finish by hand.
    fn logRemaining(self: *Runner, rest: []const Step) void {
        if (rest.len == 0) return;
        self.logPrint("\n== not run (the rest of the plan, to finish by hand):\n\n", .{});
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const p: plan_mod.Plan = .{ .steps = rest, .programs = &.{} };
        p.writeDryRun(&aw.writer) catch return;
        self.logPrint("{s}", .{aw.written()});
    }

    /// Best effort: if the new root is still mounted, keeps a copy of the log
    /// on it, since `/run` does not survive a reboot.
    pub fn saveLogToTarget(self: *Runner) void {
        var root_mounted = false;
        for (self.mounted.items) |m| {
            if (std.mem.eql(u8, m, plan_mod.target)) root_mounted = true;
        }
        if (!root_mounted) return;
        const text = Io.Dir.cwd().readFileAlloc(self.io, log_path, self.gpa, .limited(64 << 20)) catch return;
        defer self.gpa.free(text);
        const dest = plan_mod.target ++ "/var/log/dkrescue-install-failed.log";
        Io.Dir.cwd().createDirPath(self.io, plan_mod.target ++ "/var/log") catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = text }) catch return;
        self.logPrint("\n== log copy kept at {s}\n", .{dest});
    }

    /// Unmounts what this run mounted and has not unmounted, newest first.
    /// Errors are logged and otherwise ignored.
    pub fn cleanup(self: *Runner) void {
        self.saveLogToTarget();
        while (self.mounted.pop()) |mp| {
            defer self.gpa.free(mp);
            self.logPrint("\n== cleanup: umount {s}\n", .{mp});
            const res = std.process.run(self.gpa, self.io, .{ .argv = &.{ "umount", mp } }) catch |e| {
                self.logPrint("-- umount failed: {s}\n", .{@errorName(e)});
                continue;
            };
            defer self.gpa.free(res.stdout);
            defer self.gpa.free(res.stderr);
            if (!res.term.success()) self.logPrint("-- umount failed: {s}", .{res.stderr});
        }
    }

    fn stepText(self: *Runner, step: Step) ![]const u8 {
        const a = self.arena.allocator();
        switch (step.action) {
            .write_file => |w| return std.fmt.allocPrint(a, "write {s} (mode {o:0>4})", .{ w.path, w.mode }),
            .shell => return a.dupe(u8, "shell in the new system (chroot)"),
            .note => return a.dupe(u8, "(nothing to run)"),
            .command => |c| {
                var aw: Io.Writer.Allocating = .init(a);
                for (c.argv, 0..) |arg, i| {
                    if (i > 0) try aw.writer.writeByte(' ');
                    try plan_mod.writeQuoted(&aw.writer, arg);
                }
                if (c.secret_stdin) try aw.writer.writeAll("   # stdin: (hidden)");
                return aw.written();
            },
        }
    }

    fn trackMounts(self: *Runner, step: Step) void {
        const c = switch (step.action) {
            .command => |c| c,
            else => return,
        };
        const prog = std.fs.path.basename(c.argv[0]);
        if (std.mem.eql(u8, prog, "mount") and c.argv.len >= 3) {
            const mp = self.gpa.dupe(u8, c.argv[c.argv.len - 1]) catch return;
            self.mounted.append(self.gpa, mp) catch self.gpa.free(mp);
        } else if (std.mem.eql(u8, prog, "umount") and c.argv.len >= 2) {
            const mp = c.argv[c.argv.len - 1];
            var i = self.mounted.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.mounted.items[i], mp)) {
                    self.gpa.free(self.mounted.orderedRemove(i));
                    break;
                }
            }
        }
    }

    fn logPrint(self: *Runner, comptime f: []const u8, args: anytype) void {
        const file = self.log orelse return;
        const s = std.fmt.allocPrint(self.gpa, f, args) catch return;
        defer self.gpa.free(s);
        file.writeStreamingAll(self.io, s) catch {};
    }

    /// Writes `text` to the log, each line prefixed so it can't be mistaken
    /// for the runner's own markers.
    fn logBlock(self: *Runner, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (l.len == 0 and it.peek() == null) break;
            self.logPrint("    | {s}\n", .{l});
        }
    }

    /// Writes the start of the log: when, and what this run is about.
    /// `info` comes from `describeRun`.
    pub fn header(self: *Runner, info: []const u8) void {
        var buf: [32]u8 = undefined;
        self.logPrint("dkrescue-install log, {s}\n{s}\n", .{ self.stamp(&buf), info });
        self.sync();
    }

    fn sync(self: *Runner) void {
        if (self.log) |f| f.sync(self.io) catch {};
    }

    /// "2026-11-01 15:08:11Z".
    fn stamp(self: *Runner, buf: []u8) []const u8 {
        const secs: u64 = @intCast(@max(0, Io.Clock.real.now(self.io).toSeconds()));
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,              @backingInt(md.month),   md.day_index + 1,
            ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch "";
    }

    fn line(self: *Runner, text: []const u8) void {
        if (text.len == 0) return;
        if (isPercent(text)) {
            // Progress updates (unsquashfs) would flood the log: keep every
            // tenth and the last.
            const n = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t"), 10) catch 0;
            if (n % 10 == 0) self.logPrint("{s}\n", .{std.mem.trim(u8, text, " \t")});
            if (self.observer.on_line) |f| f(self.observer.ctx, text);
            return;
        }
        self.logPrint("{s}\n", .{text});
        if (std.mem.indexOf(u8, text, "SHA256:") != null) {
            if (self.gpa.dupe(u8, std.mem.trim(u8, text, " \t"))) |n| self.notes.append(self.gpa, n) catch self.gpa.free(n) else |_| {}
        }
        if (self.observer.on_line) |f| f(self.observer.ctx, text);
        const a = self.arena.allocator();
        const copy = a.dupe(u8, text) catch return;
        if (self.tail.items.len >= tail_len) _ = self.tail.orderedRemove(0);
        self.tail.append(a, copy) catch {};
    }

    /// Returns the failure reason, or null on success.
    fn writeFile(self: *Runner, w: plan_mod.FileWrite) ?[]const u8 {
        const a = self.arena.allocator();
        const fail = struct {
            fn f(al: Allocator, what: []const u8, e: anyerror) []const u8 {
                return std.fmt.allocPrint(al, "{s}: {s}", .{ what, @errorName(e) }) catch "write failed";
            }
        }.f;
        if (std.fs.path.dirname(w.path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch |e| return fail(a, "can't create the directory", e);
        var file = Io.Dir.cwd().createFile(self.io, w.path, .{ .permissions = .fromMode(@intCast(w.mode)) }) catch |e| return fail(a, "can't create the file", e);
        defer file.close(self.io);
        file.setPermissions(self.io, .fromMode(@intCast(w.mode))) catch |e| return fail(a, "can't set the mode", e);
        file.writeStreamingAll(self.io, w.contents) catch |e| return fail(a, "can't write the file", e);
        return null;
    }

    /// Returns the failure reason, or null on success.
    fn runCommand(self: *Runner, c: plan_mod.Command) !?[]const u8 {
        const a = self.arena.allocator();
        var child = std.process.spawn(self.io, .{
            .argv = c.argv,
            .stdin = if (c.stdin != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |e| return try std.fmt.allocPrint(a, "can't start {s}: {s}", .{ c.argv[0], @errorName(e) });
        defer child.kill(self.io);

        if (c.stdin) |input| {
            // Small inputs only (a partition script, a password line): they fit
            // the pipe, so writing before reading cannot deadlock.
            child.stdin.?.writeStreamingAll(self.io, input) catch {};
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
        var mr: Io.File.MultiReader = undefined;
        mr.init(self.gpa, self.io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();

        while (true) {
            mr.fill(64, .none) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return try std.fmt.allocPrint(a, "reading output failed: {s}", .{@errorName(e)}),
            };
            self.drain(&mr, false);
        }
        self.drain(&mr, true);

        const term = try child.wait(self.io);
        if (term.success()) return null;
        return try std.fmt.allocPrint(a, "{f}", .{term});
    }

    /// Hands complete lines from both streams on; at the end, the rest too.
    fn drain(self: *Runner, mr: *Io.File.MultiReader, final: bool) void {
        for (0..2) |n| {
            const r = mr.reader(n);
            while (true) {
                const buf = r.buffered();
                if (buf.len == 0) break;
                if (std.mem.indexOfAny(u8, buf, "\r\n")) |end| {
                    self.line(buf[0..end]);
                    r.toss(end + 1);
                } else {
                    if (final) {
                        self.line(buf);
                        r.toss(buf.len);
                    }
                    break;
                }
            }
        }
    }
};

/// Binds /proc /sys /dev /run into the target, runs `chroot target argv...`
/// with the terminal, and unbinds again, also when the command fails. Returns
/// an error text for the caller to show, or null.
pub fn chrootRun(gpa: Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    const binds = [_]struct { src: []const u8, opt: []const u8 }{
        .{ .src = "/proc", .opt = "--rbind" }, .{ .src = "/sys", .opt = "--rbind" },
        .{ .src = "/dev", .opt = "--rbind" },  .{ .src = "/run", .opt = "--bind" },
    };
    var done: usize = 0;
    var problem: ?[]const u8 = null;
    for (binds) |bd| {
        const dst = std.fmt.allocPrint(gpa, "{s}{s}", .{ plan_mod.target, bd.src }) catch return "out of memory";
        defer gpa.free(dst);
        Io.Dir.cwd().createDirPath(io, dst) catch {};
        var child = std.process.spawn(io, .{ .argv = &.{ "mount", bd.opt, bd.src, dst } }) catch {
            problem = "can't run mount";
            break;
        };
        const term = child.wait(io) catch {
            problem = "mount failed";
            break;
        };
        if (!term.success()) {
            problem = "can't bind-mount /proc /sys /dev /run into the target";
            break;
        }
        done += 1;
    }
    if (problem == null) {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(gpa);
        full.append(gpa, "chroot") catch return "out of memory";
        full.append(gpa, plan_mod.target) catch return "out of memory";
        full.appendSlice(gpa, argv) catch return "out of memory";
        if (std.process.spawn(io, .{ .argv = full.items })) |c| {
            var child = c;
            _ = child.wait(io) catch {};
        } else |_| problem = "can't run chroot";
    }
    // Unbind in reverse, whatever happened.
    while (done > 0) {
        done -= 1;
        const dst = std.fmt.allocPrint(gpa, "{s}{s}", .{ plan_mod.target, binds[done].src }) catch continue;
        defer gpa.free(dst);
        if (std.process.spawn(io, .{ .argv = &.{ "umount", "-R", dst } })) |c| {
            var child = c;
            _ = child.wait(io) catch {};
        } else |_| {}
    }
    return problem;
}

/// What the shell banner says: the config files of the network stack present,
/// and how to enable a dinit service the way the image does.
pub fn shellBanner(arena: Allocator, stack: probe_mod.NetStack) ![]const u8 {
    const stack_text: []const u8 = switch (stack) {
        .networkmanager =>
        \\  NetworkManager:  /etc/NetworkManager/NetworkManager.conf
        \\                   /etc/NetworkManager/system-connections/   (keyfiles, mode 0600)
        \\                   nmcli, nmtui          wpa_supplicant for WiFi
        \\
        ,
        .dhcpcd =>
        \\  dhcpcd:          /etc/dhcpcd.conf       (interface blocks, static lines)
        \\  wpa_supplicant:  /etc/wpa_supplicant/wpa_supplicant.conf
        \\
        ,
        .none => "  (no network stack found in the image)\n",
    };
    return std.fmt.allocPrint(arena,
        \\
        \\== Shell in the new system (chroot {s}) ==
        \\Useful here:
        \\{s}  ip addr, ip route          /etc/hosts  /etc/hostname  /etc/resolv.conf
        \\
        \\Enable a service at boot the way the image does:
        \\  ln -sfn ../NAME /etc/dinit.d/boot.d/NAME            (service in /etc/dinit.d)
        \\  ln -sfn /usr/lib/dinit.d/NAME /etc/dinit.d/boot.d/NAME
        \\Disable it:  rm /etc/dinit.d/boot.d/NAME
        \\Edit a file with ${{EDITOR:-vi}}. Type exit to return to the installer.
        \\
        \\
    , .{ plan_mod.target, stack_text });
}

/// Mounts the finished install again (root, and the ESP if there is one),
/// runs `chrootRun`, and unmounts. For the final screen's shell.
pub fn shellInInstalled(gpa: Allocator, io: Io, plan: plan_mod.Plan, argv: []const []const u8) ?[]const u8 {
    const t = plan_mod.target;
    Io.Dir.cwd().createDirPath(io, t) catch {};
    if (!runQuiet(io, &.{ "mount", plan.root_dev, t })) return "can't mount the new system";
    var esp_mounted = false;
    if (plan.esp_dev) |esp| esp_mounted = runQuiet(io, &.{ "mount", esp, t ++ "/boot/efi" });
    const r = chrootRun(gpa, io, argv);
    _ = runQuiet(io, &.{"sync"});
    if (esp_mounted) _ = runQuiet(io, &.{ "umount", t ++ "/boot/efi" });
    _ = runQuiet(io, &.{ "umount", t });
    return r;
}

fn runQuiet(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

/// Whether a step's condition holds now (an empty condition always does).
pub fn conditionHolds(io: Io, c: plan_mod.Condition) bool {
    for (c.exists) |p| if (!pathExists(io, p)) return false;
    if (c.any_of.len > 0) {
        var any = false;
        for (c.any_of) |p| if (pathExists(io, p)) {
            any = true;
        };
        if (!any) return false;
    }
    for (c.none_of) |p| if (pathExists(io, p)) return false;
    return true;
}

fn pathExists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// True for a line that is only a percentage, as `unsquashfs -percentage` prints.
pub fn isPercent(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len > 0 and t.len <= 3 and std.mem.indexOfNone(u8, t, "0123456789") == null;
}

/// What the log says about this run, from the probe and the answers (no
/// passwords). For `Runner.header`.
pub fn describeRun(arena: Allocator, p: probe_mod.Probe, a: answers_mod.Answers) Allocator.Error![]const u8 {
    const disk = p.findDisk(a.disk);
    return std.fmt.allocPrint(arena,
        \\firmware: {s}   efivars writable: {}
        \\disk: /dev/{s}  {d} bytes  {s}
        \\partitioning: {s}   root: {s}   esp: {s}   format esp: {}
        \\hostname: {s}   user: {s}   timezone: {s}   keymap: {s}
        \\passwords: not logged
        \\
    , .{
        if (p.firmware == .uefi) "UEFI" else "BIOS", p.efivars_rw,
        a.disk,                                      if (disk) |d| d.size else 0,
        if (disk) |d| d.model orelse "" else "",     @tagName(a.partitioning),
        a.root orelse "-",                           a.esp orelse "-",
        a.format_esp,                                a.hostname,
        a.user,                                      a.timezone,
        a.keymap orelse "-",
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const TestSink = struct {
    lines: std.ArrayList([]const u8) = .empty,
    started: usize = 0,
    done: usize = 0,

    fn onStart(ctx: ?*anyopaque, _: usize, _: Step, _: []const u8) void {
        const s: *TestSink = @ptrCast(@alignCast(ctx.?));
        s.started += 1;
    }
    fn onLine(ctx: ?*anyopaque, text: []const u8) void {
        const s: *TestSink = @ptrCast(@alignCast(ctx.?));
        s.lines.append(testing.allocator, testing.allocator.dupe(u8, text) catch return) catch {};
    }
    fn onDone(ctx: ?*anyopaque, _: usize) void {
        const s: *TestSink = @ptrCast(@alignCast(ctx.?));
        s.done += 1;
    }
    fn deinit(s: *TestSink) void {
        for (s.lines.items) |l| testing.allocator.free(l);
        s.lines.deinit(testing.allocator);
    }
};

fn cmdStep(desc: []const u8, argv: []const []const u8) Step {
    return .{ .desc = desc, .action = .{ .command = .{ .argv = argv } } };
}

test "steps run in order, output is streamed and logged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink: TestSink = .{};
    defer sink.deinit();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/logs/install.log", .{dir});
    defer testing.allocator.free(log);
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/etc/hostname", .{dir});
    defer testing.allocator.free(out);

    var r = try Runner.init(testing.allocator, testing.io, log, .{ .ctx = &sink, .on_start = TestSink.onStart, .on_line = TestSink.onLine, .on_done = TestSink.onDone });
    defer r.deinit();
    const steps = [_]Step{
        cmdStep("say hello", &.{ "echo", "hello" }),
        .{ .desc = "write", .action = .{ .write_file = .{ .path = out, .contents = "box\n", .mode = 0o600 } } },
        .{ .desc = "stdin", .action = .{ .command = .{ .argv = &.{"cat"}, .stdin = "from stdin\n" } } },
        cmdStep("progress", &.{ "sh", "-c", "printf ' 10\\r 100\\r\\n'; echo oops >&2" }),
    };
    const o = try r.run(&steps);
    try testing.expect(o == .ok);
    try testing.expectEqual(@as(usize, 4), sink.done);
    try testing.expectEqualStrings("hello", sink.lines.items[0]);
    try testing.expectEqualStrings("from stdin", sink.lines.items[1]);

    const written = try tmp.dir.readFileAlloc(testing.io, "etc/hostname", testing.allocator, .limited(100));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("box\n", written);

    const logged = try tmp.dir.readFileAlloc(testing.io, "logs/install.log", testing.allocator, .limited(10000));
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "== 1/4 say hello") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "$ echo hello") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "oops") != null);
}

test "the first failing step stops the run and keeps the tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
    defer testing.allocator.free(log);

    var r = try Runner.init(testing.allocator, testing.io, log, .{});
    defer r.deinit();
    const steps = [_]Step{
        cmdStep("fine", &.{"true"}),
        cmdStep("breaks", &.{ "sh", "-c", "echo one; echo two >&2; exit 3" }),
        cmdStep("never", &.{ "touch", "/nonexistent/never-runs" }),
    };
    const o = try r.run(&steps);
    try testing.expect(o == .failed);
    const f = o.failed;
    try testing.expectEqual(@as(usize, 1), f.index);
    try testing.expectEqualStrings("exited with code 3", f.reason);
    try testing.expectEqual(@as(usize, 2), f.tail.len);

    const logged = try tmp.dir.readFileAlloc(testing.io, "install.log", testing.allocator, .limited(10000));
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "-- failed: exited with code 3") != null);
    // It is listed as not run, and never started.
    const not_run = std.mem.indexOf(u8, logged, "== not run").?;
    try testing.expect(std.mem.indexOf(u8, logged, "never-runs").? > not_run);
    try testing.expect(std.mem.indexOf(u8, logged, "== 3/3") == null);
}

test "a missing program is a failure, not a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
    defer testing.allocator.free(log);
    var r = try Runner.init(testing.allocator, testing.io, log, .{});
    defer r.deinit();
    const o = try r.run(&.{cmdStep("nope", &.{"dk-no-such-program"})});
    try testing.expect(o == .failed);
}

test "secret stdin is never logged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
    defer testing.allocator.free(log);
    var r = try Runner.init(testing.allocator, testing.io, log, .{});
    defer r.deinit();
    const o = try r.run(&.{.{ .desc = "pw", .action = .{ .command = .{ .argv = &.{"true"}, .stdin = "root:hunter2\n", .secret_stdin = true } } }});
    try testing.expect(o == .ok);
    const logged = try tmp.dir.readFileAlloc(testing.io, "install.log", testing.allocator, .limited(10000));
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, logged, "(hidden)") != null);
}

test "a failure injected at each step stops there and leaves the log intact" {
    const n = 6;
    for (0..n) |k| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
        defer testing.allocator.free(log);
        var r = try Runner.init(testing.allocator, testing.io, log, .{});
        defer r.deinit();

        var steps: [n]Step = undefined;
        for (&steps, 0..) |*s, i| s.* = cmdStep("step", if (i == k) &.{"false"} else &.{ "echo", "ran" });
        const o = try r.run(&steps);
        try testing.expectEqual(k, o.failed.index);

        const logged = try tmp.dir.readFileAlloc(testing.io, "install.log", testing.allocator, .limited(10000));
        defer testing.allocator.free(logged);
        try testing.expectEqual(k, std.mem.count(u8, logged, "-- ok"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, logged, "-- failed"));
        // k+1 steps started, plus the "not run" list unless the last one failed.
        try testing.expectEqual(k + 1 + @intFromBool(k < n - 1), std.mem.count(u8, logged, "== "));
    }
}

test "the log holds file contents, the stdin script, and what was not run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
    defer testing.allocator.free(log);
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/fstab", .{dir});
    defer testing.allocator.free(out);
    var r = try Runner.init(testing.allocator, testing.io, log, .{});
    defer r.deinit();
    r.header("disk: /dev/test\n");
    const long: [3000]u8 = @splat('x');
    const steps = [_]Step{
        .{ .desc = "fstab", .action = .{ .write_file = .{ .path = out, .contents = "UUID=1 / ext4 defaults 1 1\n" } } },
        .{ .desc = "script", .action = .{ .command = .{ .argv = &.{"cat"}, .stdin = "label: gpt\n" } } },
        cmdStep("long line", &.{ "echo", &long }),
        cmdStep("breaks", &.{"false"}),
        cmdStep("later", &.{ "mkfs.ext4", "/dev/never" }),
    };
    const o = try r.run(&steps);
    try testing.expectEqual(@as(usize, 3), o.failed.index);
    const logged = try tmp.dir.readFileAlloc(testing.io, "install.log", testing.allocator, .limited(100000));
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.startsWith(u8, logged, "dkrescue-install log, 20"));
    try testing.expect(std.mem.indexOf(u8, logged, "disk: /dev/test") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "    | UUID=1 / ext4 defaults 1 1") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "    | label: gpt") != null);
    try testing.expect(std.mem.indexOf(u8, logged, &long) != null);
    try testing.expect(std.mem.indexOf(u8, logged, "== not run") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "mkfs.ext4 /dev/never") != null);
    try testing.expect(std.mem.indexOfScalar(u8, logged, 0) == null);
}

test "percentage lines are thinned in the log" {
    try testing.expect(isPercent(" 42"));
    try testing.expect(!isPercent("42 files"));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/install.log", .{dir});
    defer testing.allocator.free(log);
    var r = try Runner.init(testing.allocator, testing.io, log, .{});
    defer r.deinit();
    const o = try r.run(&.{cmdStep("pct", &.{ "sh", "-c", "for i in $(seq 1 100); do printf ' %d\\r' $i; done" })});
    try testing.expect(o == .ok);
    const logged = try tmp.dir.readFileAlloc(testing.io, "install.log", testing.allocator, .limited(100000));
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.count(u8, logged, "\n") < 30);
    try testing.expect(std.mem.indexOf(u8, logged, "\n100\n") != null);
}
