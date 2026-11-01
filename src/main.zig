//! Command line entry point (SPEC.md 7). Milestone I0: no screens and no
//! execution yet, so only `--dry-run` with `--answers` is accepted.

const std = @import("std");
const Io = std.Io;
const dk = @import("dkinstall");

const usage =
    \\usage: dkrescue-install --dry-run --answers FILE [--probe FILE] [--ascii]
    \\
    \\  --dry-run          print the plan instead of running it (required until I2)
    \\  --answers FILE     take every answer from FILE (INI) instead of the screens
    \\  --probe FILE       use a recorded probe fixture instead of this machine
    \\  --yes-really-erase DISK   (not yet implemented)
    \\  --ascii            ASCII box drawing
    \\
;

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
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
        } else if (std.mem.eql(u8, arg, "--answers") or std.mem.eql(u8, arg, "--probe")) {
            i += 1;
            if (i >= args.len) {
                try err.print("{s} needs a file name\n{s}", .{ arg, usage });
                return 2;
            }
            if (std.mem.eql(u8, arg, "--answers")) answers_path = args[i] else probe_path = args[i];
        } else if (std.mem.eql(u8, arg, "--yes-really-erase")) {
            try err.print("--yes-really-erase needs the installer to execute plans (milestone I2)\n", .{});
            return 2;
        } else {
            try err.print("unknown argument: {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (!dry_run) {
        try err.print("dkrescue-install can only --dry-run for now: screens come in I1, execution in I2\n{s}", .{usage});
        return 2;
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

    // Plan
    var entropy: [dk.files.ids_entropy]u8 = undefined;
    io.random(&entropy);
    const ids = try dk.files.idsFromBytes(arena, &entropy);
    const plan: dk.plan.Plan = if (file_answers) |answers| blk: {
        const result = try dk.plan.build(arena, probe, answers, ids);
        break :blk switch (result) {
            .plan => |p| p,
            .refused => |why| {
                try err.print("refused: {s}\n", .{why});
                return 1;
            },
        };
    } else blk: {
        // The screens.
        var missing: std.ArrayList([]const u8) = .empty;
        for (dk.plan.required_programs) |prog| {
            if (!onPath(io, prog)) try missing.append(arena, prog);
        }
        const env: dk.ui.Env = .{
            .is_root = probe_path != null or std.os.linux.geteuid() == 0,
            .missing = missing.items,
            .dry_run = dry_run,
            .ids = ids,
        };
        var terminal: dk.term.Terminal = undefined;
        terminal.init(io) catch |e| {
            try err.print("the screens need a terminal: {s}\n", .{@errorName(e)});
            return 1;
        };
        const sz = terminal.size();
        var ui: dk.ui.Ui = .{
            .gpa = init.gpa,
            .arena = arena,
            .screen = try dk.term.Screen.init(init.gpa, sz.w, sz.h, ascii),
            .terminal = &terminal,
        };
        const outcome = dk.ui.run(&ui, probe, env);
        terminal.deinit();
        const done = (outcome catch |e| switch (e) {
            error.Quit => return 130,
            else => return e,
        }) orelse return 130;
        break :blk done.plan;
    };

    // Missing programs are a warning in a dry run (5.1 makes them an error
    // once the installer executes).
    for (plan.programs) |prog| {
        if (!onPath(io, prog)) try err.print("warning: {s} not found in PATH directories\n", .{prog});
    }

    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    try plan.writeDryRun(&out_w.interface);
    try out_w.interface.flush();
    return 0;
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
