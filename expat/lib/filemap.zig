const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const XML_MAX_CHUNK_LEN: usize = @as(usize, @intCast(@as(i64, std.math.maxInt(i32)) / 2 + 1));

const ProcessorFn = *const fn (?*const anyopaque, usize, [*:0]const u8, ?*anyopaque) callconv(.c) void;

pub export fn filemap(
    name: [*:0]const u8,
    processor: ProcessorFn,
    arg: ?*anyopaque,
) c_int {
    if (is_windows) {
        return filemapWindows(name, processor, arg);
    } else {
        return filemapUnix(name, processor, arg);
    }
}

fn filemapUnix(
    name: [*:0]const u8,
    processor: ProcessorFn,
    arg: ?*anyopaque,
) c_int {
    const fd = c.open(name, c.O_RDONLY);
    if (fd < 0) {
        c.perror(name);
        return 0;
    }
    defer _ = c.close(fd);

    var sb: c.struct_stat = undefined;
    if (c.fstat(fd, &sb) < 0) {
        c.perror(name);
        return 0;
    }

    if (sb.st_mode & c.S_IFMT != c.S_IFREG) {
        std.debug.print("{s}: not a regular file\n", .{name});
        return 0;
    }

    const size: usize = @intCast(sb.st_size);
    if (size > XML_MAX_CHUNK_LEN) {
        return 2;
    }

    if (size == 0) {
        const ch: u8 = 0;
        processor(@ptrCast(&ch), 0, name, arg);
        return 1;
    }

    const p = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (p == c.MAP_FAILED) {
        c.perror(name);
        return 0;
    }
    defer _ = c.munmap(p, size);

    processor(@ptrCast(p), size, name, arg);
    return 1;
}

fn filemapWindows(
    name: [*:0]const u8,
    processor: ProcessorFn,
    arg: ?*anyopaque,
) c_int {
    const c_win = @cImport({
        @cInclude("windows.h");
    });

    const f = c_win.CreateFileA(
        name,
        c_win.GENERIC_READ,
        c_win.FILE_SHARE_READ,
        null,
        c_win.OPEN_EXISTING,
        c_win.FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (f == c_win.INVALID_HANDLE_VALUE) {
        c.perror(name);
        return 0;
    }
    defer _ = c_win.CloseHandle(f);

    var size_hi: c_win.DWORD = 0;
    const size = c_win.GetFileSize(f, &size_hi);
    if (size == c_win.INVALID_FILE_SIZE) {
        c.perror(name);
        return 0;
    }

    if (size_hi != 0 or size > XML_MAX_CHUNK_LEN) {
        return 2;
    }

    if (size == 0) {
        const ch: u8 = 0;
        processor(@ptrCast(&ch), 0, name, arg);
        return 1;
    }

    const m = c_win.CreateFileMappingA(
        f,
        null,
        c_win.PAGE_READONLY,
        0,
        0,
        null,
    );
    if (m == null) {
        c.perror(name);
        return 0;
    }
    defer _ = c_win.CloseHandle(m);

    const p = c_win.MapViewOfFile(
        m,
        c_win.FILE_MAP_READ,
        0,
        0,
        0,
    );
    if (p == null) {
        c.perror(name);
        return 0;
    }
    defer _ = c_win.UnmapViewOfFile(p);

    processor(@ptrCast(p), size, name, arg);
    return 1;
}
