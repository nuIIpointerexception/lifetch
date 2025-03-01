const std = @import("std");

pub fn printStruct(s: anytype, shorten_types: bool, indent: comptime_int) void {
    const s_type_info = @typeInfo(@TypeOf(s));
    if (s_type_info != .@"struct")
        @compileError("fn printStruct: `s` is " ++ @typeName(s) ++ " , expected a struct");

    const ind_str = "    " ** indent;
    const ind_str_2 = "    " ** (indent + 1);
    std.debug.print("{s}{{\n", .{ind_str});

    inline for (s_type_info.@"struct".fields) |fld| {
        const field_value = @field(s, fld.name);
        const type_name = typeName(@typeName(fld.type), shorten_types);
        const comptime_prefix = if (fld.is_comptime) "comptime " else "";

        switch (@typeInfo(fld.type)) {
            .int, .float, .comptime_int, .comptime_float => std.debug.print("{s}{s}{s}: {s} = {d}\n", .{ ind_str_2, comptime_prefix, fld.name, type_name, field_value }),

            .bool => std.debug.print("{s}{s}{s}: {s} = {}\n", .{ ind_str_2, comptime_prefix, fld.name, type_name, field_value }),

            .@"struct" => {
                std.debug.print("{s}{s}{s}: {s} =\n", .{ ind_str_2, comptime_prefix, fld.name, type_name });
                printStruct(field_value, shorten_types, indent + 1);
            },

            .array => {
                std.debug.print("{s}{s}{s}: {s} = [ ", .{ ind_str_2, comptime_prefix, fld.name, type_name });
                printArray(field_value, shorten_types);
                std.debug.print("]\n", .{});
            },

            .pointer => |ptr_type_info| switch (ptr_type_info.size) {
                .one, .many, .c => std.debug.print("{s}{s}{s}: {s} = {*}\n", .{ ind_str_2, comptime_prefix, fld.name, type_name, field_value }),

                .slice => if (ptr_type_info.child == u8)
                    std.debug.print("{s}{s}{s}: {s} = \"{s}\"\n", .{ ind_str_2, comptime_prefix, fld.name, type_name, field_value })
                else {
                    std.debug.print("{s}{s}{s}: {s} = [ ", .{ ind_str_2, comptime_prefix, fld.name, type_name });
                    printArray(field_value, shorten_types);
                    std.debug.print("]\n", .{});
                },
            },

            .@"enum" => std.debug.print("{s}{s}{s}: {s} = {s}\n", .{ ind_str_2, comptime_prefix, fld.name, type_name, @tagName(field_value) }),

            .optional => if (field_value) |value| {
                std.debug.print("{s}{s}{s}: {s} =\n", .{ ind_str_2, comptime_prefix, fld.name, type_name });
                printOptionalValue(value, shorten_types, indent + 1);
            } else {
                std.debug.print("{s}{s}{s}: {s} = null\n", .{ ind_str_2, comptime_prefix, fld.name, type_name });
            },

            else => std.debug.print("{s}{s}{s}: {s} = -\n", .{ ind_str_2, comptime_prefix, fld.name, type_name }),
        }
    }

    std.debug.print("{s}}}\n", .{ind_str});
}

pub fn printOptionalValue(value: anytype, shorten_types: bool, indent: comptime_int) void {
    const T = @TypeOf(value);
    const ind_str = "    " ** indent;

    switch (@typeInfo(T)) {
        .@"struct" => printStruct(value, shorten_types, indent),
        .array => {
            std.debug.print("{s}[ ", .{ind_str});
            printArray(value, shorten_types);
            std.debug.print(" ]\n", .{});
        },
        .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) {
            std.debug.print("{s}\"{s}\"\n", .{ ind_str, value });
        } else {
            std.debug.print("{s}{any}\n", .{ ind_str, value });
        },
        else => std.debug.print("{s}{any}\n", .{ ind_str, value }),
    }
}

pub fn printStructInline(s: anytype, shorten_types: bool) void {
    const s_type_info = @typeInfo(@TypeOf(s));
    if (s_type_info != .@"struct")
        @compileError("fn printStructInline: `s` is " ++ @typeName(s) ++ " , expected a struct");

    std.debug.print("{{ ", .{});

    inline for (s_type_info.@"struct".fields) |fld| {
        const field_value = @field(s, fld.name);
        const type_name = typeName(@typeName(fld.type), shorten_types);
        const comptime_prefix = if (fld.is_comptime) "comptime " else "";

        switch (@typeInfo(fld.type)) {
            .int, .float, .comptime_int, .comptime_float => std.debug.print("{s}{s}: {s} = {d}, ", .{ comptime_prefix, fld.name, type_name, field_value }),

            .bool => std.debug.print("{s}{s}: {s} = {}, ", .{ comptime_prefix, fld.name, type_name, field_value }),

            .@"enum" => std.debug.print("{s}{s}: {s} = {s}, ", .{ comptime_prefix, fld.name, type_name, @tagName(field_value) }),

            .pointer => |ptr_type_info| switch (ptr_type_info.size) {
                .one, .many, .c => std.debug.print("{s}{s}: {s} = {*}, ", .{ comptime_prefix, fld.name, type_name, field_value }),

                .slice => if (ptr_type_info.child == u8)
                    std.debug.print("{s}{s}: {s} = \"{s}\", ", .{ comptime_prefix, fld.name, type_name, field_value })
                else {
                    std.debug.print("{s}{s}: {s} = [ ", .{ comptime_prefix, fld.name, type_name });
                    printArray(field_value, shorten_types);
                    std.debug.print("], ", .{});
                },
            },

            else => std.debug.print("{s}{s}: {s} = {any}, ", .{ comptime_prefix, fld.name, type_name, field_value }),
        }
    }

    std.debug.print(" }}\n", .{});
}

fn printArray(a: anytype, shorten_types: bool) void {
    const is_array = @typeInfo(@TypeOf(a)) == .array;
    const is_slice = @typeInfo(@TypeOf(a)) == .pointer and @typeInfo(@TypeOf(a)).pointer.size == .slice;

    if (!is_array and !is_slice) return;

    const len = a.len;
    if (len == 0) return;

    if (len <= 8) {
        for (a, 0..) |item, i| {
            printItem(item, shorten_types);
            if (i < len - 1) std.debug.print(", ", .{});
        }
    } else {
        for (a[0..4], 0..) |item, i| {
            printItem(item, shorten_types);
            if (i < 3) std.debug.print(", ", .{});
        }
        std.debug.print(", ... ", .{});
        printItem(a[len - 1], shorten_types);
    }
}

fn printItem(item: anytype, shorten_types: bool) void {
    const T = @TypeOf(item);

    switch (@typeInfo(T)) {
        .@"struct" => {
            std.debug.print("{{ ", .{});
            inline for (std.meta.fields(T), 0..) |fld, i| {
                const field_value = @field(item, fld.name);
                std.debug.print("{s}: ", .{fld.name});

                switch (@typeInfo(@TypeOf(field_value))) {
                    .int, .float => std.debug.print("{d}", .{field_value}),
                    .bool => std.debug.print("{}", .{field_value}),
                    .@"enum" => std.debug.print("{s}", .{@tagName(field_value)}),
                    .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
                        std.debug.print("\"{s}\"", .{field_value});
                    } else {
                        std.debug.print("{any}", .{field_value});
                    },
                    else => std.debug.print("{any}", .{field_value}),
                }

                if (i < std.meta.fields(T).len - 1) {
                    std.debug.print(", ", .{});
                }
            }
            std.debug.print(" }}", .{});
        },
        .array => {
            std.debug.print("[ ", .{});
            printArray(item, shorten_types);
            std.debug.print(" ]", .{});
        },
        .pointer => |ptr| if (ptr.size == .slice) {
            if (ptr.child == u8) {
                std.debug.print("\"{s}\"", .{item});
            } else {
                std.debug.print("[ ", .{});
                printArray(item, shorten_types);
                std.debug.print(" ]", .{});
            }
        } else {
            std.debug.print("{any}", .{item});
        },
        .int, .float => std.debug.print("{d}", .{item}),
        .bool => std.debug.print("{}", .{item}),
        .@"enum" => std.debug.print("{s}", .{@tagName(item)}),
        else => std.debug.print("{any}", .{item}),
    }
}

fn typeName(name: []const u8, shorten: bool) []const u8 {
    if (!shorten) return name;
    if (name.len < 2) return name;

    if (std.mem.indexOf(u8, name, "file.")) |file_idx| {
        return name[file_idx + 5 ..];
    }

    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot_pos| {
        if (name.len > dot_pos + 1) {
            const shortened = name[dot_pos + 1 ..];
            const end = if (shortened[shortened.len - 1] == ')')
                shortened.len - 1
            else
                shortened.len;
            return shortened[0..end];
        }
    }

    return name;
}
