# Zyra

Zyra is an allocation-free, reflection-driven command-line parser for Zig 0.16.
An ordinary struct defines options and positional arguments; a tagged union
defines subcommands.

```zig
const std = @import("std");
const zyra = @import("zyra");

const Args = struct {
    target: i32,
    output: ?[]const u8 = null,
    verbose: bool = false,

    pub const zyra = .{
        .about = "Example program",
        .fields = .{
            .target = .{ .short = 't', .help = "Target number" },
            .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const args = try zyra.parseProcess(Args, init, .{});
    std.debug.print("target={d} verbose={}\n", .{ args.target, args.verbose });
}
```

The same `target` field accepts either a positional value (`program 42`) or a
named value (`program --target 42` or `program -t 42`). A field without a Zig
default is required. A defaulted field may be omitted, and `?T = null` represents
an optional value with no fallback value.

## Inference

- A one-character field such as `b` gets `-b`.
- A longer field such as `output_path` gets `--output-path`.
- Non-boolean fields accept named or positional input by default.
- Boolean fields are flags and become `true` when present.
- `[]const u8` values borrow from the argument vector; parsing itself allocates
  no memory.
- Integers, floats, booleans, enums, nullable values, and `[]const u8` are built
  in.

Metadata is optional. Under `pub const zyra`, `.fields` can add `short`, `long`,
`help`, and `value_name`, or override the inferred `named` and `positional`
booleans. Type-level `name` and `about` customize generated help.

## Subcommands

Use a tagged union whose payloads are argument structs:

```zig
const Commands = union(enum) {
    run: struct { target: i32, verbose: bool = false },
    compile: struct { target: i32 = 1, optimize: bool },
};

const command = try zyra.parse(Commands, argv, .{});
```

Command metadata may be added under `.commands`, using `name` and `help` for
each union field.

## Diagnostics and help

`parse` returns a compact `ParseError`. Pass a `*Diagnostic` in its options to
retain the argument index, token, and related field, then use `writeDiagnostic`
to render it. `writeHelp` writes generated help to any `*std.Io.Writer` and
never prints or exits on its own.

`parse` accepts an existing `[]const []const u8` and does no allocation.
`parseProcess` is a convenience for Zig 0.16's `std.process.Init`; acquiring
cross-platform process arguments may allocate from `init.arena`, but the
parsing pass still does not allocate.

A custom scalar-like type can implement:

```zig
pub fn parseZyra(raw: []const u8) !@This() { ... }
```

## Build

```sh
zig build test
zig build run -- help
zig build run -- ship new Enterprise
zig build run -- ship move Enterprise 10 20 --speed 25
zig build run -- mine set 4 5 --kind moored
```

## Acknowledgment

This library is inspired by the [Clara](https://github.com/catchorg/Clara) and [Lyra](https://github.com/bfgroup/Lyra) cli.
I really like their API and wanted something similar in Zig and also use the Zig ability to perform comptime.

## Disclaimer

Yes, Yes, it's completly vibe coded. I just design the API and let the LLM implement it. I still read the generated code but not really carefuly.
