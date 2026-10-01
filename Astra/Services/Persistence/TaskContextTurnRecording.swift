import Foundation

/// Session projections are keyed by the durable run, not append count.
enum TaskContextTurnRecording {
    static func upsert(_ turn: TaskContextState.Turn, state: inout TaskContextState, limit: Int) {
        if let runID = turn.runID, let index = state.turns.firstIndex(where: { $0.runID == runID }) {
            var refreshed = turn
            refreshed.turn = state.turns[index].turn
            refreshed.outputFile = state.turns[index].outputFile
            state.turns[index] = refreshed
        } else { state.turns.append(turn) }
        state.turns = Array(state.turns.suffix(limit))
    }
}
