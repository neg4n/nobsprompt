const std = @import("std");
const builtin = @import("builtin");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0")) @panic("nobsprompt requires exactly Zig 0.16.0");
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline, .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } } });
    if (target.result.os.tag != .macos or (target.result.cpu.arch != .aarch64 and target.result.cpu.arch != .x86_64)) @panic("supported targets: aarch64-macos and x86_64-macos");
    if (target.result.os.version_range.semver.min.order(.{ .major = 13, .minor = 0, .patch = 0 }) == .lt) @panic("minimum supported deployment target: macOS 13");
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Debug, ReleaseSafe (default), ReleaseFast, ReleaseSmall") orelse .ReleaseSafe;
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .single_threaded = true, .strip = optimize != .Debug });
    const exe = b.addExecutable(.{ .name = "nbsp", .root_module = module, .use_llvm = true });
    exe.link_gc_sections = true;
    b.installArtifact(exe);
    b.installFile("doc/nbsp.1", "share/man/man1/nbsp.1");
    b.installDirectory(.{ .source_dir = b.path("docs"), .install_dir = .prefix, .install_subdir = "share/doc/nobsprompt", .include_extensions = &.{".mdx"}, .exclude_extensions = &.{".ts"} });
    b.installFile("src/nbsp_opinionated.zsh", "share/doc/nobsprompt/get-started/opinionated-prompt.zsh");
    const test_step = b.step("test", "Unit and shell compatibility tests");
    const units = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true }), .use_llvm = true });
    const run_units = b.addRunArtifact(units);
    test_step.dependOn(&run_units.step);
    b.step("unit", "Unit and allocation-failure tests").dependOn(&run_units.step);
    const cli = b.addSystemCommand(&.{"sh"});
    cli.addFileArg(b.path("tests/test_cli.sh"));
    cli.addArtifactArg(exe);
    for ([_][]const u8{ "src/nbsp_zsh.zsh", "src/nbsp_opinionated.zsh", "src/nbsp_autosuggest.zsh" }) |path| cli.addFileArg(b.path(path));
    test_step.dependOn(&cli.step);
    const process_tests = b.addSystemCommand(&.{"sh"});
    process_tests.addFileArg(b.path("tests/test_process.sh"));
    process_tests.addArtifactArg(exe);
    test_step.dependOn(&process_tests.step);
    for ([_][]const u8{ "src/nbsp_zsh.zsh", "src/nbsp_opinionated.zsh", "src/nbsp_autosuggest.zsh" }) |path| {
        const syntax = b.addSystemCommand(&.{ "zsh", "-n" });
        syntax.addFileArg(b.path(path));
        test_step.dependOn(&syntax.step);
    }
    for ([_][]const u8{ "tests/test_zsh_data.zsh", "tests/test_zsh_options.zsh", "tests/test_zsh_quote_parity.zsh" }) |path| {
        const shell = b.addSystemCommand(&.{ "zsh", "-f" });
        shell.addFileArg(b.path(path));
        if (!std.mem.endsWith(u8, path, "options.zsh")) shell.addArtifactArg(exe);
        if (!std.mem.endsWith(u8, path, "parity.zsh")) shell.addFileArg(b.path("src/nbsp_zsh.zsh"));
        test_step.dependOn(&shell.step);
    }
    const pty = b.option([]const u8, "zsh_tests", "Expect-backed tests: auto, enabled, disabled") orelse "auto";
    if (!std.mem.eql(u8, pty, "auto") and !std.mem.eql(u8, pty, "enabled") and !std.mem.eql(u8, pty, "disabled")) @panic("invalid zsh_tests option");
    const expect = if (std.mem.eql(u8, pty, "disabled")) null else b.findProgram(&.{"expect"}, &.{}) catch null;
    if (expect == null and std.mem.eql(u8, pty, "enabled")) @panic("Expect is required");
    if (expect) |program| {
        for ([_][]const u8{ "tests/test_zsh_integration.exp", "tests/test_zsh_detached.exp", "tests/test_zsh_autosuggest.exp", "tests/test_zsh_autosuggest.exp" }, 0..) |path, i| {
            const shell = b.addSystemCommand(&.{program});
            shell.addFileArg(b.path(path));
            shell.addArtifactArg(exe);
            if (i == 3) shell.addArg("--no-memo");
            test_step.dependOn(&shell.step);
        }
    }
    const fuzz = b.addExecutable(.{ .name = "fuzz-parsers", .root_module = b.createModule(.{ .root_source_file = b.path("src/fuzz.zig"), .target = target, .optimize = optimize, .link_libc = true, .single_threaded = true }), .use_llvm = true });
    const run_fuzz = b.addRunArtifact(fuzz);
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Deterministic mutation tests (250000 iterations by default)").dependOn(&run_fuzz.step);
    const measure = b.addExecutable(.{ .name = "measure-allocations", .root_module = b.createModule(.{ .root_source_file = b.path("src/measure.zig"), .target = target, .optimize = optimize, .link_libc = true, .single_threaded = true }), .use_llvm = true });
    b.step("measurement-tools", "Install allocation measurement tool for verification").dependOn(&b.addInstallArtifact(measure, .{}).step);
    const run_measure = b.addRunArtifact(measure);
    if (b.option([]const u8, "allocations_cwd", "Directory used for allocation measurements")) |cwd| run_measure.setCwd(.{ .cwd_relative = cwd });
    if (b.args) |args| run_measure.addArgs(args);
    b.step("allocations", "Measure explicit backend allocations (data or dirs)").dependOn(&run_measure.step);
    const memory = b.addSystemCommand(&.{"sh"});
    memory.addFileArg(b.path("tests/run_memory_checks.sh"));
    memory.addArg(b.graph.zig_exe);
    b.step("memory-check", "Debug/ReleaseSafe tests, allocation diagnostics, mutations").dependOn(&memory.step);
    const check = b.step("check", "Compile and check Zig formatting");
    check.dependOn(&exe.step);
    check.dependOn(&units.step);
    check.dependOn(&fuzz.step);
    check.dependOn(&measure.step);
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" }, .check = true });
    check.dependOn(&fmt.step);
    const benchmark = b.addSystemCommand(&.{"zsh"});
    benchmark.addFileArg(b.path("bench/benchmark.zsh"));
    if (b.args) |args| benchmark.addArgs(args);
    benchmark.addArg("--");
    benchmark.addArtifactArg(exe);
    benchmark.addArg(b.option([]const u8, "benchmark_command", "data (default) or dirs") orelse "data");
    benchmark.setEnvironmentVariable("NBSP_BENCH_COMPILER", "Zig 0.16.0");
    benchmark.setEnvironmentVariable("NBSP_BENCH_BUILD_TYPE", @tagName(optimize));
    benchmark.setEnvironmentVariable("NBSP_BENCH_CFLAGS", b.fmt("-O{s} -target {s} -fsingle-threaded", .{ @tagName(optimize), target.result.zigTriple(b.allocator) catch @panic("out of memory") }));
    benchmark.setEnvironmentVariable("NBSP_BENCH_LDFLAGS", "LLVM 21 codegen, Zig Mach-O linker, macOS system libc");
    b.step("benchmark", "Benchmark with declared compiler provenance").dependOn(&benchmark.step);
}
