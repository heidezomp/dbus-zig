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

        return Connection{ .socket = socket };
    }

    pub fn disconnect(self: Connection) void {
        self.socket.close();
    }
};
