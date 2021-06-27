const std = @import("std");
const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

pub const Transport = enum {
    /// Unix domain sockets
    unix,
    /// launchd
    launchd,
    /// systemd socket activation
    systemd,
    /// TCP/IP based connections
    tcp,
    /// Nonce-authenticated TCP Sockets
    nonce_tcp,
    /// Executed Subprocesses on Unix
    unixexec,
    /// Autolaunch a session bus if not present
    autolaunch,

    pub fn prefix(self: Transport) []const u8 {
        return switch (self) {
            .unix => "unix:",
            .launchd => "launchd:",
            .systemd => "systemd:",
            .tcp => "tcp:",
            .nonce_tcp => "nonce-tcp:",
            .unixexec => "unixexec:",
            .autolaunch => "autolaunch:",
        };
    }
};

pub const UnixAddress = union(enum) {
    path: []const u8,
    dir: []const u8,
    tmpdir: []const u8,
    abstract: []const u8,
    runtime: void,
};

pub const SocketFamily = enum {
    ipv4,
    ipv6,
};

pub const TcpAddress = struct {
    host: []const u8,
    bind: []const u8,
    port: u16,
    family: ?SocketFamily,
};

pub const Address = union(Transport) {
    unix: UnixAddress,
    /// Environment variable containing the path of the unix domain
    /// socket for the launchd created dbus-daemon
    launchd: []const u8,
    /// No extra information provided
    systemd: void,
    tcp: TcpAddress,
    nonce_tcp: void, // TODO
    unixexec: void, // TODO
    autolaunch: void, // TODO
};

pub const Parser = struct {
    iterator: std.mem.SplitIterator,

    pub fn init(address: []const u8) !Parser {
        return Parser{
            .iterator = std.mem.split(address, ";"),
        };
    }

    pub fn nextAddress(self: *Parser) !?Address {
        const address = self.iterator.next() orelse return null;

        // Parse transport
        const transport = inline for (std.meta.fields(Transport)) |field| {
            const item = @field(Transport, field.name);
            const prefix = item.prefix();
            if (std.mem.startsWith(u8, address, prefix)) break item;
        } else return error.InvalidTransport;

        // Start parsing after the :
        const parts = address[transport.prefix().len..];
        if (parts.len == 0) {
            switch (transport) {
                .systemd => return Address.systemd,
                else => return error.ExpectedKeyValuePair,
            }
        }

        var tcp_parse_state: struct {
            host: ?[]const u8 = null,
            bind: ?[]const u8 = null,
            port: ?u16 = null,
            family: ?SocketFamily = null,
        } = .{};

        var part_iter = std.mem.split(parts, ",");
        while (part_iter.next()) |part| {
            var kv_iter = std.mem.split(part, "=");
            const key = kv_iter.next() orelse return error.InvalidKeyValuePair;
            const value = kv_iter.next() orelse return error.InvalidKeyValuePair;
            if (kv_iter.next() != null) return error.InvalidKeyValuePair;

            switch (transport) {
                .unix => {
                    if (part_iter.next() != null) return error.InvalidUnixAddress;

                    if (std.mem.eql(u8, "path", key)) {
                        return Address{ .unix = .{ .path = value } };
                    } else if (std.mem.eql(u8, "dir", key)) {
                        return Address{ .unix = .{ .dir = value } };
                    } else if (std.mem.eql(u8, "tmpdir", key)) {
                        return Address{ .unix = .{ .tmpdir = value } };
                    } else if (std.mem.eql(u8, "abstract", key)) {
                        return Address{ .unix = .{ .abstract = value } };
                    } else if (std.mem.eql(u8, "runtime", key)) {
                        if (!std.mem.eql(u8, "yes", value)) return error.InvalidValue;
                        return Address{ .unix = .{ .runtime = {} } };
                    } else {
                        return error.InvalidKey;
                    }
                },
                .launchd => {
                    if (part_iter.next() != null) return error.InvalidUnixAddress;

                    if (std.mem.eql(u8, "env", key)) {
                        return Address{ .launchd = value };
                    } else {
                        return error.InvalidKey;
                    }
                },
                .systemd => return error.InvalidSystemdAddress,
                .tcp => {
                    if (std.mem.eql(u8, "host", key)) {
                        tcp_parse_state.host = value;
                    } else if (std.mem.eql(u8, "bind", key)) {
                        tcp_parse_state.bind = value;
                    } else if (std.mem.eql(u8, "port", key)) {
                        tcp_parse_state.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidTcpPort;
                    } else if (std.mem.eql(u8, "family", key)) {
                        tcp_parse_state.family = std.meta.stringToEnum(SocketFamily, value);
                    } else {
                        return error.InvalidKey;
                    }
                },
                else => return error.NotImplemented,
            }
        }

        switch (transport) {
            .unix, .systemd, .launchd => unreachable, // We return immediately from all switch prongs
            .tcp => return Address{ .tcp = .{
                .host = tcp_parse_state.host orelse return error.MissingTcpHost,
                .bind = tcp_parse_state.bind orelse tcp_parse_state.host.?,
                .port = tcp_parse_state.port orelse 0,
                .family = tcp_parse_state.family,
            } },
            else => unreachable, // We return error.NotImplemented in all other switch prongs
        }
    }
};

test "parse unix address 1" {
    const address = "unix:path=/tmp/dbus-test";
    var parser = try Parser.init(address);

    try expectEqualStrings("/tmp/dbus-test", (try parser.nextAddress()).?.unix.path);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse unix address 2" {
    const address = "unix:invalidkey=value";
    var parser = try Parser.init(address);

    try expectError(error.InvalidKey, parser.nextAddress());
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse systemd address 1" {
    const address = "systemd:";
    var parser = try Parser.init(address);

    try expectEqual(Address.systemd, (try parser.nextAddress()).?);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse systemd address 2" {
    const address = "systemd:invalidkey=value";
    var parser = try Parser.init(address);

    try expectError(error.InvalidSystemdAddress, parser.nextAddress());
}

test "parse launchd address 1" {
    const address = "launchd:env=ENVIRONMENT_VARIABLE";
    var parser = try Parser.init(address);

    try expectEqualStrings("ENVIRONMENT_VARIABLE", (try parser.nextAddress()).?.launchd);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse launchd address 2" {
    const address = "launchd:";
    var parser = try Parser.init(address);

    try expectError(error.ExpectedKeyValuePair, parser.nextAddress());
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse tcp address 1" {
    const address = "tcp:";
    var parser = try Parser.init(address);

    try expectError(error.ExpectedKeyValuePair, parser.nextAddress());
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse tcp address 2" {
    const address = "tcp:host=127.0.0.1";
    var parser = try Parser.init(address);
    const parsed = (try parser.nextAddress()).?.tcp;

    try expectEqualStrings("127.0.0.1", parsed.host);
    try expectEqualStrings("127.0.0.1", parsed.bind);
    try expectEqual(@as(u16, 0), parsed.port);
    try expectEqual(@as(?SocketFamily, null), parsed.family);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse tcp address 3" {
    const address = "tcp:host=127.0.0.1,port=abc";
    var parser = try Parser.init(address);

    try expectError(error.InvalidTcpPort, parser.nextAddress());
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse tcp address 4" {
    const address = "tcp:port=123";
    var parser = try Parser.init(address);

    try expectError(error.MissingTcpHost, parser.nextAddress());
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}
