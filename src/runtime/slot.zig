// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("./object.zig");
const ref_counted = @import("../utility/ref_counted.zig");
const hash = @import("../utility/hash.zig");

const Self = @This();

// Cannot use Object.Ref because it creates a cycle.
const ObjectRef = ref_counted.RefPtrWithoutTypeChecks(Object);

/// Initialize a slot. The slot borrows a ref from the caller for `value`.
/// `name` is duped internally.
pub fn init(
    allocator: *Allocator,
    is_mutable: bool,
    is_parent: bool,
    name: []const u8,
    value: ObjectRef,
) !Self {
    const name_hash = hash.stringHash(name);

    return Self{
        .allocator = allocator,
        .is_mutable = is_mutable,
        .is_parent = is_parent,
        .name = try allocator.dupe(u8, name),
        .name_hash = name_hash,
        .value = value,
    };
}

/// Deinitialize the slot, and unref the value.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.name);
    self.value.unref();
}

pub fn copy(self: Self) !Self {
    self.value.ref();
    return init(self.allocator, self.is_mutable, self.is_parent, self.name, self.value);
}

/// Assign a new value to the given slot object. The previous value is unref'd.
/// The new value borrows a ref from the caller.
pub fn assignNewValue(self: *Self, value: Object.Ref) void {
    self.value.unref();
    self.value = value;
}

allocator: *Allocator,
is_mutable: bool,
is_parent: bool,
name: []const u8,
name_hash: u32,
value: ObjectRef,
