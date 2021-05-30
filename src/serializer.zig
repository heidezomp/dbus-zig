const std = @import("std");

pub fn Serializer(comptime Writer: type, endian: std.builtin.Endian) type {
    return struct {
        writer: std.io.CountingWriter(Writer),

        const Self = @This();

        pub fn serialize(self: *Self, value: anytype) !void {
            const T = @TypeOf(value);
            const writer = self.writer.writer();
            switch (T) {
                u8 => {
                    try writer.writeByte(value);
                },
                bool => {
                    try self.alignForward(4);
                    try writer.writeInt(u32, @boolToInt(value), endian);
                },
                i16, u16, i32, u32, i64, u64 => {
                    try self.alignForward(@sizeOf(T));
                    try writer.writeInt(T, value, endian);
                },
                f64 => {
                    try self.alignForward(8);
                    if (endian == std.Target.current.cpu.arch.endian()) {
                        try writer.writeAll(std.mem.asBytes(&value));
                    } else {
                        var bytes = std.mem.toBytes(value);
                        std.mem.reverse(u8, &bytes);
                        try writer.writeAll(&bytes);
                    }
                },
                else => {
                    // Not a primitive type; assume it has a serialize method
                    value.serialize(self);
                },
            }
        }

        pub fn alignForward(self: *Self, alignment: usize) !void {
            var align_bytes = std.mem.alignForward(self.writer.bytes_written, alignment) - self.writer.bytes_written;
            const writer = self.writer.writer();
            while (align_bytes != 0) : (align_bytes -= 1) {
                try writer.writeByte(0);
            }
        }
    };
}

pub fn serializer(writer: anytype, comptime endian: std.builtin.Endian) Serializer(@TypeOf(writer), endian) {
    return .{ .writer = std.io.countingWriter(writer) };
}

test "serialize" {
    try testSerialize(.Little);
    try testSerialize(.Big);
}

fn testSerialize(comptime endian: std.builtin.Endian) !void {
    var out_buffer: [1024]u8 = undefined;

    var stream = std.io.fixedBufferStream(&out_buffer);
    var ser = serializer(stream.writer(), endian);

    const false_value = "\x00\x00\x00\x00";
    const true_value = switch (endian) {
        .Little => "\x01\x00\x00\x00",
        .Big => "\x00\x00\x00\x01",
    };

    stream.reset();
    ser.writer.bytes_written = 0;
    try ser.serialize(false);
    try std.testing.expectEqual(@as(usize, 4), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, false_value, stream.getWritten());

    stream.reset();
    ser.writer.bytes_written = 0;
    try ser.serialize(true);
    try std.testing.expectEqual(@as(usize, 4), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, true_value, stream.getWritten());

    stream.reset();
    ser.writer.bytes_written = 1;
    try ser.serialize(false);
    try std.testing.expectEqual(@as(usize, 8), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ false_value, stream.getWritten());

    stream.reset();
    ser.writer.bytes_written = 1;
    try ser.serialize(true);
    try std.testing.expectEqual(@as(usize, 8), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ true_value, stream.getWritten());

    const u16_value = switch (endian) {
        .Little => "\x34\x12",
        .Big => "\x12\x34",
    };

    stream.reset();
    ser.writer.bytes_written = 0;
    try ser.serialize(@as(u16, 0x1234));
    try std.testing.expectEqual(@as(usize, 2), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, u16_value, stream.getWritten());

    stream.reset();
    ser.writer.bytes_written = 1;
    try ser.serialize(@as(u16, 0x1234));
    try std.testing.expectEqual(@as(usize, 4), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, "\x00" ++ u16_value, stream.getWritten());

    const float_value = switch (endian) {
        .Little => "\x00\x00\x00\x00\x00\x00\xf0\x3f",
        .Big => "\x3f\xf0\x00\x00\x00\x00\x00\x00",
    };

    stream.reset();
    ser.writer.bytes_written = 0;
    try ser.serialize(@as(f64, 1.0));
    try std.testing.expectEqual(@as(usize, 8), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, float_value, stream.getWritten());

    stream.reset();
    ser.writer.bytes_written = 1;
    try ser.serialize(@as(f64, 1.0));
    try std.testing.expectEqual(@as(usize, 16), ser.writer.bytes_written);
    try std.testing.expectEqualSlices(u8, "\x00" ** 7 ++ float_value, stream.getWritten());
}
