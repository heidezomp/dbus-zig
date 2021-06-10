const std = @import("std");
const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
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

pub const Address = union(Transport) {
    unix: UnixAddress,
    /// Environment variable containing the path of the unix domain
    /// socket for the launchd created dbus-daemon
    launchd: []const u8,
    /// No extra information provided
    systemd: void,
    tcp: void, // TODO
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
                else => return error.NotImplemented,
            }
        }

        return null;
    }
};

test "parse unix address 1" {
    const address = "unix:path=/tmp/dbus-test";
    var parser = try Parser.init(address);

    try expectEqualSlices(u8, "/tmp/dbus-test", (try parser.nextAddress()).?.unix.path);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse unix address 2" {
    const address = "unix:invalidkey=value";
    var parser = try Parser.init(address);

    try expectError(error.InvalidKey, parser.nextAddress());
}

test "parse systemd address 1" {
    const address = "systemd:";
    var parser = try Parser.init(address);

    try expectEqual(Address.systemd, (try parser.nextAddress()).?);
}

test "parse systemd address 2" {
    const address = "systemd:invalidkey=value";
    var parser = try Parser.init(address);

    try expectError(error.InvalidSystemdAddress, parser.nextAddress());
}

test "parse launchd address 1" {
    const address = "launchd:env=ENVIRONMENT_VARIABLE";
    var parser = try Parser.init(address);

    try expectEqualSlices(u8, "ENVIRONMENT_VARIABLE", (try parser.nextAddress()).?.launchd);
    try expectEqual(@as(?Address, null), try parser.nextAddress());
}

test "parse launchd address 2" {
    const address = "launchd:";
    var parser = try Parser.init(address);

    try expectError(error.ExpectedKeyValuePair, parser.nextAddress());
}
