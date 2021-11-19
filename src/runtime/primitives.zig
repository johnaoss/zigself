// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("./object.zig");

const basic_primitives = @import("./primitives/basic.zig");
const bytevector_primitives = @import("./primitives/bytevector.zig");
const number_primitives = @import("./primitives/number.zig");
const object_primitives = @import("./primitives/object.zig");

/// A primitive specification. The `name` field specifies the exact selector the
/// primitive uses (i.e. `_DoFoo:WithBar:`, or `_PrintLine`), and the `function`
/// is the function which is called to execute the primitive.
const PrimitiveSpec = struct {
    name: []const u8,
    function: fn (allocator: *Allocator, receiver: Object.Ref, arguments: []Object.Ref, lobby: Object.Ref) Allocator.Error!Object.Ref,
};

const PrimitiveRegistry = &[_]PrimitiveSpec{
    // basic primitives
    .{ .name = "_Nil", .function = basic_primitives.Nil },
    // byte vector primitives
    .{ .name = "_PrintLine", .function = bytevector_primitives.PrintLine },
    // number primitives
    .{ .name = "_IntAdd:", .function = number_primitives.IntAdd },
    // object primitives
    .{ .name = "_AddSlots:", .function = object_primitives.AddSlots },
};

// FIXME: This is very naive! We shouldn't need to linear search every single
//        time.
pub fn hasPrimitive(selector: []const u8) bool {
    for (PrimitiveRegistry) |primitive| {
        if (std.mem.eql(u8, primitive.name, selector)) {
            return true;
        }
    }

    return false;
}

pub fn callPrimitive(allocator: *Allocator, selector: []const u8, receiver: Object.Ref, arguments: []Object.Ref, lobby: Object.Ref) !Object.Ref {
    for (PrimitiveRegistry) |primitive| {
        if (std.mem.eql(u8, primitive.name, selector)) {
            return try primitive.function(allocator, receiver, arguments, lobby);
        }
    }

    std.debug.panic("Unknown primitive \"{s}\" called\n", .{selector});
}
