// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

const Heap = @import("./Heap.zig");
const value = @import("./value.zig");
const Value = value.Value;
const IntegerValue = value.IntegerValue;
const stage2_compat = @import("../utility/stage2_compat.zig");

const Self = @This();

header: Header.Ptr,

pub fn createFromString(token: *Heap.AllocationToken, string: []const u8) Self {
    var self = createUninitialized(token, string.len);
    std.mem.copy(u8, self.getValues(), string);
    return self;
}

pub fn createUninitialized(token: *Heap.AllocationToken, size: usize) Self {
    var memory_area = token.allocate(.ByteArray, requiredSizeForAllocation(size));
    var header = @ptrCast(Header.Ptr, memory_area);

    header.init(size);

    return Self{ .header = header };
}

pub inline fn fromAddress(address: [*]u64) Self {
    return .{ .header = @ptrCast(*align(@alignOf(u64)) Header, address) };
}

pub fn getValues(self: Self) []u8 {
    const header_size = @sizeOf(Header);
    const total_length = self.header.length.get();

    return @ptrCast([*]u8, self.header)[header_size..total_length];
}

pub fn asValue(self: Self) Value {
    return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self.header)));
}

pub fn getSizeInMemory(self: Self) usize {
    return requiredSizeForAllocation(self.header.length.get() - @sizeOf(Header));
}

/// Return the size required for the byte vector with `length` amount of
/// bytes to be stored inside.
pub fn requiredSizeForAllocation(length: u64) usize {
    // A basic ceil
    const required_words = if (length == 0) 0 else ((length - 1) / @sizeOf(u64)) + 1;

    return @sizeOf(Header) + required_words * @sizeOf(u64);
}

pub const Header = packed struct {
    /// The length of the bytevector object, including the size of the
    /// header.
    length: IntegerValue(.Unsigned),

    pub const Ptr = stage2_compat.HeapPtr(Header, .Mutable);

    pub fn init(self: Header.Ptr, byte_array_length: u64) void {
        self.length = IntegerValue(.Unsigned).init(@sizeOf(Header) + byte_array_length);
    }

    pub fn asByteVector(self: Header.Ptr) Self {
        return .{ .header = @alignCast(@alignOf(u64), self) };
    }
};
