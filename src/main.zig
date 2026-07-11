const std = @import("std");
const zyra = @import("zyra");

const version = "Naval Fate 1.0.0";

const NavalFate = union(enum) {
    ship: ShipCommand,
    mine: MineCommand,
    help: Empty,
    version: Empty,

    pub const zyra = .{
        .name = "naval_fate",
        .about = "Naval Fate: ships, mines, and questionable tactical decisions.",
        .commands = .{
            .ship = .{ .help = "Create, move, or fire a ship" },
            .mine = .{ .help = "Set or remove a mine" },
            .help = .{ .help = "Show this help" },
            .version = .{ .help = "Show version information" },
        },
    };
};

const ShipCommand = union(enum) {
    new: NewShipArgs,
    move: MoveShipArgs,
    shoot: Coordinates,
};

const MineCommand = union(enum) {
    set: MineArgs,
    remove: MineArgs,
};

const Empty = struct {};

const NewShipArgs = struct {
    name: []const u8,
};

const MoveShipArgs = struct {
    name: []const u8,
    x: i32,
    y: i32,
    speed: u16 = 10,
};

const Coordinates = struct {
    x: i32,
    y: i32,
};

const MineKind = enum { moored, drifting };

const MineArgs = struct {
    x: i32,
    y: i32,
    kind: ?MineKind = null,
};

pub fn main(init: std.process.Init) !u8 {
    var diagnostic: zyra.Diagnostic = undefined;
    const command = zyra.parseProcess(NavalFate, init, .{ .diagnostic = &diagnostic }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
            const stderr = &stderr_file_writer.interface;
            try zyra.writeDiagnostic(diagnostic, stderr);
            try stderr.writeAll("\nTry 'naval_fate help' for usage.\n");
            try stderr.flush();
            return 2;
        },
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try execute(command, stdout);
    try stdout.flush();
    return 0;
}

fn execute(command: NavalFate, stdout: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (command) {
        .help => try zyra.writeHelp(NavalFate, stdout, .{}),
        .version => try stdout.print("{s}\n", .{version}),
        .ship => |ship| switch (ship) {
            .new => |args| try stdout.print("Creating ship {s}.\n", .{args.name}),
            .move => |args| try stdout.print(
                "Moving ship {s} to ({d}, {d}) at {d} knots.\n",
                .{ args.name, args.x, args.y, args.speed },
            ),
            .shoot => |args| try stdout.print("Ship firing at ({d}, {d}).\n", .{ args.x, args.y }),
        },
        .mine => |mine| switch (mine) {
            .set => |args| try printMine(stdout, "Setting", args),
            .remove => |args| try printMine(stdout, "Removing", args),
        },
    }
}

fn printMine(stdout: *std.Io.Writer, action: []const u8, args: MineArgs) std.Io.Writer.Error!void {
    try stdout.print("{s} ", .{action});
    if (args.kind) |kind| try stdout.print("{s} ", .{@tagName(kind)});
    try stdout.print("mine at ({d}, {d}).\n", .{ args.x, args.y });
}

test "nested tagged unions parse ship commands" {
    const new = try zyra.parse(NavalFate, &.{ "naval_fate", "ship", "new", "Enterprise" }, .{});
    try std.testing.expectEqualStrings("Enterprise", new.ship.new.name);

    const move = try zyra.parse(NavalFate, &.{ "naval_fate", "ship", "move", "Defiant", "10", "-4", "--speed", "30" }, .{});
    try std.testing.expectEqual(@as(i32, 10), move.ship.move.x);
    try std.testing.expectEqual(@as(i32, -4), move.ship.move.y);
    try std.testing.expectEqual(@as(u16, 30), move.ship.move.speed);

    const shoot = try zyra.parse(NavalFate, &.{ "naval_fate", "ship", "shoot", "3", "5" }, .{});
    try std.testing.expectEqual(@as(i32, 3), shoot.ship.shoot.x);
}

test "defaults and nullable enums parse naturally" {
    const move = try zyra.parse(NavalFate, &.{ "naval_fate", "ship", "move", "Serenity", "1", "2" }, .{});
    try std.testing.expectEqual(@as(u16, 10), move.ship.move.speed);

    const mine = try zyra.parse(NavalFate, &.{ "naval_fate", "mine", "set", "7", "8", "--kind", "drifting" }, .{});
    try std.testing.expectEqual(.drifting, mine.mine.set.kind.?);
}

test "help and version are ordinary commands" {
    try std.testing.expectEqual(.help, std.meta.activeTag(try zyra.parse(NavalFate, &.{ "naval_fate", "help" }, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(try zyra.parse(NavalFate, &.{ "naval_fate", "version" }, .{})));
}
