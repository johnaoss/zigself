## zigSelf

An implementation of the Self programming language.

## What is Self?

[Self](https://selflanguage.org/) is a programming language designed in 1986 at
Xerox PARC. It is an object-oriented programming language which uses
_prototype-based inheritance_ as its basis and message-passing as its execution
method. It is dynamically (but strongly) typed.

Self uses an image-based approach for runtime. All the objects in the system
are stored in a _Self world_ and turned into a _snapshot_ for saving. At
runtime, objects can be interacted with, created and destroyed without losing
state on other objects.

## Build-time requirements

You need the Zig compiler, preferably one built with the known-good version
commit. You can find the source code, instructions for building, and more on the
[Zig repository](https://github.com/ziglang/zig).

Latest Zig commit known to work is [`ee651c3`](https://github.com/ziglang/zig/commit/ee651c3).
Earlier and later versions may work but there are no guarantees.

## Building zigSelf

1. Clone the repository with submodules: `git clone --recurse-submodules https://github.com/sin-ack/zigself`
2. Run the code: `zig build run -- examples/fibonacci.self`

That's it! If you want to build a release version, you can build one with
`zig build -Drelease-fast=true` and the binary will be in `zig-out/bin/`.

There is an (experimental) REPL that you can run with `zig build run -- repl.self`.

## Current status of zigSelf

- [x] Lexer
- [x] **Milestone 1:** Parser
- [ ] Initial VM and runtime
  - [x] Values
  - [x] Objects
    - [x] Slots objects
    - [x] Method objects
    - [x] Block objects
    - [x] Byte vector objects
    - [x] Activation objects
    - [x] Vector objects
  - [x] Value lookups on objects
  - [x] Assignments to mutable slots
  - [ ] Primitives
    - [x] Basic primitives
    - [x] Integer primitives
    - [x] Byte vector primitives
    - [x] Vector primitives
    - [ ] Object primitives
      - [x] `_AddSlots:`
      - [x] `_Eq:`
      - [x] `_Inspect:`
      - [ ] `_RemoveSlot:IfFail:`
  - [x] Heap and object allocation
  - [x] Generational scavenging garbage collection
    - [x] Basic implementation
    - [x] Old space -> new space tracking
    - [x] New space -> old space tracking
    - [x] VM tracking of values in primitives and interpreter
- [x] Test harness
- [ ] Standard library
  - [x] Move to std namespace
  - [x] String operations and text processing
  - [ ] Integer operations
  - [ ] Math
  - [ ] System calls
  - [ ] Low-level I/O (fd based)
  - and more...
- [x] **Milestone 2:** A REPL
- [ ] World building script
- [ ] Transporter (Self modules)
- [ ] Overlay system for Transporter (more on this later)
- [ ] Foreign Function Interface, to use libraries from other languages like C
- [ ] **Milestone 3:** Initial GUI support via xcb
- [ ] An implementation of Morphic
- [ ] **Milestone 4:** Self programming environment, based on Seity

## License

zigSelf is licensed under the GNU General Public License version 3, so that the
VM implementation remains open for everyone including end-users to study, modify
and share. See [LICENSE](LICENSE) for more details.
