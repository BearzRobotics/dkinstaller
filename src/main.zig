//! Command line entry point (SPEC.md 7): the screens, `--dry-run`, and the
//! install itself (milestone I2).

const std = @import("std");
const Io = std.Io;
const dk = @import("dkinstall");

const usage =
    \\usage: dkrescue-install [--dry-run] [--answers FILE [--yes-really-erase DISK]]
    \\                        [--probe FILE] [--ascii]
    \\
    \\  (no options)       the interactive installer
    \\  --dry-run          print the plan instead of running it
    \\  --answers FILE     take every answer from FILE (INI) instead of the screens;
    \\                     the summary and its typed confirmation are still shown
    \\  --yes-really-erase DISK
    \\                     with --answers: no screens at all, for tests; DISK must
    \\                     be the disk named in FILE
    \\  --probe FILE       use a recorded probe fixture (only with --dry-run)
    \\  --ascii            ASCII box drawing
    \\
;

/// Prints the unattended install's progress to standard output.
const Plain = struct {
    out: *Io.Writer,
    total: usize,

    fn onStart(ctx: ?*anyopaque, index: usize, step: dk.plan.Step, text: []const u8) void {
        const self: *Plain = @ptrCast(@alignCast(ctx.?));
        self.out.print("[{d}/{d}] {s}\n$ {s}\n", .{ index + 1, self.total, step.desc, text }) catch {};
        self.out.flush() catch {};
    }

    fn onLine(ctx: ?*anyopaque, line: []const u8) void {
        const self: *Plain = @ptrCast(@alignCast(ctx.?));
        self.out.print("    {s}\n", .{line}) catch {};
        self.out.flush() catch {};
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var err_buf: [1024]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    var dry_run = false;
    var ascii = false;
    var answers_path: ?[]const u8 = null;
    var probe_path: ?[]const u8 = null;
    var erase_disk: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        } else if (std.mem.eql(u8, arg, "--answers") or std.mem.eql(u8, arg, "--probe") or std.mem.eql(u8, arg, "--yes-really-erase")) {
            i += 1;
            if (i >= args.len) {
                try err.print("{s} needs a value\n{s}", .{ arg, usage });
                return 2;
            }
            if (std.mem.eql(u8, arg, "--answers")) {
                answers_path = args[i];
            } else if (std.mem.eql(u8, arg, "--probe")) {
                probe_path = args[i];
            } else erase_disk = args[i];
        } else {
            try err.print("unknown argument: {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    const executing = !dry_run;
    if (executing and probe_path != null) {
        try err.print("--probe is for --dry-run only: a recorded probe is never combined with execution\n", .{});
        return 2;
    }
    if (erase_disk != null and answers_path == null) {
        try err.print("--yes-really-erase needs --answers\n", .{});
        return 2;
    }
    if (erase_disk != null and dry_run) {
        try err.print("--yes-really-erase is for a real install; with --dry-run nothing is erased\n", .{});
        return 2;
    }
    if (executing and std.os.linux.geteuid() != 0) {
        try err.print("dkrescue-install must run as root\n", .{});
        return 1;
    }

    // Answers (from a file; otherwise from the screens, below)
    var file_answers: ?dk.answers.Answers = null;
    if (answers_path) |ans_path| {
        const ans_text = Io.Dir.cwd().readFileAlloc(io, ans_path, arena, .limited(1 << 20)) catch |e| {
            try err.print("can't read {s}: {s}\n", .{ ans_path, @errorName(e) });
            return 1;
        };
        var diag: dk.answers.Diag = .{};
        file_answers = dk.answers.parse(arena, ans_text, &diag) catch {
            try err.print("{s}:{d}: {s}\n", .{ ans_path, diag.line, diag.message });
            return 1;
        };
        if (erase_disk) |d| if (!std.mem.eql(u8, d, file_answers.?.disk)) {
            try err.print("--yes-really-erase {s} does not match the disk in {s} ({s})\n", .{ d, ans_path, file_answers.?.disk });
            return 2;
        };
    }

    // Probe
    const probe: dk.probe.Probe = if (probe_path) |pp| blk: {
        const t = Io.Dir.cwd().readFileAlloc(io, pp, arena, .limited(8 << 20)) catch |e| {
            try err.print("can't read {s}: {s}\n", .{ pp, @errorName(e) });
            return 1;
        };
        break :blk dk.probe.fromFixture(arena, t) catch |e| {
            try err.print("bad probe fixture {s}: {s}\n", .{ pp, @errorName(e) });
            return 1;
        };
    } else dk.probe.live(arena, io) catch |e| {
        try err.print("can't probe this machine: {s}\n", .{@errorName(e)});
        return 1;
    };

    var entropy: [dk.files.ids_entropy]u8 = undefined;
    io.random(&entropy);
    const ids = try dk.files.idsFromBytes(arena, &entropy);

    var missing: std.ArrayList([]const u8) = .empty;
    for (dk.plan.required_programs) |prog| {
        if (!onPath(io, prog)) try missing.append(arena, prog);
    }

    // The terminal is opened only when there is a screen to show.
    var terminal: dk.term.Terminal = undefined;
    var have_term = false;
    defer if (have_term) terminal.deinit();
    var ui: dk.ui.Ui = undefined;
    var have_ui = false;
    defer if (have_ui) ui.screen.deinit(init.gpa);

    var run_answers: ?dk.answers.Answers = file_answers;
    const plan: dk.plan.Plan = if (file_answers) |answers| blk: {
        const result = try dk.plan.build(arena, probe, answers, ids);
        const plan = switch (result) {
            .plan => |p| p,
            .refused => |why| {
                try err.print("refused: {s}\n", .{why});
                return 1;
            },
        };
        if (executing and erase_disk == null) {
            const disk = probe.findDisk(answers.disk).?;
            try openTerminal(&terminal, &ui, init.gpa, arena, io, ascii);
            have_term = true;
            have_ui = true;
            if (!try dk.ui.confirmPlan(&ui, disk, plan)) return 130;
        }
        break :blk plan;
    } else blk: {
        const env: dk.ui.Env = .{
            .is_root = probe_path != null or std.os.linux.geteuid() == 0,
            .missing = missing.items,
            .dry_run = dry_run,
            .ids = ids,
            .cfdisk = onPath(io, "cfdisk"),
        };
        try openTerminal(&terminal, &ui, init.gpa, arena, io, ascii);
        have_term = true;
        have_ui = true;
        const outcome = dk.ui.run(&ui, probe, env);
        const done = (outcome catch |e| switch (e) {
            error.Quit => return 130,
            else => return e,
        }) orelse return 130;
        run_answers = done.answers;
        break :blk done.plan;
    };

    if (dry_run) {
        if (have_term) {
            terminal.deinit();
            have_term = false;
        }
        for (plan.programs) |prog| {
            if (!onPath(io, prog)) try err.print("warning: {s} not found in PATH directories\n", .{prog});
        }
        var out_buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
        try plan.writeDryRun(&out_w.interface);
        try out_w.interface.flush();
        return 0;
    }

    // SPEC.md 5.1: every program the plan runs must exist before anything is written.
    var absent: std.ArrayList([]const u8) = .empty;
    for (plan.programs) |prog| {
        if (!onPath(io, prog)) try absent.append(arena, prog);
    }
    if (absent.items.len > 0) {
        if (have_term) {
            terminal.deinit();
            have_term = false;
        }
        for (absent.items) |prog| try err.print("missing program: {s}\n", .{prog});
        return 1;
    }
    if (!isLiveDisc(io)) {
        if (have_term) {
            terminal.deinit();
            have_term = false;
        }
        try err.print("not running from the live disc ({s} missing): installing from an installed system isn't supported\n", .{dk.plan.rootfs_sfs});
        return 1;
    }

    const info = try dk.execute.describeRun(arena, probe, run_answers.?);
    if (have_term) {
        const end = dk.ui.install(&ui, io, plan, info) catch |e| {
            terminal.deinit();
            have_term = false;
            try err.print("install error: {s}; log: {s}\n", .{ @errorName(e), dk.execute.log_path });
            return 1;
        };
        terminal.deinit();
        have_term = false;
        switch (end) {
            .reboot => {
                var child = std.process.spawn(io, .{ .argv = &.{"reboot"} }) catch return 0;
                _ = child.wait(io) catch {};
                return 0;
            },
            .live => return 0,
            .quit => return 1,
        }
    }

    // Unattended.
    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var plain: Plain = .{ .out = &out_w.interface, .total = plan.steps.len };
    var runner = dk.execute.Runner.init(init.gpa, io, dk.execute.log_path, .{
        .ctx = &plain,
        .on_start = Plain.onStart,
        .on_line = Plain.onLine,
    }) catch |e| {
        try err.print("can't open the log {s}: {s}\n", .{ dk.execute.log_path, @errorName(e) });
        return 1;
    };
    defer runner.deinit();
    runner.header(info);
    switch (try runner.run(plan.steps)) {
        .ok => {
            try out_w.interface.print("Installation complete.\n", .{});
            try out_w.interface.flush();
            return 0;
        },
        .failed => |f| {
            runner.cleanup();
            try err.print("\nstep {d} failed: {s}\n$ {s}\n{s}\n", .{ f.index + 1, f.desc, f.text, f.reason });
            for (f.tail) |l| try err.print("    {s}\n", .{l});
            try err.print("log: {s}\n", .{dk.execute.log_path});
            return 1;
        },
    }
}

fn openTerminal(terminal: *dk.term.Terminal, ui: *dk.ui.Ui, gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, ascii: bool) !void {
    terminal.init(io) catch |e| {
        std.debug.print("the screens need a terminal: {s}\n", .{@errorName(e)});
        return error.NoTerminal;
    };
    const sz = terminal.size();
    ui.* = .{
        .gpa = gpa,
        .arena = arena,
        .screen = try dk.term.Screen.init(gpa, sz.w, sz.h, ascii),
        .terminal = terminal,
    };
}

fn isLiveDisc(io: Io) bool {
    Io.Dir.accessAbsolute(io, dk.plan.rootfs_sfs, .{}) catch return false;
    return true;
}

fn onPath(io: Io, prog: []const u8) bool {
    const dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };
    var buf: [256]u8 = undefined;
    for (dirs) |d| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, prog }) catch continue;
        Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return true;
    }
    return false;
}
