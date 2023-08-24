const std = @import("std");
const Allocator = std.mem.Allocator;

// - larger name buffer
// - ensure extended header size does not exceed buffer
// - add tests
// - no try in advance?
pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var f = try std.fs.cwd().openFile("he/bad2.t", .{ .mode = .read_only });
    defer f.close();
    var dir = try std.fs.cwd().makeOpenPathIterable("eh", .{});

    try std.tar.pipeToFileSystem(dir.dir, f.reader(), .{
        .strip_components = 1,
        .mode_mode = .ignore,
    });

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    // var http_client: std.http.Client = .{ .allocator = gpa.allocator() };
    // defer http_client.deinit();

    // var eh = try fetchAndUnpack(
    //     &http_client,
    //     "https://github.com/ziglang/zig/archive/bf827d0b555df47ad2a2ea2062e2c855255c74d1.tar.gz",
    //     // "https://pkg.machengine.org/vulkan-headers/0212dd8b71531d0cec8378ce8fb1721a0df7420a.tar.gz",
    // );
    // std.debug.print("{}\n", .{eh});

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    try stdout.print("Run `zig build test` to run the tests.\n", .{});
    try bw.flush();
}

fn fetchAndUnpack(http_client: *std.http.Client, url: []const u8) !bool {
    const gpa = http_client.allocator;
    const uri = try std.Uri.parse(url);

    var dir = try std.fs.cwd().makeOpenPathIterable("eh", .{});

    var h = std.http.Headers{ .allocator = gpa };
    defer h.deinit();

    var req = try http_client.request(.GET, uri, h, .{});
    defer req.deinit();

    try req.start();
    try req.wait();

    if (req.response.status != .ok) {
        return false;
    }

    // const payload = try req.reader().readAllAlloc(gpa, std.math.maxInt(usize));
    // if (payload.len > 0) {
    //     std.log.warn("{}", .{payload.len});
    //     try dir.dir.writeFile("payload", payload);
    //     return false;
    // }

    const content_type = req.response.headers.getFirstValue("Content-Type") orelse return false;

    if (std.ascii.eqlIgnoreCase(content_type, "application/gzip") or
        std.ascii.eqlIgnoreCase(content_type, "application/x-gzip") or
        std.ascii.eqlIgnoreCase(content_type, "application/tar+gzip"))
    {
        // I observed the gzip stream to read 1 byte at a time, so I am using a
        // buffered reader on the front of it.
        try unpackTarball(gpa, req.reader(), dir.dir, std.compress.gzip);
    } else if (std.ascii.eqlIgnoreCase(content_type, "application/x-xz")) {
        // I have not checked what buffer sizes the xz decompression implementation uses
        // by default, so the same logic applies for buffering the reader as for gzip.
        try unpackTarball(gpa, req.reader(), dir.dir, std.compress.xz);
    } else if (std.ascii.eqlIgnoreCase(content_type, "application/octet-stream")) {
        // support gitlab tarball urls such as https://gitlab.com/<namespace>/<project>/-/archive/<sha>/<project>-<sha>.tar.gz
        // whose content-disposition header is: 'attachment; filename="<project>-<sha>.tar.gz"'
        const content_disposition = req.response.headers.getFirstValue("Content-Disposition") orelse return false;
        if (isTarAttachment(content_disposition)) {
            try unpackTarball(gpa, req.reader(), dir.dir, std.compress.gzip);
        } else return false;
    } else {
        return false;
    }

    return true;
}

fn unpackTarball(
    gpa: Allocator,
    req_reader: anytype,
    out_dir: std.fs.Dir,
    comptime compression: type,
) !void {
    var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, req_reader);

    var decompress = try compression.decompress(gpa, br.reader());
    defer decompress.deinit();

    try std.tar.pipeToFileSystem(out_dir, decompress.reader(), .{
        .strip_components = 1,
        // TODO: we would like to set this to executable_bit_only, but two
        // things need to happen before that:
        // 1. the tar implementation needs to support it
        // 2. the hashing algorithm here needs to support detecting the is_executable
        //    bit on Windows from the ACLs (see the isExecutable function).
        .mode_mode = .ignore,
    });
}

fn isTarAttachment(content_disposition: []const u8) bool {
    const disposition_type_end = std.ascii.indexOfIgnoreCase(content_disposition, "attachment;") orelse return false;

    var value_start = std.ascii.indexOfIgnoreCasePos(content_disposition, disposition_type_end + 1, "filename") orelse return false;
    value_start += "filename".len;
    if (content_disposition[value_start] == '*') {
        value_start += 1;
    }
    if (content_disposition[value_start] != '=') return false;
    value_start += 1;

    var value_end = std.mem.indexOfPos(u8, content_disposition, value_start, ";") orelse content_disposition.len;
    if (content_disposition[value_end - 1] == '\"') {
        value_end -= 1;
    }
    return std.ascii.endsWithIgnoreCase(content_disposition[value_start..value_end], ".tar.gz");
}

test "trace" {
    // error: TarComponentsOutsideStrippedPrefix
    // /home/lordmzte/dev/zig/lib/std/tar.zig:181:13: 0x6000f17 in stripComponents (zig)
    //             return error.TarComponentsOutsideStrippedPrefix;
    //             ^
    // /home/lordmzte/dev/zig/lib/std/tar.zig:130:35: 0x6001c2c in pipeToFileSystem__anon_49378 (zig)
    //                 const file_name = try stripComponents(unstripped_file_name, options.strip_components);
    //                                   ^
    // /home/lordmzte/dev/zig/src/Package.zig:561:5: 0x6002a57 in unpackTarball__anon_49145 (zig)
    //     try std.tar.pipeToFileSystem(out_dir, decompress.reader(), .{
    //     ^
    // /home/lordmzte/dev/zig/src/Package.zig:490:13: 0x60139ea in fetchAndUnpack (zig)
    //             try unpackTarball(gpa, &req, tmp_directory.handle, std.compress.gzip);
    //             ^
    // /home/lordmzte/dev/zig/src/Package.zig:282:25: 0x6018e6b in fetchAndAddDependencies (zig)
    //         const sub_pkg = try fetchAndUnpack(
    //                         ^
    // /home/lordmzte/dev/zig/src/main.zig:4402:13: 0x5e7a46a in cmdBuild (zig)
    //             try fetch_result;
    //             ^
    // /home/lordmzte/dev/zig/src/main.zig:298:9: 0x5e46dfb in mainArgs (zig)
    //         return cmdBuild(gpa, arena, cmd_args);
    //         ^
    // /home/lordmzte/dev/zig/src/main.zig:211:5: 0x5e458eb in main (zig)
    //     return mainArgs(gpa, arena, args);
    //     ^
}
