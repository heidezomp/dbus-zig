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
        var buffer: [100]u8 = undefined;
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

        // We are now authenticated and ready to send/receive D-Bus messages
        return Connection{ .socket = socket };
    }

    pub fn disconnect(self: Connection) void {
        self.socket.close();
    }
};
