const std = @import("std");
const dbus = @import("dbus.zig");

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() anyerror!void {
    const gpa = &general_purpose_allocator.allocator;
    defer {
        _ = general_purpose_allocator.deinit();
    }

    const bus = try dbus.Connection.connectSessionBus(gpa);
    defer bus.disconnect();
}
