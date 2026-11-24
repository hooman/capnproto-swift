// Enum readers against C++-encoded messages, on the host and in a separate Embedded module.
// The exported entry instantiates EnumList, CapnpList<EnumList<_>>, raw(at:) and the raw
// field accessors, so the Embedded allocation check covers them.
// Modes: 0 = empty message (schema defaults), 1 = known values (enums.capnp),
// 2 = ordinals unknown to this schema (written with the newer twin, enums-newer.capnp).

import CapnpRuntime

typealias Palette = Capnp_e0e5000000000001.PaletteReader
typealias Which = Capnp_e0e5000000000001.PaletteReader.choiceReader._CapnpWhich

@c(verify_enums)
public func verifyEnums(_ pointer: UnsafeRawPointer, _ count: Int, _ mode: Int32) -> UInt64 {
    let raw = unsafe UnsafeRawBufferPointer(start: pointer, count: count)
    let arena = Arena(framedBytes: unsafe RawSpan(_unsafeBytes: raw))
    let sum = arena.withRoot { root -> UInt64 in
        let p = Palette(root.borrowed())
        switch mode {
        case 0:
            precondition(p.primary == .red && p._capnpRaw_primary == 0)
            precondition(p.accent == .blue && p._capnpRaw_accent == 2)
            precondition(p.colors.count == 0 && p.grid.count == 0)
            precondition(p.level == .low && p.mood == .sad && p.shuffled == .red)
            precondition(p.choice._capnpWhich == Which.none)
            precondition(p.choice.shade == .green && p.choice._capnpRaw_shade == 1)
            precondition(p.extra.tone == .happy && p.extra._capnpRaw_tone == 1)
            return 10
        case 1:
            precondition(p.primary == .green && p._capnpRaw_primary == 1)
            precondition(p.accent == .blue && p._capnpRaw_accent == 2)
            let colors = p.colors
            precondition(colors.count == 2 && colors[0] == .red && colors[1] == .blue)
            precondition(colors.raw(at: 1) == 2)
            let grid = p.grid
            precondition(grid.count == 2 && grid[0].count == 1 && grid[0][0] == .green)
            precondition(grid[1].count == 2 && grid[1][0] == .blue && grid[1][1] == .red)
            precondition(p.level == .high && p.mood == .happy && p.shuffled == .blue)
            precondition(p._capnpRaw_shuffled == 2)
            precondition(p.choice._capnpWhich == Which.shade)
            precondition(p.choice.shade == .red && p.choice._capnpRaw_shade == 0)
            precondition(p.extra.tone == .happy)
            return 20
        default:
            precondition(p.primary == nil && p._capnpRaw_primary == 3)
            precondition(p.accent == .red && p._capnpRaw_accent == 0)
            let colors = p.colors
            precondition(colors.count == 2 && colors[0] == nil && colors.raw(at: 0) == 3)
            precondition(colors[1] == .green)
            let grid = p.grid
            precondition(grid.count == 1 && grid[0][0] == nil && grid[0].raw(at: 0) == 3)
            precondition(p.mood == nil && p._capnpRaw_mood == 2)
            precondition(p.extra.tone == .sad && p.level == .low)
            precondition(p.choice._capnpWhich == Which.none && p.choice.shade == .green)
            return 30
        }
    }
    precondition(arena.error == .none, "enum readers reported a wire error")
    return sum
}
