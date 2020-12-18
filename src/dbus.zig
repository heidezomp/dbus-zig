const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Connection = struct {
    socket: std.fs.File,

    pub fn connectSessionBus(gpa: *Allocator) !Connection {
        const address = try std.process.getEnvVarOwned(gpa, "DBUS_SESSION_BUS_ADDRESS");
        defer gpa.free(address);

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
        const uid = std.os.system.getuid();
        var buffer: [100]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        try fbs.writer().print("{}", .{uid});
        try socket.writer().print("\x00AUTH EXTERNAL {x}\r\n", .{fbs.getWritten()});
        const amt = try socket.read(&buffer);
        const response = buffer[0..amt];
        std.log.debug("auth response: {}", .{response});
        if (!std.mem.startsWith(u8, response, "OK ")) // Rest of response is server GUID in hex
            return error.AuthenticationRejected; // TODO Actually check for REJECTED response

        return Connection{ .socket = socket };
    }

    pub fn disconnect(self: Connection) void {
        self.socket.close();
    }
};
