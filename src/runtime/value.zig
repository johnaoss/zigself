// Copyright (c) 2021-2022, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("../utility/hash.zig");
const Object = @import("./object.zig");
const Completion = @import("./completion.zig");
const ByteArray = @import("./byte_array.zig");
const SourceRange = @import("../language/source_range.zig");
const InterpreterContext = @import("./interpreter.zig").InterpreterContext;
const object_lookup = @import("./object/lookup.zig");
const Heap = @import("./heap.zig");
const debug = @import("../debug.zig");

const LOOKUP_DEBUG = debug.LOOKUP_DEBUG;

const LookupIntent = object_lookup.LookupIntent;
const LookupError = object_lookup.LookupError;
const parent_hash = hash.stringHash("parent");

pub const Value = packed struct {
    data: u64,

    pub const ValueMarkerMask: u64 = 0b11;

    pub const ValueType = enum(u64) {
        Integer = 0b00,
        ObjectReference = 0b01,
        FloatingPoint = 0b10,
        ObjectMarker = 0b11,
    };

    /// Create a new Value object from the given object address.
    pub fn fromObjectAddress(address: [*]u64) Value {
        // Must be 8-byte aligned
        std.debug.assert((@ptrToInt(address) & 0b111) == 0);
        return .{ .data = @ptrToInt(address) | @enumToInt(ValueType.ObjectReference) };
    }

    /// Create a new Value object from an integer literal.
    pub fn fromInteger(integer: i64) Value {
        std.debug.assert((@as(i64, -1) << 62) < integer and integer < (@as(i64, 1) << 62));
        return .{ .data = @bitCast(u64, integer << 2) | @enumToInt(ValueType.Integer) };
    }

    /// Create a new Value object from an unsigned integer literal.
    pub fn fromUnsignedInteger(integer: u64) Value {
        std.debug.assert(integer < (@as(u64, 1) << 62));
        return .{ .data = (integer << 2) | @enumToInt(ValueType.Integer) };
    }

    pub fn fromFloatingPoint(floating_point: f64) Value {
        return .{ .data = (@bitCast(u64, floating_point) & ~ValueMarkerMask) | @enumToInt(ValueType.FloatingPoint) };
    }

    /// Return the type of this value.
    pub fn getType(self: Value) ValueType {
        return @intToEnum(ValueType, self.data & ValueMarkerMask);
    }

    /// Return whether this value is an integer.
    pub fn isInteger(self: Value) bool {
        return self.getType() == .Integer;
    }

    /// Return whether this value is an object reference.
    pub fn isObjectReference(self: Value) bool {
        return self.getType() == .ObjectReference;
    }

    /// Return whether this value is a floating point number.
    pub fn isFloatingPoint(self: Value) bool {
        return self.getType() == .FloatingPoint;
    }

    /// Return this value as an integer.
    pub fn asInteger(self: Value) i64 {
        std.debug.assert(self.isInteger());
        return @bitCast(i64, self.data) >> 2;
    }

    /// Return this value as an unsigned integer.
    pub fn asUnsignedInteger(self: Value) u64 {
        std.debug.assert(self.isInteger());
        return self.data >> 2;
    }

    /// Return this value as a floating point number.
    pub fn asFloatingPoint(self: Value) f64 {
        std.debug.assert(self.isFloatingPoint());
        return @bitCast(f64, self.data & ~ValueMarkerMask);
    }

    /// Return the object address stored in this object as a pointer.
    pub fn asObjectAddress(self: Value) [*]u64 {
        std.debug.assert(self.isObjectReference());
        return @intToPtr([*]u64, self.data & ~ValueMarkerMask);
    }

    /// Return the object the address of which is stored in this value.
    pub fn asObject(self: Value) Object {
        std.debug.assert(self.isObjectReference());
        return Object.fromAddress(self.asObjectAddress());
    }

    /// Return the byte vector the address of which is stored in this value.
    pub fn asByteArray(self: Value) ByteArray {
        std.debug.assert(self.isObjectReference());
        return ByteArray.fromAddress(self.asObjectAddress());
    }

    pub fn lookup(
        self: Value,
        comptime intent: LookupIntent,
        context: *InterpreterContext,
        selector: []const u8,
        source_range: SourceRange,
    ) object_lookup.lookupReturnType(intent) {
        const selector_hash = hash.stringHash(selector);
        if (LOOKUP_DEBUG) std.debug.print("Value.lookup: Looking up \"{s}\" (hash: {x}) on {}\n", .{ selector, selector_hash, self });

        return try self.lookupByHash(intent, context, selector_hash, source_range);
    }

    pub fn lookupByHash(
        self: Value,
        comptime intent: LookupIntent,
        context: *InterpreterContext,
        selector_hash: u32,
        source_range: SourceRange,
    ) object_lookup.lookupReturnType(intent) {
        return switch (self.getType()) {
            .ObjectMarker => unreachable,
            .ObjectReference => self.asObject().lookupByHash(intent, context, selector_hash, source_range),

            .Integer => {
                if (LOOKUP_DEBUG) std.debug.print("Value.lookupByHash: Looking up on traits integer\n", .{});
                const integer_traits = context.vm.integer_traits.getValue();
                if (intent == .Read) {
                    if (selector_hash == parent_hash)
                        return @as(?Completion, Completion.initNormal(integer_traits));
                }

                return try integer_traits.lookupByHash(intent, context, selector_hash, source_range);
            },
            .FloatingPoint => {
                if (LOOKUP_DEBUG) std.debug.print("Value.lookupByHash: Looking up on traits float\n", .{});

                const float_traits = context.vm.float_traits.getValue();
                if (intent == .Read) {
                    if (selector_hash == parent_hash)
                        return @as(?Completion, Completion.initNormal(float_traits));
                }

                return try float_traits.lookupByHash(intent, context, selector_hash, source_range);
            },
        };
    }

    /// Clones this value and returns a copy of it.
    pub fn clone(self: Value, heap: *Heap) !Value {
        return switch (self.getType()) {
            .ObjectMarker => unreachable,
            .Integer, .FloatingPoint => Value{ .data = self.data },
            .ObjectReference => (try self.asObject().clone(heap)).asValue(),
        };
    }
};
