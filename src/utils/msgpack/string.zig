const std = @import("std");
const c = @import("common.zig");

const isOptional = @import("utils.zig").isOptional;
const NonOptional = @import("utils.zig").NonOptional;

const maybePackNull = @import("null.zig").maybePackNull;
const maybeUnpackNull = @import("null.zig").maybeUnpackNull;

const packIntValue = @import("int.zig").packIntValue;
const unpackIntValue = @import("int.zig").unpackIntValue;

pub fn sizeOfPackedStringHeader(len: usize) !usize {
    if (len <= c.MSG_FIXSTR_MAX - c.MSG_FIXSTR_MIN) {
        return 1;
    } else if (len <= std.math.maxInt(u8)) {
        return 1 + @sizeOf(u8);
    } else if (len <= std.math.maxInt(u16)) {
        return 1 + @sizeOf(u16);
    } else if (len <= std.math.maxInt(u32)) {
        return 1 + @sizeOf(u32);
    } else {
        return error.StringTooLong;
    }
}

pub fn sizeOfPackedString(len: usize) !usize {
    return try sizeOfPackedStringHeader(len) + len;
}

pub fn packStringHeader(writer: anytype, len: usize) !void {
    if (len <= c.MSG_FIXSTR_MAX - c.MSG_FIXSTR_MIN) {
        try writer.writeByte(c.MSG_FIXSTR_MIN + @as(u8, @intCast(len)));
    } else if (len <= std.math.maxInt(u8)) {
        try writer.writeByte(c.MSG_STR8);
        try packIntValue(writer, u8, @intCast(len));
    } else if (len <= std.math.maxInt(u16)) {
        try writer.writeByte(c.MSG_STR16);
        try packIntValue(writer, u16, @intCast(len));
    } else if (len <= std.math.maxInt(u32)) {
        try writer.writeByte(c.MSG_STR32);
        try packIntValue(writer, u32, @intCast(len));
    } else {
        return error.StringTooLong;
    }
}

pub fn unpackStringHeader(reader: anytype, comptime T: type) !T {
    const header = try reader.readByte();
    switch (header) {
        c.MSG_FIXSTR_MIN...c.MSG_FIXSTR_MAX => {
            return header - c.MSG_FIXSTR_MIN;
        },
        c.MSG_STR8 => {
            return try unpackIntValue(reader, u8, NonOptional(T));
        },
        c.MSG_STR16 => {
            return try unpackIntValue(reader, u16, NonOptional(T));
        },
        c.MSG_STR32 => {
            return try unpackIntValue(reader, u32, NonOptional(T));
        },
        else => {
            return maybeUnpackNull(header, T);
        },
    }
}

pub fn packString(writer: anytype, comptime T: type, value_or_maybe_null: T) !void {
    const value = try maybePackNull(writer, T, value_or_maybe_null) orelse return;
    try packStringHeader(writer, value.len);
    try writer.writeAll(value);
}

pub fn unpackString(reader: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    const len = if (isOptional(T))
        try unpackStringHeader(reader, ?usize) orelse return null
    else
        try unpackStringHeader(reader, usize);

    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);

    try reader.readNoEof(data);
    return data;
}

const packed_null = [_]u8{0xc0};
const packed_abc = [_]u8{ 0xa3, 0x61, 0x62, 0x63 };

test "packString: abc" {
    var buffer: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try packString(stream.writer(), []const u8, "abc");
    try std.testing.expectEqualSlices(u8, &packed_abc, stream.getWritten());
}

test "packString: null" {
    var buffer: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try packString(stream.writer(), ?[]const u8, null);
    try std.testing.expectEqualSlices(u8, &packed_null, stream.getWritten());
}

test "sizeOfPackedString" {
    try std.testing.expectEqual(1, sizeOfPackedString(0));
}
