const std = @import("std");
const builtin = @import("builtin");
const mysqlzig = @import("mysqlzig");

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    var cfg: mysqlzig.Config = .{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    if (try parseArgs(&args, &cfg)) return;
    installSignalHandlers();

    var server = mysqlzig.Server.init(std.heap.smp_allocator, cfg);
    defer server.deinit();
    try server.start();
    std.debug.print("mysqlzig listening on {s}:{d}, dump={s}\n", .{ cfg.bind_host, cfg.port, cfg.dump_path });

    var sleeper: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer sleeper.deinit();
    const sleep_io = sleeper.io();
    while (server.isRunning() and !shutdown_requested.load(.acquire)) {
        std.Io.sleep(sleep_io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    if (shutdown_requested.load(.acquire)) {
        std.debug.print("mysqlzig stopping, writing dump={s}\n", .{cfg.dump_path});
        server.stop();
    } else {
        server.wait();
    }
}

fn parseArgs(args: *std.process.Args.Iterator, cfg: *mysqlzig.Config) !bool {
    var positional: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            cfg.port = try parsePort(args.next() orelse return error.MissingPort);
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            cfg.port = try parsePort(arg["--port=".len..]);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dump")) {
            cfg.dump_path = args.next() orelse return error.MissingDumpPath;
        } else if (std.mem.startsWith(u8, arg, "--dump=")) {
            cfg.dump_path = arg["--dump=".len..];
        } else if (std.mem.eql(u8, arg, "--host")) {
            cfg.bind_host = args.next() orelse return error.MissingHost;
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            cfg.bind_host = arg["--host=".len..];
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--memory")) {
            cfg.memory_size = try parseSize(args.next() orelse return error.MissingMemorySize);
        } else if (std.mem.startsWith(u8, arg, "--memory=")) {
            cfg.memory_size = try parseSize(arg["--memory=".len..]);
        } else if (std.mem.eql(u8, arg, "--user")) {
            cfg.username = args.next() orelse return error.MissingUser;
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            cfg.username = arg["--user=".len..];
        } else if (std.mem.eql(u8, arg, "--password")) {
            cfg.password = args.next() orelse return error.MissingPassword;
        } else if (std.mem.startsWith(u8, arg, "--password=")) {
            cfg.password = arg["--password=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown option: {s}\n\n", .{arg});
            printHelp();
            return error.UnknownOption;
        } else {
            switch (positional) {
                0 => cfg.port = try parsePort(arg),
                1 => cfg.dump_path = arg,
                else => return error.TooManyArguments,
            }
            positional += 1;
        }
    }
    return false;
}

fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  mysqlzig-server [port] [dump_path]
        \\  mysqlzig-server [options]
        \\
        \\Options:
        \\  -h, --help              Show this help.
        \\  -p, --port <port>       Listen port. Default: 3306.
        \\  -d, --dump <path>       Dump file path. Default: mysqlzig.dump.
        \\      --host <addr>       Bind host. Default: 127.0.0.1.
        \\  -m, --memory <size>     mmap size, e.g. 256m, 1g, 1048576.
        \\      --user <name>       Username. Default: root.
        \\      --password <pass>   Password. Default: empty.
        \\
        \\Stop:
        \\  Press Ctrl+C on macOS/Linux, or run SQL `shutdown`; shutdown writes the dump file.
        \\
    , .{});
}

fn parsePort(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 10);
}

fn parseSize(text: []const u8) !usize {
    if (text.len == 0) return error.BadMemorySize;
    const suffix = std.ascii.toLower(text[text.len - 1]);
    const has_suffix = suffix == 'k' or suffix == 'm' or suffix == 'g';
    const number_text = if (has_suffix) text[0 .. text.len - 1] else text;
    const base = try std.fmt.parseInt(usize, number_text, 10);
    return switch (suffix) {
        'k' => base * 1024,
        'm' => base * 1024 * 1024,
        'g' => base * 1024 * 1024 * 1024,
        else => base,
    };
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    if (std.posix.SIG == void or std.posix.Sigaction == void) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}
