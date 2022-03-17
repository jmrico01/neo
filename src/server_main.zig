const builtin = @import("builtin");
const std = @import("std");

const http = @import("http-common");
const server = @import("http-server");

const SERVER_IP = "0.0.0.0";

pub const log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .info,
    .ReleaseFast => .info,
    .ReleaseSmall => .info,
};

const ServerCallbackError = server.Writer.Error || error {InternalServerError};

const ServerState = struct {
    allocator: std.mem.Allocator,
};

fn serverCallback(state: *ServerState, request: server.Request, writer: server.Writer) !void
{
    const allocator = state.allocator;
    const host = http.getHeader(request, "Host") orelse return error.NoHost;
    _ = host;

    switch (request.method) {
        .Get => {
            try server.serveStatic(writer, request.uri, "static", allocator);
        },
        .Post => {
            try server.writeCode(writer, ._404);
            try server.writeEndHeader(writer);
        },
    }
}

fn serverCallbackWrapper(
    state: *ServerState,
    request: server.Request,
    writer: server.Writer) ServerCallbackError!void
{
    serverCallback(state, request, writer) catch |err| {
        std.log.err("serverCallback failed, error {}", .{err});
        const code = http.Code._500;
        try server.writeCode(writer, code);
        try server.writeEndHeader(writer);
        return error.InternalServerError;
    };
}

fn httpRedirectCallback(_: void, request: server.Request, writer: server.Writer) !void
{
    var buf: [2048]u8 = undefined;
    const host = http.getHeader(request, "Host") orelse return error.NoHost;
    const redirectUrl = try std.fmt.bufPrint(&buf, "https://{s}{s}", .{host, request.uriFull});

    try server.writeCode(writer, ._301);
    try server.writeHeader(writer, .{.name = "Location", .value = redirectUrl});
    try server.writeEndHeader(writer);
}

fn httpRedirectEntrypoint(allocator: std.mem.Allocator) !void
{
    var s = try server.Server(void).init(httpRedirectCallback, {}, null, allocator);
    const port = 80;

    std.log.info("Listening on {s}:{} (HTTP -> HTTPS redirect)", .{SERVER_IP, port});
    s.listen(SERVER_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
        return err;
    };
    s.stop();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("GPA detected leaks", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len < 2) {
        std.log.err("Expected arguments: port [<https-chain-path> <https-key-path>]", .{});
        return error.BadArgs;
    }

    const port = try std.fmt.parseUnsigned(u16, args[1], 10);
    const HttpsArgs = struct {
        chainPath: []const u8,
        keyPath: []const u8,
    };
    var httpsArgs: ?HttpsArgs = null;
    if (args.len > 2) {
        if (args.len != 4) {
            std.log.err("Expected arguments: port [<https-chain-path> <https-key-path>]", .{});
            return error.BadArgs;
        }
        httpsArgs = HttpsArgs {
            .chainPath = args[2],
            .keyPath = args[3],
        };
    }

    var state = ServerState {
        .allocator = allocator,
    };
    var s: server.Server(*ServerState) = undefined;
    var httpRedirectThread: ?std.Thread = undefined;
    {
        if (httpsArgs) |ha| {
            const cwd = std.fs.cwd();
            const chainFile = try cwd.openFile(ha.chainPath, .{});
            defer chainFile.close();
            const chainFileData = try chainFile.readToEndAlloc(allocator, 1024 * 1024 * 1024);
            defer allocator.free(chainFileData);

            const keyFile = try cwd.openFile(ha.keyPath, .{});
            defer keyFile.close();
            const keyFileData = try keyFile.readToEndAlloc(allocator, 1024 * 1024 * 1024);
            defer allocator.free(keyFileData);

            const httpsOptions = server.HttpsOptions {
                .certChainFileData = chainFileData,
                .privateKeyFileData = keyFileData,
            };
            s = try server.Server(*ServerState).init(
                serverCallbackWrapper, &state, httpsOptions, allocator
            );
            httpRedirectThread = try std.Thread.spawn(.{}, httpRedirectEntrypoint, .{allocator});
        } else {
            s = try server.Server(*ServerState).init(
                serverCallbackWrapper, &state, null, allocator
            );
            httpRedirectThread = null;
        }
    }
    defer s.deinit();

    std.log.info("Listening on {s}:{} (HTTPS {})", .{SERVER_IP, port, httpsArgs != null});
    s.listen(SERVER_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
        return err;
    };
    s.stop();

    if (httpRedirectThread) |t| {
        t.detach(); // TODO we don't really care for now
    }
}
