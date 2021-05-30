const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    socket: std.net.Stream,

    pub fn connectSessionBus() !Connection {
        const address = std.os.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
            return error.EnvironmentVariableNotFound;

        return Connection.connectAddress(address);
    }

    pub fn connectAddress(address: []const u8) !Connection {
        // TODO Parse address according to spec:
        // https://dbus.freedesktop.org/doc/dbus-specification.html#addresses
        const expected_address_prefix = "unix:path=";
        if (!std.mem.startsWith(u8, address, expected_address_prefix))
            return error.AddressUnimplemented;
        const socket_path = address[expected_address_prefix.len..];

        return Connection.connectUnixSocket(socket_path);
    }

    pub fn connectUnixSocket(path: []const u8) !Connection {
        const socket = try std.net.connectUnixSocket(path);
        errdefer socket.close();

        // Perform authentication
        // We only support the EXTERNAL authentication mechanism, which
        // authenticates (on unix systems) based on the user's uid
        const uid = std.os.system.getuid();
        var buffer: [100]u8 = undefined; // TODO use a BufferedReader/BufferedWriter and store them in the Connection
        var fbs = std.io.fixedBufferStream(&buffer);
        try fbs.writer().print("{}", .{uid});
        try socket.writer().print("\x00AUTH EXTERNAL {}\r\n", .{std.fmt.fmtSliceHexLower(fbs.getWritten())});
        const amt = try socket.read(&buffer);
        const response = buffer[0..amt];
        std.log.debug("auth response: «{s}»", .{std.fmt.fmtSliceEscapeLower(response)});
        if (std.mem.startsWith(u8, response, "OK ")) {
            // Rest of response is server GUID in hex, which we don't use
        } else if (std.mem.startsWith(u8, response, "REJECTED ")) {
            // Rest of response is a list of authentication mechanisms
            // supported, but we only support EXTERNAL
            return error.AuthenticationRejected;
        } else {
            return error.UnexpectedAuthenticationResponse;
        }
        try socket.writer().print("BEGIN\r\n", .{});

        // We now have an authenticated connection that is ready to send/receive D-Bus messages
        var self = Connection{ .socket = socket };

        // Send a Hello message to receive our connection's unique name
        try self.sendMessage();

        return self;
    }

    pub fn sendMessage(self: Connection) !void {
        const msg =
            "\x6c\x01\x00\x01\x00\x00\x00\x00\x01\x00\x00\x00\x6e\x00\x00\x00" ++
            "\x01\x01\x6f\x00\x15\x00\x00\x00\x2f\x6f\x72\x67\x2f\x66\x72\x65" ++
            "\x65\x64\x65\x73\x6b\x74\x6f\x70\x2f\x44\x42\x75\x73\x00\x00\x00" ++
            "\x06\x01\x73\x00\x14\x00\x00\x00\x6f\x72\x67\x2e\x66\x72\x65\x65" ++
            "\x64\x65\x73\x6b\x74\x6f\x70\x2e\x44\x42\x75\x73\x00\x00\x00\x00" ++
            "\x02\x01\x73\x00\x14\x00\x00\x00\x6f\x72\x67\x2e\x66\x72\x65\x65" ++
            "\x64\x65\x73\x6b\x74\x6f\x70\x2e\x44\x42\x75\x73\x00\x00\x00\x00" ++
            "\x03\x01\x73\x00\x05\x00\x00\x00\x48\x65\x6c\x6c\x6f\x00\x00\x00";
        //try self.socket.writer().writeAll(msg);

        comptime const endian = std.Target.current.cpu.arch.endian();
        var ser = serializer(self.socket.writer(), endian); // TODO put a BufferedWriter in between
        try ser.serialize(@as(u8, switch (endian) {
            .Little => 'l',
            .Big => 'B',
        }));
        try ser.serialize(MessageType.MethodCall.toByte());
        try ser.serialize((MessageFlags{}).toByte());
        try ser.serialize(@as(u8, 1)); // major protocol version
        try ser.serialize(@as(u32, 0)); // message body length
        try ser.serialize(@as(u32, 1)); // message serial number (non-zero)

        // Message header
        // TODO doesn't work; try to replicate the above message and write a test for it once it works

        //try self.socket.writer().writeIntNative(u32, 2); // array number of elements

        //try self.socket.writer().writeByte(3); // first array element field code: MEMBER
        //try self.socket.writer().writeByte(1); // signature length (excluding nul byte)
        //try self.socket.writer().writeAll("s\x00"); // signature: string (offset 20)
        //try self.socket.writer().writeIntNative(u32, 3); // string length (excluding nul byte)
        //try self.socket.writer().writeAll("foo\x00"); // member

        //try self.socket.writer().writeByte(3); // second array element field code: PATH
        //try self.socket.writer().writeByte(1); // signature length (excluding nul byte)
        //try self.socket.writer().writeAll("o\x00"); // signature: object path
        //try self.socket.writer().writeIntNative(u32, 7); // object path length (excluding nul byte)
        //try self.socket.writer().writeAll("/ab/bar\x00"); // member

        // read response?
        while (true) {
            var buffer: [4096]u8 = undefined;
            const amt = try self.socket.read(&buffer);
            const response = buffer[0..amt];
            std.log.debug("response: «{s}»", .{std.fmt.fmtSliceEscapeLower(response)});
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }

    pub fn disconnect(self: Connection) void {
        self.socket.close();
    }
};

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

const MessageType = enum(u8) {
    MethodCall = 1,
    MethodReturn = 2,
    Error = 3,
    Signal = 4,

    fn toByte(self: MessageType) u8 {
        return @enumToInt(self);
    }
};

const MessageFlags = packed struct {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _padding: u5 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8);
    }

    fn toByte(self: MessageFlags) u8 {
        const bytes = std.mem.asBytes(&self);
        comptime {
            std.debug.assert(bytes.len == 1);
        }
        return bytes[0];
    }
};

test {
    std.testing.refAllDecls(@This());
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
