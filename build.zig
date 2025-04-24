const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{});
    const upstream_root = upstream.path(".");

    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zpaq",
        .target = target,
        .optimize = optimize,
    });

    switch (target.result.os.tag) {
        .windows => {},
        else => {
            lib.root_module.addCMacro("unix", "");
        },
    }
    switch (optimize) {
        .Debug => {
            lib.root_module.addCMacro("DEBUG", "");
        },
        .ReleaseSmall, .ReleaseFast, .ReleaseSafe => {},
    }

    const supports_jit = target.result.cpu.arch.isX86() and target.result.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.sse2));
    if (!supports_jit) {
        lib.root_module.addCMacro("NOJIT", "");
    }

    lib.addCSourceFiles(.{
        .root = upstream_root,
        .files = &[_][]const u8{
            "libzpaq.cpp",
        },
        .flags = &[_][]const u8{
            "-Wall",
        },
    });
    lib.linkLibCpp();
    lib.installHeader(upstream_root.path(b, "libzpaq.h"), "libzpaq.h");
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zpaq",
        .target = target,
        .optimize = optimize,
    });
    switch (optimize) {
        .Debug => {},
        .ReleaseSmall, .ReleaseFast, .ReleaseSafe => {
            // In release modes we need to override the __DATE__
            // macro to make the build reproducible. We'll set it
            // to the release date.
            exe.root_module.addCMacro("__DATE__", "\"Sep 21 2016\"");
        },
    }
    exe.addCSourceFiles(.{
        .root = upstream_root,
        .files = &[_][]const u8{"zpaq.cpp"},
    });
    exe.linkLibrary(lib);
    b.installArtifact(exe);

    const test_step = b.step("test", "run the tests");
    {
        const run = b.addRunArtifact(exe);
        run.addCheck(.{ .expect_stdout_match = "zpaq v7.15 journaling archiver" });
        test_step.dependOn(&run.step);
    }
    addArchiveExtract(b, exe, test_step, &.{
        .{ .subpath = "test.txt", .content = "This is test content for ZPAQ compression" },
    });
    addArchiveExtract(b, exe, test_step, &.{
        .{ .subpath = "foo", .content = "The foo file with the foo content!\nAnother Line\n" },
        .{ .subpath = "bar", .content = "Another\nfile, bar\n, to test more content.\n" },
        .{ .subpath = "baz/buz", .content = "A file in a subdirectory!" },
    });
}

const File = struct {
    subpath: []const u8,
    content: []const u8,
};

fn addArchiveExtract(
    b: *std.Build,
    zpaq_exe: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    files: []const File,
) void {
    for (0..6) |method| {
        const write_files = b.addWriteFiles();
        for (files) |file| {
            _ = write_files.add(file.subpath, file.content);
        }
        const archive = b.addRunArtifact(zpaq_exe);
        archive.setCwd(write_files.getDirectory());
        archive.addArg("a");
        const archive_file = archive.addOutputFileArg("test.zpaq");
        for (files) |file| {
            archive.addArg(file.subpath);
        }
        archive.addArg("-method");
        archive.addArg(b.fmt("{d}", .{method}));
        archive.addCheck(.{ .expect_stderr_match = "all OK" });

        {
            const list = b.addRunArtifact(zpaq_exe);
            list.addArg("l");
            list.addFileArg(archive_file);
            list.addCheck(.{ .expect_stderr_match = "all OK" });
            for (files) |file| {
                list.addCheck(.{ .expect_stdout_match = file.subpath });
                list.addCheck(.{ .expect_stdout_match = b.fmt("{d}", .{file.content.len}) });
            }
            test_step.dependOn(&list.step);
        }

        {
            const extract = b.addRunArtifact(zpaq_exe);
            extract.addArg("x");
            extract.addFileArg(archive_file);
            extract.addArg("-to");
            extract.addCheck(.{ .expect_stderr_match = "all OK" });
            const extract_dir = extract.addOutputFileArg("extracted");
            for (files) |file| {
                extract.addCheck(.{ .expect_stdout_match = file.subpath });
                //extract.addCheck(.{ .expect_stdout_match = b.fmt("{d}", .{file.content.len}) });

                const check = b.addCheckFile(extract_dir.path(b, file.subpath), .{ .expected_exact = file.content });
                test_step.dependOn(&check.step);
            }
        }
    }
}
