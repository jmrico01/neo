const std = @import("std");

const zig_bearssl_build = @import("deps/zig-http/deps/zig-bearssl/build.zig");
const zig_http_build = @import("deps/zig-http/build.zig");

const PROJECT_NAME = "neo";

pub fn build(b: *std.build.Builder) void
{
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const installDirRoot = std.build.InstallDir {
        .custom = "",
    };
    const installDirStatic = std.build.InstallDir {
        .custom = "static",
    };

    const server = b.addExecutable(PROJECT_NAME, "src/server_main.zig");
    server.setBuildMode(mode);
    server.setTarget(target);
    zig_bearssl_build.addLib(server, target, "deps/zig-http/deps/zig-bearssl");
    zig_http_build.addLibClient(server, target, "deps/zig-http");
    zig_http_build.addLibCommon(server, target, "deps/zig-http");
    zig_http_build.addLibServer(server, target, "deps/zig-http");
    server.linkLibC();
    server.override_dest_dir = installDirRoot;
    server.install();

    const wasmTarget = std.zig.CrossTarget {
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = null
    };

    const lib = b.addSharedLibrary(PROJECT_NAME, "src/wasm_main.zig", .unversioned);
    lib.setBuildMode(mode);
    lib.setTarget(wasmTarget);
    lib.override_dest_dir = installDirStatic;
    lib.install();

    // const installDirData = std.build.InstallDir {
    //     .custom = "data",
    // };
    // b.installDirectory(.{
    //     .source_dir = "data",
    //     .install_dir = installDirData,
    //     .install_subdir = "",
    // });

    // const installDirScripts = std.build.InstallDir {
    //     .custom = "scripts",
    // };
    // b.installDirectory(.{
    //     .source_dir = "scripts",
    //     .install_dir = installDirScripts,
    //     .install_subdir = "",
    // });

    b.installDirectory(.{
        .source_dir = "static",
        .install_dir = installDirStatic,
        .install_subdir = "",
    });

    // const serverRun = server.run();
    // serverRun.step.dependOn(b.getInstallStep());
    // if (b.args) |args| {
    //     serverRun.addArgs(args);
    // }

    // const runStep = b.step("run", "Run the app");
    // runStep.dependOn(&serverRun.step);

    const runTests = b.step("test", "Run tests");

    const testSrcs = [_][]const u8 {
        "src/server_main.zig",
        "src/wasm_main.zig",
    };
    for (testSrcs) |src| {
        const tests = b.addTest(src);
        tests.setBuildMode(mode);
        tests.setTarget(target);
        tests.linkLibC();
        runTests.dependOn(&tests.step);
    }
}
