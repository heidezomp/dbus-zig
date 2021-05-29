const std = @import("std");
const Allocator = std.mem.Allocator;

const endian = std.Target.current.cpu.arch.endian();

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
        try self.sendMessage(.{
            .message_type = .MethodCall,
            .serial = 1, // TODO but this should not be determined by the caller, but tracked as Connection state
        });

        return self;
    }

    pub fn sendMessage(self: Connection, message: Message) !void {
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

        var pos: usize = 0;
        pos = try serializeValue(self.socket.writer(), pos, @as(u8, switch (endian) {
            .Little => 'l',
            .Big => 'B',
        }));
        pos = try serializeValue(self.socket.writer(), pos, MessageType.MethodCall.toByte());
        pos = try serializeValue(self.socket.writer(), pos, (MessageFlags{}).toByte());
        pos = try serializeValue(self.socket.writer(), pos, @as(u8, 1)); // major protocol version
        pos = try serializeValue(self.socket.writer(), pos, @as(u32, 0)); // message body length
        pos = try serializeValue(self.socket.writer(), pos, @as(u32, 1)); // message serial number (non-zero)

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

const Message = struct { // TODO should a Message struct even exist? maybe just have a serializeMessage function with arguments? or more generic: serializeValue for serializing a single D-Bus value?
    endian: std.builtin.Endian = std.Target.current.cpu.arch.endian(),
    message_type: MessageType,
    flags: MessageFlags = .{},
    serial: u32,
};

fn serializeMessage(
    writer: anytype,
    message_type: MessageType,
    message_flags: MessageFlags,
    serial: u32,
    header_fields: Array(Struct(.{ Byte, Variant })),
) void {
    std.debug.assert(serial != 0);
}

fn serializeValue(writer: anytype, position: usize, value: anytype) !usize {
    const DbusType = @TypeOf(value);
    var cur_pos = std.mem.alignForward(position, alignOf(DbusType));
    var align_bytes = cur_pos - position;
    while (align_bytes != 0) : (align_bytes -= 1) {
        try writer.writeByte(0);
    }
    switch (DbusType) {
        u8 => {
            try writer.writeByte(value);
            cur_pos += 1;
        },
        bool => {
            try writer.writeIntNative(u32, @boolToInt(value));
            cur_pos += 4;
        },
        i16, u16, i32, u32, i64, u64 => {
            try writer.writeIntNative(DbusType, value);
            cur_pos += @sizeOf(DbusType);
        },
        f64 => {
            try writer.writeAll(std.mem.asBytes(&value));
            cur_pos += 8;
        },
        //String, ObjectPath => ...
        //Signature => ...
        //Array => ...
        //Struct => ...
        //Variant => ...
        //DictEntry => ...
        //UnixFd => ...
        else => @compileError(@typeName(DbusType) ++ " is not a D-Bus type"),
    }
    return cur_pos;
}

fn alignOf(comptime DbusType: type) usize {
    return switch (DbusType) {
        u8 => 1,
        bool => 4,
        i16, u16 => 2,
        i32, u32 => 4,
        i64, u64, f64 => 8,
        //String, ObjectPath => 4,
        //Signature => 1,
        //Array => 4,
        //Struct => 8,
        //Variant => 1,
        //DictEntry => 8,
        //UnixFd => 4,
        else => @compileError(@typeName(DbusType) ++ " is not a D-Bus type"),
    };
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

test "serializeValue" {
    var out_buffer: [1024]u8 = undefined;

    var stream = std.io.fixedBufferStream(&out_buffer);
    const writer = stream.writer();

    const false_value = "\x00\x00\x00\x00";
    const true_value = switch (endian) {
        .Little => "\x01\x00\x00\x00",
        .Big => "\x00\x00\x00\x01",
    };

    var position: usize = 0;
    position = try serializeValue(writer, position, false);
    try std.testing.expectEqual(@as(usize, 4), position);
    try std.testing.expectEqualSlices(u8, false_value, stream.getWritten());

    stream.reset();
    position = 0;
    position = try serializeValue(writer, position, true);
    try std.testing.expectEqual(@as(usize, 4), position);
    try std.testing.expectEqualSlices(u8, true_value, stream.getWritten());

    stream.reset();
    position = 1;
    position = try serializeValue(writer, position, false);
    try std.testing.expectEqual(@as(usize, 8), position);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ false_value, stream.getWritten());

    stream.reset();
    position = 1;
    position = try serializeValue(writer, position, true);
    try std.testing.expectEqual(@as(usize, 8), position);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ true_value, stream.getWritten());

    const u32_0_value = "\x00\x00\x00\x00";
    const u32_1_value = switch (endian) {
        .Little => "\x01\x00\x00\x00",
        .Big => "\x00\x00\x00\x01",
    };

    stream.reset();
    position = 0;
    position = try serializeValue(writer, position, @as(u32, 0));
    try std.testing.expectEqual(@as(usize, 4), position);
    try std.testing.expectEqualSlices(u8, u32_0_value, stream.getWritten());

    stream.reset();
    position = 0;
    position = try serializeValue(writer, position, @as(u32, 1));
    try std.testing.expectEqual(@as(usize, 4), position);
    try std.testing.expectEqualSlices(u8, u32_1_value, stream.getWritten());

    stream.reset();
    position = 1;
    position = try serializeValue(writer, position, @as(u32, 0));
    try std.testing.expectEqual(@as(usize, 8), position);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ u32_0_value, stream.getWritten());

    stream.reset();
    position = 1;
    position = try serializeValue(writer, position, @as(u32, 1));
    try std.testing.expectEqual(@as(usize, 8), position);
    try std.testing.expectEqualSlices(u8, "\x00" ** 3 ++ u32_1_value, stream.getWritten());
}
