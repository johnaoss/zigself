// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("../../language/ast.zig");
const Heap = @import("../heap.zig");
const Slot = @import("../slot.zig").Slot;
const hash = @import("../../utility/hash.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../object.zig");
const Script = @import("../../language/script.zig");
// Zig's shadowing rules are annoying.
const ByteVectorTheFirst = @import("../byte_vector.zig");
const Activation = @import("../activation.zig");

var static_map_map: ?Value = null;

pub fn getMapMap(heap: *Heap) !Value {
    if (static_map_map) |m| return m;

    var new_map = try heap.allocateInObjectSegment(@sizeOf(SlotsMap));

    // FIXME: Clean this up
    var header = @ptrCast(*Object.Header, new_map);
    header.object_information = 0b11;
    header.setObjectType(.Map);
    var map = @ptrCast(*Map, header);
    map.setMapType(.Slots);
    var slots_map = map.asSlotsMap();
    slots_map.properties = 0;
    slots_map.slot_count = 0;

    var map_value = Value.fromObjectAddress(new_map);
    header.map_pointer = map_value;
    static_map_map = map_value;
    return map_value;
}

// 2 bits for marker + 3 bits for object type
const MapTypeShift = 2 + 3;
const MapTypeMask: u64 = 0b111 << MapTypeShift;

pub const MapType = enum(u64) {
    Slots = 0b000 << MapTypeShift,
    Method = 0b001 << MapTypeShift,
    Block = 0b010 << MapTypeShift,
    ByteVector = 0b011 << MapTypeShift,
};

pub const Map = packed struct {
    header: Object.Header,

    pub const Slots = SlotsMap;
    pub const Method = MethodMap;
    pub const Block = BlockMap;
    pub const ByteVector = ByteVectorMap;

    fn init(self: *Map, map_type: MapType, map_map: Value) void {
        self.header.init(.Map, map_map);
        self.setMapType(map_type);
    }

    pub fn finalize(self: *Map, allocator: Allocator) void {
        switch (self.getMapType()) {
            .Slots, .ByteVector => unreachable,
            .Method => self.asMethodMap().finalize(allocator),
            .Block => self.asBlockMap().finalize(allocator),
        }
    }

    pub fn getMapType(self: *Map) MapType {
        const raw_map_type = self.header.object_information & MapTypeMask;
        return std.meta.intToEnum(MapType, raw_map_type) catch |err| switch (err) {
            std.meta.IntToEnumError.InvalidEnumTag => std.debug.panic(
                "Unexpected map type {x} on object at {*}\n",
                .{ raw_map_type >> MapTypeShift, self },
            ),
        };
    }

    pub fn setMapType(self: *Map, map_type: MapType) void {
        self.header.object_information = (self.header.object_information & ~MapTypeMask) | @enumToInt(map_type);
    }

    pub fn isSlotsMap(self: *Map) bool {
        return self.getMapType() == .Slots;
    }

    fn mustBeSlotsMap(self: *Map) void {
        if (!self.isSlotsMap()) {
            std.debug.panic("Expected the object at {*} to be a slots map", .{self});
        }
    }

    pub fn asSlotsMap(self: *Map) *Slots {
        self.mustBeSlotsMap();
        return @ptrCast(*Slots, self);
    }

    pub fn isMethodMap(self: *Map) bool {
        return self.getMapType() == .Method;
    }

    fn mustBeMethodMap(self: *Map) void {
        if (!self.isMethodMap()) {
            std.debug.panic("Expected the object at {*} to be a method map", .{self});
        }
    }

    pub fn asMethodMap(self: *Map) *Method {
        self.mustBeMethodMap();
        return @ptrCast(*Method, self);
    }

    pub fn isBlockMap(self: *Map) bool {
        return self.getMapType() == .Block;
    }

    fn mustBeBlockMap(self: *Map) void {
        if (!self.isBlockMap()) {
            std.debug.panic("Expected the object at {*} to be a block map", .{self});
        }
    }

    pub fn asBlockMap(self: *Map) *Block {
        self.mustBeBlockMap();
        return @ptrCast(*Block, self);
    }

    pub fn isByteVectorMap(self: *Map) bool {
        return self.getMapType() == .ByteVector;
    }

    fn mustBeByteVectorMap(self: *Map) void {
        if (!self.isByteVectorMap()) {
            std.debug.panic("Expected the object at {*} to be a byte vector map", .{self});
        }
    }

    pub fn asByteVectorMap(self: *Map) *ByteVector {
        self.mustBeByteVectorMap();
        return @ptrCast(*ByteVector, self);
    }

    pub fn getSizeInMemory(self: *Map) usize {
        return switch (self.getMapType()) {
            .Slots => self.asSlotsMap().getSizeInMemory(),
            .Method => self.asMethodMap().getSizeInMemory(),
            .Block => self.asBlockMap().getSizeInMemory(),
            .ByteVector => self.asByteVectorMap().getSizeInMemory(),
        };
    }

    pub fn asValue(self: *Map) Value {
        return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self)));
    }
};

// NOTE: properties comes *before* the slot count in the struct
//       definition, but comes *after* the slot count in the actual bit
//       definitions.
const SlotsMap = packed struct {
    map: Map,
    /// Slots map properties.
    /// The first byte is the amount of assignable slots the map has.
    /// The other bytes are currently reserved for future use.
    /// The last two bits are zero.
    properties: u32,
    /// The amount of slots. The slots begin after the end of this
    /// field.
    slot_count: u32,

    /// Create a new slots map. Takes the amount of slots this object will have.
    ///
    /// IMPORTANT: All slots *must* be initialized right after creation like this:
    ///
    /// ```
    /// var slots_map = Object.Map.Slots.create(heap, 2);
    /// slots_map.getSlots()[0].initConstant(...);
    /// slots_map.getSlots()[1].initMutable(...);
    /// ```
    pub fn create(heap: *Heap, slot_count: u32) !*SlotsMap {
        const size = requiredSizeForAllocation(slot_count);
        const map_map = try getMapMap(heap);

        var memory_area = try heap.allocateInObjectSegment(size);
        var self = @ptrCast(*SlotsMap, memory_area);
        self.init(slot_count, map_map);

        return self;
    }

    fn init(self: *SlotsMap, slot_count: u32, map_map: Value) void {
        self.map.init(.Slots, map_map);
        self.properties = 0;
        self.slot_count = slot_count;
    }

    fn getSlotsSlice(self: *SlotsMap) []u8 {
        const total_object_size = @sizeOf(SlotsMap) + self.slot_count * @sizeOf(Slot);
        const map_memory = @ptrCast([*]u8, self);
        return map_memory[@sizeOf(SlotsMap)..total_object_size];
    }

    pub fn getSlots(self: *SlotsMap) []Slot {
        return std.mem.bytesAsSlice(Slot, self.getSlotsSlice());
    }

    pub fn getSizeInMemory(self: *SlotsMap) usize {
        return requiredSizeForAllocation(self.slot_count);
    }

    pub fn asValue(self: *SlotsMap) Value {
        return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self)));
    }

    /// Return the amount of assignable slots that this slot map
    /// contains.
    pub fn getAssignableSlotCount(self: *SlotsMap) u8 {
        // 255 assignable slots ought to be enough for everybody.
        return @intCast(u8, self.properties >> 24);
    }

    pub fn setAssignableSlotCount(self: *SlotsMap, count: u8) void {
        self.properties = (self.properties & @as(u32, 0x00FFFFFF)) | (@as(u32, count) << 24);
    }

    pub fn getSlotByHash(self: *SlotsMap, hash_value: u32) ?*Slot {
        for (self.getSlots()) |*slot| {
            if (slot.hash == hash_value) {
                return slot;
            }
        }

        return null;
    }

    pub fn getSlotByName(self: *SlotsMap, string: []const u8) ?*Slot {
        const hash_value = hash.stringHash(string);
        return self.getSlotByHash(hash_value);
    }

    /// Return the size required for the whole map with the given slot count.
    pub fn requiredSizeForAllocation(slot_count: u32) usize {
        return @sizeOf(SlotsMap) + slot_count * @sizeOf(Slot);
    }
};

/// Common code and fields shared between methods and blocks.
const SlotsAndStatementsMap = packed struct {
    slots_map: *SlotsMap,
    /// The address of the statements to be executed when this method is
    /// activated. The stored value is a 64-bit bitfield consisting of:
    ///
    /// - 2 bits of zeros
    /// - 14 bits representing the amount of statements contained within
    /// - 48 bits for the pointer to the statements slice
    statements_address: Value,
    /// Which script this method or block is defined in.
    script_ref: Value,

    fn init(
        self: *SlotsAndStatementsMap,
        map_map: Value,
        argument_slot_count: u8,
        regular_slot_count: u32,
        statements: []AST.StatementNode,
        script: Script.Ref,
    ) void {
        self.slots_map.init(regular_slot_count + argument_slot_count, map_map);
        self.slots_map.map.init(.Method, map_map);
        self.setArgumentSlotCount(argument_slot_count);

        self.setStatementsSlice(statements);
        self.script_ref = Value.fromUnsignedInteger(@ptrToInt(script.value));
    }

    fn setArgumentSlotCount(self: *SlotsAndStatementsMap, count: u8) void {
        self.slots_map.properties = (self.slots_map.properties & @as(u32, 0xFF00FFFF)) | (@as(u32, count) << 16);
    }

    fn setStatementsSlice(self: *SlotsAndStatementsMap, statements: []AST.StatementNode) void {
        std.debug.assert(statements.len < (@as(usize, 1) << 14));
        self.statements_address = Value.fromUnsignedInteger((statements.len << 48) | @ptrToInt(statements.ptr));
    }

    pub fn finalize(self: *SlotsAndStatementsMap, allocator: Allocator) void {
        allocator.free(self.getStatementsSlice());

        self.getDefinitionScript().unref();
    }

    pub fn getDefinitionScript(self: *SlotsAndStatementsMap) Script.Ref {
        return Script.Ref{ .value = @intToPtr(*Script, self.script_ref.asUnsignedInteger()) };
    }

    pub fn getStatementsSlice(self: *SlotsAndStatementsMap) []AST.StatementNode {
        const statements_bitfield = self.statements_address.asUnsignedInteger();
        const statements_length = (statements_bitfield & @as(u64, 0xFFFF000000000000)) >> 48;
        const statements_address = statements_bitfield & @as(u64, 0x0000FFFFFFFFFFFF);

        return @intToPtr([*]AST.StatementNode, statements_address)[0..statements_length];
    }

    pub fn getArgumentSlotCount(self: *SlotsAndStatementsMap) u8 {
        return @intCast(u8, (self.slots_map.properties >> 16) & @as(u64, 0xFF));
    }

    fn getArgumentSlotsSlice(self: *SlotsAndStatementsMap, comptime MapSize: usize) []u8 {
        const object_size_up_to_argument_slots = MapSize + self.getArgumentSlotCount() * @sizeOf(Slot);
        const map_memory = @ptrCast([*]u8, self);
        return map_memory[MapSize..object_size_up_to_argument_slots];
    }

    pub fn getArgumentSlots(self: *SlotsAndStatementsMap, comptime MapSize: usize) []Slot {
        return std.mem.bytesAsSlice(Slot, self.getArgumentSlotsSlice(MapSize));
    }

    fn getSlotsSlice(self: *SlotsAndStatementsMap, comptime MapSize: usize) []u8 {
        const total_object_size = MapSize + self.slots_map.slot_count * @sizeOf(Slot);
        const argument_slots_size = self.getArgumentSlotCount() * @sizeOf(Slot);

        const map_memory = @ptrCast([*]u8, self);
        return map_memory[MapSize + argument_slots_size .. total_object_size];
    }

    pub fn getSlots(self: *SlotsAndStatementsMap, comptime MapSize: usize) []Slot {
        return std.mem.bytesAsSlice(Slot, self.getSlotsSlice(MapSize));
    }

    pub fn getAssignableSlotCount(self: *SlotsAndStatementsMap) u8 {
        return self.slots_map.getAssignableSlotCount();
    }

    pub fn setAssignableSlotCount(self: *SlotsAndStatementsMap, count: u8) void {
        self.slots_map.setAssignableSlotCount(count);
    }
};

/// A map for a method. A method object is a slots object which has two separate
/// slot sections for argument slots and regular slots defined on the method
/// respectively. It also contains a pointer to the actual set of statements to
/// be executed. Finally, some debug info is stored which is then displayed in
/// stack traces.
const MethodMap = packed struct {
    base_map: SlotsAndStatementsMap,
    /// What the method is called.
    method_name: Value,

    /// Borrows a ref for `script` from the caller. Takes ownership of
    /// `statements`.
    pub fn create(
        heap: *Heap,
        argument_slot_count: u8,
        regular_slot_count: u32,
        statements: []AST.StatementNode,
        method_name: ByteVectorTheFirst,
        script: Script.Ref,
    ) !*MethodMap {
        const size = requiredSizeForAllocation(regular_slot_count + argument_slot_count);
        const map_map = try getMapMap(heap);

        var memory_area = try heap.allocateInObjectSegment(size);
        var self = @ptrCast(*MethodMap, memory_area);
        self.init(map_map, argument_slot_count, regular_slot_count, statements, method_name, script);

        try heap.markAddressAsNeedingFinalization(memory_area);
        return self;
    }

    fn init(
        self: *MethodMap,
        map_map: Value,
        argument_slot_count: u8,
        regular_slot_count: u32,
        statements: []AST.StatementNode,
        method_name: ByteVectorTheFirst,
        script: Script.Ref,
    ) void {
        self.base_map.init(map_map, argument_slot_count, regular_slot_count, statements, script);
        self.method_name = method_name.asValue();
    }

    pub fn finalize(self: *MethodMap, allocator: Allocator) void {
        self.base_map.finalize(allocator);
    }

    pub fn asValue(self: *MethodMap) Value {
        return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self)));
    }

    pub fn getDefinitionScript(self: *MethodMap) Script.Ref {
        return self.base_map.getDefinitionScript();
    }

    pub fn getStatementsSlice(self: *MethodMap) []AST.StatementNode {
        return self.base_map.getStatementsSlice();
    }

    pub fn getArgumentSlotCount(self: *MethodMap) u8 {
        return self.base_map.getArgumentSlotCount();
    }

    pub fn getArgumentSlots(self: *MethodMap) []Slot {
        return self.base_map.getArgumentSlots(@sizeOf(MethodMap));
    }

    pub fn getSlots(self: *MethodMap) []Slot {
        return self.base_map.getSlots(@sizeOf(MethodMap));
    }

    pub fn getSizeInMemory(self: *MethodMap) usize {
        return requiredSizeForAllocation(self.base_map.slots_map.slot_count);
    }

    pub fn getAssignableSlotCount(self: *MethodMap) u8 {
        return self.base_map.getAssignableSlotCount();
    }

    pub fn setAssignableSlotCount(self: *MethodMap, count: u8) void {
        self.base_map.setAssignableSlotCount(count);
    }

    /// Return the size required for the whole map with the given slot count.
    pub fn requiredSizeForAllocation(slot_count: u32) usize {
        return @sizeOf(MethodMap) + slot_count * @sizeOf(Slot);
    }
};

/// A map for a block object. A block object is a slots + statements object
/// which can be defined in a method and then executed later. The block must be
/// executed while the method in which it is created is still on the activation
/// stack.
const BlockMap = packed struct {
    base_map: SlotsAndStatementsMap,
    /// A weak reference to the parent activation of this block. The block must
    /// not be activated if this activation has left the stack.
    parent_activation_weak: Value,
    /// A weak reference to the non-local return target activation of this
    /// block. If a non-local return happens inside this block, then it will
    /// target this activation.
    nonlocal_return_target_activation_weak: Value,

    /// Borrows a ref for `script` from the caller. Takes ownership of
    /// `statements`.
    pub fn create(
        heap: *Heap,
        argument_slot_count: u8,
        regular_slot_count: u32,
        statements: []AST.StatementNode,
        parent_activation: *Activation,
        nonlocal_return_target_activation: *Activation,
        script: Script.Ref,
    ) !*BlockMap {
        const size = requiredSizeForAllocation(regular_slot_count + argument_slot_count);
        const map_map = try getMapMap(heap);

        var memory_area = try heap.allocateInObjectSegment(size);
        var self = @ptrCast(*BlockMap, memory_area);
        self.init(map_map, argument_slot_count, regular_slot_count, statements, parent_activation, nonlocal_return_target_activation, script);

        try heap.markAddressAsNeedingFinalization(memory_area);
        return self;
    }

    fn init(
        self: *BlockMap,
        map_map: Value,
        argument_slot_count: u8,
        regular_slot_count: u32,
        statements: []AST.StatementNode,
        parent_activation: *Activation,
        nonlocal_return_target_activation: *Activation,
        script: Script.Ref,
    ) void {
        self.base_map.init(map_map, argument_slot_count, regular_slot_count, statements, script);
        self.setParentActivation(parent_activation);
        self.setNonlocalReturnTargetActivation(nonlocal_return_target_activation);
    }

    fn setParentActivation(self: *BlockMap, parent_activation: *Activation) void {
        var weak_ref = parent_activation.makeWeakRef();
        var weak_handle_address = @ptrToInt(weak_ref.handle.value);

        self.parent_activation_weak = Value.fromUnsignedInteger(weak_handle_address);
    }

    fn setNonlocalReturnTargetActivation(self: *BlockMap, nonlocal_return_target_activation: *Activation) void {
        var weak_ref = nonlocal_return_target_activation.makeWeakRef();
        var weak_handle_address = @ptrToInt(weak_ref.handle.value);

        self.nonlocal_return_target_activation_weak = Value.fromUnsignedInteger(weak_handle_address);
    }

    fn getParentActivationWeak(self: *BlockMap) Activation.Weak {
        return Activation.Weak{ .handle = .{ .value = @intToPtr(getActivationHandlePointerType(), self.parent_activation_weak.asUnsignedInteger()) } };
    }

    fn getNonlocalReturnTargetActivationWeak(self: *BlockMap) Activation.Weak {
        return Activation.Weak{ .handle = .{ .value = @intToPtr(getActivationHandlePointerType(), self.nonlocal_return_target_activation_weak.asUnsignedInteger()) } };
    }

    pub fn finalize(self: *BlockMap, allocator: Allocator) void {
        self.base_map.finalize(allocator);
        self.getParentActivationWeak().deinit();
        self.getNonlocalReturnTargetActivationWeak().deinit();
    }

    pub fn asValue(self: *BlockMap) Value {
        return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self)));
    }

    pub fn getDefinitionScript(self: *BlockMap) Script.Ref {
        return self.base_map.getDefinitionScript();
    }

    pub fn getStatementsSlice(self: *BlockMap) []AST.StatementNode {
        return self.base_map.getStatementsSlice();
    }

    pub fn getArgumentSlotCount(self: *BlockMap) u8 {
        return self.base_map.getArgumentSlotCount();
    }

    pub fn getArgumentSlots(self: *BlockMap) []Slot {
        return self.base_map.getArgumentSlots(@sizeOf(BlockMap));
    }

    pub fn getSlots(self: *BlockMap) []Slot {
        return self.base_map.getSlots(@sizeOf(BlockMap));
    }

    pub fn getParentActivation(self: *BlockMap) ?*Activation {
        return self.getParentActivationWeak().getPointer();
    }

    pub fn getNonlocalReturnTargetActivation(self: *BlockMap) ?*Activation {
        return self.getNonlocalReturnTargetActivationWeak().getPointer();
    }

    pub fn getSizeInMemory(self: *BlockMap) usize {
        return requiredSizeForAllocation(self.base_map.slots_map.slot_count);
    }

    pub fn getAssignableSlotCount(self: *BlockMap) u8 {
        return self.base_map.getAssignableSlotCount();
    }

    pub fn setAssignableSlotCount(self: *BlockMap, count: u8) void {
        self.base_map.setAssignableSlotCount(count);
    }

    /// Return the size required for the whole map with the given slot count.
    pub fn requiredSizeForAllocation(slot_count: u32) usize {
        return @sizeOf(MethodMap) + slot_count * @sizeOf(Slot);
    }

    fn getActivationHandlePointerType() type {
        const weak_type_info = @typeInfo(Activation.Weak);
        const handle_type_info = @typeInfo(weak_type_info.Struct.fields[0].field_type);
        return handle_type_info.Struct.fields[0].field_type;
    }
};

// A byte vector map. A simple map holding a reference to the byte vector.
const ByteVectorMap = packed struct {
    map: Map,
    /// A reference to the byte vector in question.
    byte_vector: Value,

    pub fn create(heap: *Heap, byte_vector: ByteVectorTheFirst) !*ByteVectorMap {
        const size = requiredSizeForAllocation();
        const map_map = try getMapMap(heap);

        var memory_area = try heap.allocateInObjectSegment(size);
        var self = @ptrCast(*ByteVectorMap, memory_area);
        self.init(map_map, byte_vector);

        return self;
    }

    fn init(self: *ByteVectorMap, map_map: Value, byte_vector: ByteVectorTheFirst) void {
        self.map.init(.ByteVector, map_map);
        self.byte_vector = byte_vector.asValue();
    }

    pub fn asValue(self: *ByteVectorMap) Value {
        return Value.fromObjectAddress(@ptrCast([*]u64, @alignCast(@alignOf(u64), self)));
    }

    pub fn getByteVector(self: *ByteVectorMap) ByteVectorTheFirst {
        return ByteVectorTheFirst.fromAddress(self.byte_vector.asObjectAddress());
    }

    pub fn getValues(self: *ByteVectorMap) []u8 {
        return self.getByteVector().getValues();
    }

    pub fn getSizeInMemory(self: *ByteVectorMap) usize {
        _ = self;
        return requiredSizeForAllocation();
    }

    pub fn requiredSizeForAllocation() usize {
        return @sizeOf(ByteVectorMap);
    }
};