const dbus = @import("dbus.zig");

pub fn main() anyerror!void {
    const bus = try dbus.Connection.connectSessionBus();
    defer bus.disconnect();
}
