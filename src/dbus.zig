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
        try self.sendMessage(.{
            .message_type = .method_call,
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
        try self.socket.writer().writeAll(msg);

        // Message header
        // TODO doesn't work; try to replicate the above message and write a test for it once it works

        //try self.socket.writer().writeByte(switch (std.Target.current.cpu.arch.endian()) {
        //    .Little => 'l',
        //    .Big => 'B',
        //});
        //try self.socket.writer().writeByte(@enumToInt(MessageType.METHOD_CALL));
        //try self.socket.writer().writeByte(0); // flags
        //try self.socket.writer().writeByte(1); // major protocol version
        //try self.socket.writer().writeIntNative(u32, 0); // message body length
        //try self.socket.writer().writeIntNative(u32, 1); // message serial number (non-zero)
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

const Message = struct {
    endian: std.builtin.Endian = std.Target.current.cpu.arch.endian(),
    message_type: MessageType,
    flags: MessageFlags = .{},
    serial: u32,
};

const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

const MessageFlags = packed struct {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _padding: u5 = 0,
};

comptime {
    std.debug.assert(@bitSizeOf(MessageFlags) == 8);
}
