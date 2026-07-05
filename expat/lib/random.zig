const std = @import("std");
const builtin = @import("builtin");

pub export fn writeRandomBytes(target: ?*anyopaque, count: usize) void {
    const buf: [*]u8 = @ptrCast(target);
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos,
        .freebsd, .netbsd, .openbsd, .dragonfly, .illumos,
        => std.c.arc4random_buf(buf, count),

        .linux => {
            var done: usize = 0;
            while (done < count) {
                const rc = std.os.linux.getrandom(buf + done, count - done, 0);
                if (rc == 0 or (rc > 0 and @as(isize, @bitCast(rc)) > 0)) {
                    done += @intCast(if (rc == 0) count - done else @as(usize, @bitCast(@as(isize, @bitCast(rc)))));
                } else {
                    const err = @as(std.os.linux.E, @enumFromInt(@as(u16, @intCast(-@as(isize, @bitCast(rc))))));
                    if (err != .INTR) break;
                }
            }
        },

        .windows => {
            var done: usize = 0;
            while (done < count) {
                const c = @cImport({
                    @cInclude("stdlib.h");
                });
                var val: c_uint = 0;
                if (c.rand_s(&val) != 0) break;
                const bytes = std.mem.asBytes(&val);
                const to_use = @min(count - done, bytes.len);
                @memcpy(buf + done [0..to_use], bytes[0..to_use]);
                done += to_use;
            }
        },

        else => {
            // Fallback: read from /dev/urandom
            const fd = std.posix.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return;
            defer std.posix.close(fd);
            var done: usize = 0;
            while (done < count) {
                const n = std.posix.read(fd, buf + done [0 .. count - done]) catch break;
                if (n == 0) break;
                done += n;
            }
        },
    }
}
