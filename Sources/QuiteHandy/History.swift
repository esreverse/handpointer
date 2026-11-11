import Foundation

/// One undo/redo history for everything you change while the pointer is on: lines and stamps on
/// the screen, lines and stamps on the whiteboard, and the whiteboard itself (opening, closing,
/// pulling out a new sheet, resizing, moving).
///
/// Each ink keeps its own steps; the history only remembers in which order they happened.
final class History {
    indirect enum Entry {
        /// One step in that ink's own undo list.
        case ink(Ink)
        /// The whiteboard went from one state to another.
        case board(Whiteboard.Board, Whiteboard.State, Whiteboard.State)
        /// Several entries that undo and redo together.
        case group([Entry])
    }

    var board: Whiteboard?
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var grouping: [Entry]?
    private static let maxEntries = 300

    func add(_ entry: Entry) {
        if grouping != nil {
            grouping?.append(entry)
            return
        }
        undoEntries.append(entry)
        if undoEntries.count > History.maxEntries {
            undoEntries.removeFirst()
        }
        redoEntries = []
    }

    /// Everything added until `endGroup` undoes as one step.
    func beginGroup() {
        grouping = []
    }

    func endGroup() {
        guard let g = grouping else {
            return
        }
        grouping = nil
        if !g.isEmpty {
            add(.group(g))
        }
    }

    func undo() {
        while let e = undoEntries.popLast() {
            if perform(e, back: true) {
                redoEntries.append(e)
                return
            }
        }
    }

    func redo() {
        while let e = redoEntries.popLast() {
            if perform(e, back: false) {
                undoEntries.append(e)
                return
            }
        }
    }

    func clear() {
        undoEntries = []
        redoEntries = []
        grouping = nil
    }

    /// False when the entry no longer applies (a line that has faded away in the meantime).
    private func perform(_ e: Entry, back: Bool) -> Bool {
        switch e {
        case let .ink(ink):
            return back ? ink.undo() : ink.redo()
        case let .board(b, from, to):
            board?.restore(b, back ? from : to)
            return true
        case let .group(entries):
            var any = false
            for item in back ? entries.reversed() : entries {
                any = perform(item, back: back) || any
            }
            return any
        }
    }
}
