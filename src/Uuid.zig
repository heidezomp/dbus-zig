const std = @import("std");

bytes: [16]u8,

const Uuid = @This();

pub fn generate() Uuid {
    var bytes: [16]u8 = undefined;

    // The reference implementation uses 12 bytes of random data and a
    // 4 byte timestamp, but the specification also allows 16 bytes of
    // random data.
    std.crypto.random.bytes(&bytes);

    return Uuid{ .bytes = bytes };
}

pub fn parseHex(reader: anytype) !Uuid {
    var hex: [32]u8 = undefined;
    _ = try reader.readAll(&hex);

    var bytes: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, &hex);

    return Uuid{ .bytes = bytes };
}

test "parseHex" {
    const expected = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const hex = "000102030405060708090a0b0c0d0e0f";

    var fbs = std.io.fixedBufferStream(hex);
    const uuid = try Uuid.parseHex(fbs.reader());

    try std.testing.expectEqualSlices(u8, &expected, &uuid.bytes);
}

pub fn writeHex(uuid: Uuid, writer: anytype) !void {
    try writer.print("{s}", .{std.fmt.fmtSliceHexLower(&uuid.bytes)});
}

test "writeHex" {
    const uuid = Uuid{ .bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f } };
    const expected = "000102030405060708090a0b0c0d0e0f";

    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try uuid.writeHex(fbs.writer());

    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}
