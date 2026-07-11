//! Zyra derives a command-line interface from ordinary Zig types.
const std = @import("std");

pub const ParseError = error{
    MissingRequired,
    UnknownOption,
    UnknownCommand,
    MissingValue,
    InvalidValue,
    DuplicateArgument,
    UnexpectedPositional,
    HelpRequested,
};

pub const Diagnostic = struct {
    kind: ParseError,
    arg_index: usize,
    token: ?[]const u8 = null,
    subject: ?[]const u8 = null,
};

pub const ParseOptions = struct {
    diagnostic: ?*Diagnostic = null,
    /// When enabled, an unmatched `--help` or `-h` makes `parse` return
    /// `error.HelpRequested`. Declared names take precedence, so a field
    /// named `help` or one with an `h` short alias keeps its meaning.
    auto_help: bool = false,
};

pub const HelpOptions = struct {
    program_name: ?[]const u8 = null,
};

/// Parses a complete argv vector. The executable name at argv[0] is ignored.
/// Any string fields in the returned value borrow their storage from `argv`.
pub fn parse(
    comptime T: type,
    argv: []const []const u8,
    options: ParseOptions,
) ParseError!T {
    return parseImpl(T, argv, options);
}

/// Acquires the current process arguments using `init.arena` and parses them.
/// Argument acquisition may allocate on platforms that require transcoding;
/// the Zyra parsing pass itself remains allocation-free.
pub fn parseProcess(
    comptime T: type,
    init: std.process.Init,
    options: ParseOptions,
) !T {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    return parseImpl(T, argv, options);
}

// `parse` receives ordinary slices, while std.process.Args.toSlice returns
// sentinel-terminated slices. Keep the public type precise and share the
// implementation for both representations here.
fn parseImpl(comptime T: type, argv: anytype, options: ParseOptions) ParseError!T {
    comptime validateSchema(T);
    const tokens = if (argv.len == 0) argv else argv[1..];
    const base_index: usize = if (argv.len == 0) 0 else 1;
    return parseType(T, tokens, base_index, options);
}

fn parseType(
    comptime T: type,
    tokens: anytype,
    base_index: usize,
    options: ParseOptions,
) ParseError!T {
    return switch (@typeInfo(T)) {
        .@"struct" => parseStruct(T, tokens, base_index, options),
        .@"union" => parseUnion(T, tokens, base_index, options),
        else => unreachable,
    };
}

fn parseUnion(
    comptime T: type,
    tokens: anytype,
    base_index: usize,
    options: ParseOptions,
) ParseError!T {
    if (tokens.len == 0) {
        return fail(options, error.MissingRequired, base_index, null, "command");
    }

    const command = tokens[0];
    inline for (std.meta.fields(T)) |field| {
        if (commandNameMatches(T, field.name, command)) {
            const payload = try parseType(field.type, tokens[1..], base_index + 1, options);
            return @unionInit(T, field.name, payload);
        }
    }
    if (options.auto_help and (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")))
        return fail(options, error.HelpRequested, base_index, command, null);
    return fail(options, error.UnknownCommand, base_index, command, "command");
}

fn parseStruct(
    comptime T: type,
    tokens: anytype,
    base_index: usize,
    options: ParseOptions,
) ParseError!T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    var seen: [fields.len]bool = @splat(false);

    inline for (fields) |field| {
        if (comptime field.defaultValue()) |default| {
            @field(result, field.name) = default;
        }
    }

    var options_enabled = true;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];

        if (options_enabled and std.mem.eql(u8, token, "--")) {
            options_enabled = false;
            continue;
        }

        if (options_enabled and std.mem.startsWith(u8, token, "--") and token.len > 2) {
            const body = token[2..];
            const equal_index = std.mem.indexOfScalar(u8, body, '=');
            const option_name = if (equal_index) |index| body[0..index] else body;
            const attached_value: ?[]const u8 = if (equal_index) |index| body[index + 1 ..] else null;
            var matched = false;

            long_match: {
                inline for (fields, 0..) |field, field_index| {
                    if (fieldIsNamed(T, field.name) and fieldLongMatches(T, field.name, option_name)) {
                        matched = true;
                        if (seen[field_index]) {
                            return fail(options, error.DuplicateArgument, base_index + i, token, field.name);
                        }

                        if (isBoolLike(field.type)) {
                            if (attached_value != null) {
                                return fail(options, error.InvalidValue, base_index + i, token, field.name);
                            }
                            @field(result, field.name) = flagValue(field.type);
                        } else {
                            const raw = attached_value orelse value: {
                                if (i + 1 >= tokens.len) {
                                    return fail(options, error.MissingValue, base_index + i, token, field.name);
                                }
                                i += 1;
                                break :value tokens[i];
                            };
                            @field(result, field.name) = parseValue(field.type, raw) catch {
                                return fail(options, error.InvalidValue, base_index + i, raw, field.name);
                            };
                        }
                        seen[field_index] = true;
                        break :long_match;
                    }
                }
            }
            if (!matched) {
                if (options.auto_help and std.mem.eql(u8, option_name, "help"))
                    return fail(options, error.HelpRequested, base_index + i, token, null);
                return fail(options, error.UnknownOption, base_index + i, token, option_name);
            }
            continue;
        }

        if (options_enabled and token.len > 1 and token[0] == '-' and !looksLikeNegativeNumber(token)) {
            if (token.len != 2) {
                return fail(options, error.UnknownOption, base_index + i, token, token[1..]);
            }
            const option_name = token[1];
            var matched = false;

            short_match: {
                inline for (fields, 0..) |field, field_index| {
                    if (fieldIsNamed(T, field.name) and fieldShort(T, field.name) == option_name) {
                        matched = true;
                        if (seen[field_index]) {
                            return fail(options, error.DuplicateArgument, base_index + i, token, field.name);
                        }

                        if (isBoolLike(field.type)) {
                            @field(result, field.name) = flagValue(field.type);
                        } else {
                            if (i + 1 >= tokens.len) {
                                return fail(options, error.MissingValue, base_index + i, token, field.name);
                            }
                            i += 1;
                            const raw = tokens[i];
                            @field(result, field.name) = parseValue(field.type, raw) catch {
                                return fail(options, error.InvalidValue, base_index + i, raw, field.name);
                            };
                        }
                        seen[field_index] = true;
                        break :short_match;
                    }
                }
            }
            if (!matched) {
                if (options.auto_help and option_name == 'h')
                    return fail(options, error.HelpRequested, base_index + i, token, null);
                return fail(options, error.UnknownOption, base_index + i, token, token[1..]);
            }
            continue;
        }

        var assigned = false;
        positional_match: {
            inline for (fields, 0..) |field, field_index| {
                if (fieldIsPositional(T, field.name) and !seen[field_index]) {
                    @field(result, field.name) = parseValue(field.type, token) catch {
                        return fail(options, error.InvalidValue, base_index + i, token, field.name);
                    };
                    seen[field_index] = true;
                    assigned = true;
                    break :positional_match;
                }
            }
        }
        if (!assigned) {
            return fail(options, error.UnexpectedPositional, base_index + i, token, null);
        }
    }

    inline for (fields, 0..) |field, field_index| {
        if (field.defaultValue() == null and !seen[field_index]) {
            return fail(options, error.MissingRequired, base_index + tokens.len, null, field.name);
        }
    }
    return result;
}

fn parseValue(comptime T: type, raw: []const u8) error{InvalidValue}!T {
    return switch (@typeInfo(T)) {
        .optional => |optional| try parseValue(optional.child, raw),
        .bool => if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else error.InvalidValue,
        .int => std.fmt.parseInt(T, raw, 0) catch error.InvalidValue,
        .float => std.fmt.parseFloat(T, raw) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidValue,
        .pointer => |pointer| if (pointer.size == .slice and pointer.child == u8 and pointer.is_const)
            raw
        else
            error.InvalidValue,
        .@"struct", .@"union", .@"opaque" => if (@hasDecl(T, "parseZyra"))
            T.parseZyra(raw) catch error.InvalidValue
        else
            error.InvalidValue,
        else => error.InvalidValue,
    };
}

fn flagValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .bool => true,
        .optional => |optional| blk: {
            if (optional.child != bool) unreachable;
            break :blk true;
        },
        else => unreachable,
    };
}

fn isBoolLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool => true,
        .optional => |optional| optional.child == bool,
        else => false,
    };
}

// Zyra treats a leading '-' followed by a digit or '.' as a positional
// candidate. The destination field parser remains responsible for validating
// the complete token, so `-1foo` is valid for a string but not for an integer.
fn looksLikeNegativeNumber(token: []const u8) bool {
    return token.len > 1 and token[0] == '-' and
        (std.ascii.isDigit(token[1]) or token[1] == '.');
}

fn fail(
    options: ParseOptions,
    err: ParseError,
    arg_index: usize,
    token: ?[]const u8,
    subject: ?[]const u8,
) ParseError {
    if (options.diagnostic) |diagnostic| {
        diagnostic.* = .{
            .kind = err,
            .arg_index = arg_index,
            .token = token,
            .subject = subject,
        };
    }
    return err;
}

/// Writes a human-readable explanation of a structured parse failure.
pub fn writeDiagnostic(diagnostic: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (diagnostic.kind) {
        error.MissingRequired => try writer.print("missing required argument '{?s}'", .{diagnostic.subject}),
        error.UnknownOption => try writer.print("unknown option '{?s}'", .{diagnostic.token}),
        error.UnknownCommand => try writer.print("unknown command '{?s}'", .{diagnostic.token}),
        error.MissingValue => try writer.print("option '{?s}' requires a value", .{diagnostic.token}),
        error.InvalidValue => try writer.print("invalid value '{?s}' for '{?s}'", .{ diagnostic.token, diagnostic.subject }),
        error.DuplicateArgument => try writer.print("argument '{?s}' was provided more than once", .{diagnostic.subject}),
        error.UnexpectedPositional => try writer.print("unexpected positional argument '{?s}'", .{diagnostic.token}),
        error.HelpRequested => try writer.writeAll("help requested"),
    }
}

/// Generates deterministic usage and help text from `T` and its optional
/// `pub const zyra` declaration.
pub fn writeHelp(
    comptime T: type,
    writer: *std.Io.Writer,
    options: HelpOptions,
) std.Io.Writer.Error!void {
    comptime validateSchema(T);
    try writer.print("Usage: {s}", .{programName(T, options)});
    try writeHelpBody(T, writer);
}

/// Generates help for the deepest subcommand named by `argv`, so
/// `program ship --help` documents `ship`. Falls back to the root help when
/// `argv` names no subcommand. The executable name at argv[0] is ignored.
pub fn writeHelpForArgs(
    comptime T: type,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    options: HelpOptions,
) std.Io.Writer.Error!void {
    return writeHelpForArgsImpl(T, argv, writer, options);
}

/// Acquires the current process arguments using `init.arena` and generates
/// help for the subcommand they name, as `writeHelpForArgs` does.
pub fn writeHelpForProcess(
    comptime T: type,
    init: std.process.Init,
    writer: *std.Io.Writer,
    options: HelpOptions,
) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    return writeHelpForArgsImpl(T, argv, writer, options);
}

fn writeHelpForArgsImpl(
    comptime T: type,
    argv: anytype,
    writer: *std.Io.Writer,
    options: HelpOptions,
) std.Io.Writer.Error!void {
    comptime validateSchema(T);
    try writer.print("Usage: {s}", .{programName(T, options)});
    const tokens = if (argv.len == 0) argv else argv[1..];
    try writeHelpWalk(T, tokens, writer);
}

fn writeHelpWalk(comptime T: type, tokens: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (@typeInfo(T) == .@"union" and tokens.len > 0) {
        inline for (std.meta.fields(T)) |field| {
            if (commandNameMatches(T, field.name, tokens[0])) {
                try writer.writeByte(' ');
                try writeCliName(writer, commandDisplayName(T, field.name));
                return writeHelpWalk(field.type, tokens[1..], writer);
            }
        }
    }
    try writeHelpBody(T, writer);
}

fn writeHelpBody(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            try writer.writeAll(" [options] [arguments]\n");
            if (schemaAbout(T)) |about| try writer.print("\n{s}\n", .{about});
            try writeStructHelp(T, writer);
        },
        .@"union" => {
            try writer.writeAll(" <command> [options] [arguments]\n");
            if (schemaAbout(T)) |about| try writer.print("\n{s}\n", .{about});
            try writer.writeAll("\nCommands:\n");
            inline for (std.meta.fields(T)) |field| {
                try writer.writeAll("  ");
                try writeCliName(writer, commandDisplayName(T, field.name));
                if (commandHelp(T, field.name)) |help| try writer.print("\t{s}", .{help});
                try writer.writeByte('\n');
            }
        },
        else => unreachable,
    }
}

fn programName(comptime T: type, options: HelpOptions) []const u8 {
    return options.program_name orelse schemaName(T) orelse "program";
}

fn writeStructHelp(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const fields = std.meta.fields(T);
    const has_positionals = comptime blk: {
        var value = false;
        for (fields) |field| value = value or fieldIsPositional(T, field.name);
        break :blk value;
    };
    if (has_positionals) {
        try writer.writeAll("\nArguments:\n");
        inline for (fields) |field| {
            if (fieldIsPositional(T, field.name)) {
                try writer.print("  <{s}>\t{s}", .{ fieldValueName(T, field.name), @typeName(field.type) });
                if (fieldHelp(T, field.name)) |help| try writer.print(" - {s}", .{help});
                try writeDefault(field, writer);
                try writer.writeByte('\n');
            }
        }
    }

    const has_options = comptime blk: {
        var value = false;
        for (fields) |field| value = value or fieldIsNamed(T, field.name);
        break :blk value;
    };
    if (has_options) {
        try writer.writeAll("\nOptions:\n");
        inline for (fields) |field| {
            if (fieldIsNamed(T, field.name)) {
                try writer.writeAll("  ");
                if (fieldShort(T, field.name)) |short| try writer.print("-{c}", .{short});
                if (fieldLong(T, field.name)) |long| {
                    if (fieldShort(T, field.name) != null) try writer.writeAll(", ");
                    try writer.writeAll("--");
                    try writeCliName(writer, long);
                }
                if (!isBoolLike(field.type)) try writer.print(" <{s}>", .{fieldValueName(T, field.name)});
                if (fieldHelp(T, field.name)) |help| try writer.print("\t{s}", .{help});
                try writeDefault(field, writer);
                try writer.writeByte('\n');
            }
        }
    }
}

fn writeDefault(comptime field: std.builtin.Type.StructField, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime field.defaultValue()) |default| {
        try writer.writeAll(" (default: ");
        try writeDefaultValue(default, writer);
        try writer.writeByte(')');
    }
}

// Renders a default in the syntax the user would type on the command line:
// strings verbatim and enums without their leading dot.
fn writeDefaultValue(value: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |child| try writeDefaultValue(child, writer) else try writer.writeAll("null"),
        .pointer => try writer.print("{s}", .{value}),
        .@"enum" => try writer.writeAll(@tagName(value)),
        else => try writer.print("{any}", .{value}),
    }
}

fn writeCliName(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |character| try writer.writeByte(if (character == '_') '-' else character);
}

fn fieldShort(comptime T: type, comptime field_name: []const u8) ?u8 {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "short")) return metadata.short;
        }
    }
    return if (field_name.len == 1) field_name[0] else null;
}

fn fieldLong(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "long")) return metadata.long;
        }
    }
    return if (field_name.len > 1) field_name else null;
}

fn fieldIsNamed(comptime T: type, comptime field_name: []const u8) bool {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "named")) return metadata.named;
        }
    }
    return true;
}

fn fieldIsPositional(comptime T: type, comptime field_name: []const u8) bool {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "positional")) return metadata.positional;
        }
    }
    return !isBoolLike(@FieldType(T, field_name));
}

fn fieldHelp(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "help")) return metadata.help;
        }
    }
    return null;
}

fn fieldValueName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (@hasDecl(T, "zyra")) {
        const config = T.zyra;
        if (@hasField(@TypeOf(config), "fields") and @hasField(@TypeOf(config.fields), field_name)) {
            const metadata = @field(config.fields, field_name);
            if (@hasField(@TypeOf(metadata), "value_name")) return metadata.value_name;
        }
    }
    return field_name;
}

fn fieldLongMatches(comptime T: type, comptime field_name: []const u8, input: []const u8) bool {
    const name = fieldLong(T, field_name) orelse return false;
    return cliNameEql(name, input);
}

fn cliNameEql(name: []const u8, input: []const u8) bool {
    if (name.len != input.len) return false;
    for (name, input) |expected, actual| {
        if ((if (expected == '_') '-' else expected) != actual) return false;
    }
    return true;
}

fn schemaName(comptime T: type) ?[]const u8 {
    if (@hasDecl(T, "zyra") and @hasField(@TypeOf(T.zyra), "name")) return T.zyra.name;
    return null;
}

fn schemaAbout(comptime T: type) ?[]const u8 {
    if (@hasDecl(T, "zyra") and @hasField(@TypeOf(T.zyra), "about")) return T.zyra.about;
    return null;
}

fn commandDisplayName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (@hasDecl(T, "zyra") and @hasField(@TypeOf(T.zyra), "commands") and
        @hasField(@TypeOf(T.zyra.commands), field_name))
    {
        const metadata = @field(T.zyra.commands, field_name);
        if (@hasField(@TypeOf(metadata), "name")) return metadata.name;
    }
    return field_name;
}

fn commandHelp(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (@hasDecl(T, "zyra") and @hasField(@TypeOf(T.zyra), "commands") and
        @hasField(@TypeOf(T.zyra.commands), field_name))
    {
        const metadata = @field(T.zyra.commands, field_name);
        if (@hasField(@TypeOf(metadata), "help")) return metadata.help;
    }
    return null;
}

fn commandNameMatches(comptime T: type, comptime field_name: []const u8, input: []const u8) bool {
    return cliNameEql(commandDisplayName(T, field_name), input);
}

fn validateSchema(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                validateValueType(field.type);
                if (field.defaultValue() == null and !fieldIsNamed(T, field.name) and !fieldIsPositional(T, field.name))
                    @compileError("Zyra field '" ++ field.name ++ "' is required but neither named nor positional");
            }
            validateFieldMetadata(T);
            validateAliases(T);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) @compileError("Zyra subcommands require a tagged union: " ++ @typeName(T));
            inline for (union_info.fields) |field| {
                switch (@typeInfo(field.type)) {
                    .@"struct", .@"union" => validateSchema(field.type),
                    else => @compileError("Zyra command payload must be a struct or tagged union: " ++ field.name),
                }
            }
            validateCommandMetadata(T);
            validateCommandAliases(T);
        },
        else => @compileError("Zyra root type must be a struct or tagged union, found " ++ @typeName(T)),
    }
}

fn validateValueType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => {},
        .optional => |optional| validateValueType(optional.child),
        .pointer => |pointer| {
            if (!(pointer.size == .slice and pointer.child == u8 and pointer.is_const))
                @compileError("unsupported Zyra field type: " ++ @typeName(T));
        },
        .@"struct", .@"union", .@"opaque" => {
            if (!@hasDecl(T, "parseZyra")) @compileError("unsupported Zyra field type: " ++ @typeName(T));
        },
        else => @compileError("unsupported Zyra field type: " ++ @typeName(T)),
    }
}

fn validateFieldMetadata(comptime T: type) void {
    if (!@hasDecl(T, "zyra")) return;
    const config = T.zyra;
    if (!@hasField(@TypeOf(config), "fields")) return;
    inline for (std.meta.fields(@TypeOf(config.fields))) |metadata_field| {
        if (!@hasField(T, metadata_field.name)) {
            @compileError("Zyra metadata references unknown field '" ++ metadata_field.name ++ "'");
        }
    }
}

fn validateCommandMetadata(comptime T: type) void {
    if (!@hasDecl(T, "zyra")) return;
    const config = T.zyra;
    if (!@hasField(@TypeOf(config), "commands")) return;
    inline for (std.meta.fields(@TypeOf(config.commands))) |metadata_field| {
        if (!@hasField(T, metadata_field.name)) {
            @compileError("Zyra metadata references unknown command '" ++ metadata_field.name ++ "'");
        }
    }
}

fn validateAliases(comptime T: type) void {
    const fields = std.meta.fields(T);
    inline for (fields, 0..) |left, left_index| {
        if (!fieldIsNamed(T, left.name)) continue;
        inline for (fields[left_index + 1 ..]) |right| {
            if (!fieldIsNamed(T, right.name)) continue;
            if (fieldShort(T, left.name) != null and fieldShort(T, left.name) == fieldShort(T, right.name))
                @compileError("duplicate Zyra short option in " ++ @typeName(T));
            const left_long = fieldLong(T, left.name);
            const right_long = fieldLong(T, right.name);
            if (left_long != null and right_long != null and cliNameEql(left_long.?, right_long.?))
                @compileError("duplicate Zyra long option in " ++ @typeName(T));
        }
    }
}

fn validateCommandAliases(comptime T: type) void {
    const fields = std.meta.fields(T);
    inline for (fields, 0..) |left, left_index| {
        inline for (fields[left_index + 1 ..]) |right| {
            if (cliNameEql(commandDisplayName(T, left.name), commandDisplayName(T, right.name)))
                @compileError("duplicate Zyra command name in " ++ @typeName(T));
        }
    }
}

// Tests double as examples of the inferred public API.
const PairArgs = struct { a: i32, b: i32 };

test "fields accept positional and named input" {
    const positional = try parse(PairArgs, &.{ "program", "1", "2" }, .{});
    try std.testing.expectEqual(@as(i32, 1), positional.a);
    try std.testing.expectEqual(@as(i32, 2), positional.b);

    const named = try parse(PairArgs, &.{ "program", "-b", "2", "-a", "1" }, .{});
    try std.testing.expectEqual(@as(i32, 1), named.a);
    try std.testing.expectEqual(@as(i32, 2), named.b);
}

const LongArgs = struct { number: i32, b: i32, target: i32 };

test "short and long options mix in any order" {
    const args = try parse(LongArgs, &.{ "program", "--number", "2", "--target=1", "-b", "3" }, .{});
    try std.testing.expectEqual(@as(i32, 2), args.number);
    try std.testing.expectEqual(@as(i32, 3), args.b);
    try std.testing.expectEqual(@as(i32, 1), args.target);
}

const FlagArgs = struct { target: i32, verbose: bool };

test "boolean flags do not consume a value" {
    const args = try parse(FlagArgs, &.{ "program", "--verbose", "--target", "1" }, .{});
    try std.testing.expectEqual(@as(i32, 1), args.target);
    try std.testing.expect(args.verbose);
}

const RunArgs = struct { target: i32, verbose: bool = false };
const CompileArgs = struct { target: i32 = 1, optimize: bool };
const Commands = union(enum) {
    run: RunArgs,
    compile: CompileArgs,
};

test "tagged unions derive subcommands and retain defaults" {
    const run = try parse(Commands, &.{ "program", "run", "--target", "4" }, .{});
    switch (run) {
        .run => |args| {
            try std.testing.expectEqual(@as(i32, 4), args.target);
            try std.testing.expect(!args.verbose);
        },
        else => return error.WrongCommand,
    }

    const compile_args = try parse(Commands, &.{ "program", "compile", "--optimize" }, .{});
    switch (compile_args) {
        .compile => |args| {
            try std.testing.expectEqual(@as(i32, 1), args.target);
            try std.testing.expect(args.optimize);
        },
        else => return error.WrongCommand,
    }
}

const RichArgs = struct {
    count: u16,
    ratio: f32 = 1.0,
    mode: enum { fast, safe } = .safe,
    output_path: ?[]const u8 = null,
    verbose: bool = false,

    pub const zyra = .{
        .name = "rich",
        .about = "Metadata example.",
        .fields = .{
            .count = .{ .short = 'c', .help = "Number of jobs", .value_name = "N", .positional = false },
            .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        },
    };
};

test "metadata aliases, scalar types, nullable values, and kebab names" {
    const args = try parse(RichArgs, &.{ "rich", "-c", "12", "--ratio", "0.5", "--mode", "fast", "--output-path", "out.txt", "-v" }, .{});
    try std.testing.expectEqual(@as(u16, 12), args.count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), args.ratio, 0.0001);
    try std.testing.expectEqual(.fast, args.mode);
    try std.testing.expectEqualStrings("out.txt", args.output_path.?);
    try std.testing.expect(args.verbose);
}

const CustomValue = struct {
    value: u8,

    pub fn parseZyra(raw: []const u8) !CustomValue {
        if (!std.mem.startsWith(u8, raw, "v")) return error.BadPrefix;
        return .{ .value = try std.fmt.parseInt(u8, raw[1..], 10) };
    }
};

test "custom value parser hook" {
    const Args = struct { custom: CustomValue };
    const args = try parse(Args, &.{ "program", "v42" }, .{});
    try std.testing.expectEqual(@as(u8, 42), args.custom.value);
}

test "named assignment skips that field for later positionals" {
    const args = try parse(PairArgs, &.{ "program", "-a", "4", "5" }, .{});
    try std.testing.expectEqual(@as(i32, 4), args.a);
    try std.testing.expectEqual(@as(i32, 5), args.b);
}

test "negative numbers and option terminator" {
    const Numeric = struct { value: i32 };
    const String = struct { value: []const u8 };
    try std.testing.expectEqual(@as(i32, -7), (try parse(Numeric, &.{ "p", "-7" }, .{})).value);
    try std.testing.expectEqualStrings("--literal", (try parse(String, &.{ "p", "--", "--literal" }, .{})).value);
}

test "structured diagnostics describe failures" {
    var diagnostic: Diagnostic = undefined;
    try std.testing.expectError(error.InvalidValue, parse(PairArgs, &.{ "program", "nope", "2" }, .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqual(error.InvalidValue, diagnostic.kind);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.arg_index);
    try std.testing.expectEqualStrings("nope", diagnostic.token.?);
    try std.testing.expectEqualStrings("a", diagnostic.subject.?);

    try std.testing.expectError(error.DuplicateArgument, parse(PairArgs, &.{ "program", "-a", "1", "-a", "2", "3" }, .{}));
    try std.testing.expectError(error.MissingRequired, parse(PairArgs, &.{ "program", "1" }, .{}));
    try std.testing.expectError(error.MissingValue, parse(PairArgs, &.{ "program", "-a" }, .{}));
    try std.testing.expectError(error.UnknownOption, parse(PairArgs, &.{ "program", "--wat", "1", "2" }, .{}));
    try std.testing.expectError(error.UnexpectedPositional, parse(PairArgs, &.{ "program", "1", "2", "3" }, .{}));
    try std.testing.expectError(error.UnknownCommand, parse(Commands, &.{ "program", "unknown" }, .{}));
    try std.testing.expectError(error.MissingRequired, parse(Commands, &.{"program"}, .{}));
    try std.testing.expectError(error.InvalidValue, parse(RichArgs, &.{ "program", "--verbose=false", "-c", "1" }, .{}));
}

test "help is generated from schema and metadata" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(RichArgs, &output.writer, .{});
    const help = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage: rich") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Metadata example.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "-c, --count <N>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--output-path") != null);
}

test "auto_help intercepts unmatched --help and -h at any level" {
    const with_help: ParseOptions = .{ .auto_help = true };
    try std.testing.expectError(error.HelpRequested, parse(PairArgs, &.{ "program", "--help" }, with_help));
    try std.testing.expectError(error.HelpRequested, parse(PairArgs, &.{ "program", "1", "-h" }, with_help));
    try std.testing.expectError(error.HelpRequested, parse(Commands, &.{ "program", "--help" }, with_help));
    try std.testing.expectError(error.HelpRequested, parse(Commands, &.{ "program", "run", "--help" }, with_help));
}

test "auto_help is off by default" {
    try std.testing.expectError(error.UnknownOption, parse(PairArgs, &.{ "program", "--help" }, .{}));
    try std.testing.expectError(error.UnknownOption, parse(PairArgs, &.{ "program", "1", "-h" }, .{}));
    try std.testing.expectError(error.UnknownCommand, parse(Commands, &.{ "program", "--help" }, .{}));
}

test "declared fields take precedence over auto_help" {
    const Claimed = struct {
        help: bool = false,
        hint: i32 = 0,

        pub const zyra = .{ .fields = .{ .hint = .{ .short = 'h', .positional = false } } };
    };
    const args = try parse(Claimed, &.{ "program", "--help", "-h", "3" }, .{ .auto_help = true });
    try std.testing.expect(args.help);
    try std.testing.expectEqual(@as(i32, 3), args.hint);
}

test "writeHelpForArgs documents the named subcommand" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelpForArgs(Commands, &.{ "program", "run", "--help" }, &output.writer, .{});
    const help = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage: program run [options] [arguments]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--target") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);

    output.clearRetainingCapacity();
    try writeHelpForArgs(Commands, &.{ "program", "--help" }, &output.writer, .{});
    const root_help = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, root_help, "Usage: program <command>") != null);
}

const DefaultArgs = struct {
    output: []const u8 = "out.txt",
    label: ?[]const u8 = null,
    mode: enum { fast, safe } = .safe,
};

test "defaults render in command-line syntax" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(DefaultArgs, &output.writer, .{});
    const help = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help, "(default: out.txt)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "(default: null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "(default: safe)") != null);
}

const NamedCommands = union(enum) {
    execute: struct { value: i32 },

    pub const zyra = .{
        .name = "tool",
        .about = "Command metadata example.",
        .commands = .{
            .execute = .{ .name = "run", .help = "Run the operation" },
        },
    };
};

test "command names and help can be customized" {
    const command = try parse(NamedCommands, &.{ "tool", "run", "9" }, .{});
    switch (command) {
        .execute => |args| try std.testing.expectEqual(@as(i32, 9), args.value),
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(NamedCommands, &output.writer, .{});
    const help = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage: tool <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "run\tRun the operation") != null);
}
