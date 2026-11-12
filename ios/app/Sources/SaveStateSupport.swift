//
//  SaveStateSupport.swift
//  3ds2apple
//
//  Instant save states are a runtime feature: the shell can only ask the
//  runtime to serialize or restore a system. The in-game menu reports the
//  feature as unavailable in this build instead of writing a file that could
//  not be loaded back.
//
//  This type is the single place the UI asks about save states, so the menu
//  wiring does not have to change when the shell uses the runtime's save-state
//  calls: `save(slot:)` and `load(slot:)` are the hooks the buttons will call.
//

import Foundation

struct SaveStateError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SaveStateSupport {
    /// Whether the runtime can take/restore a save state in this build.
    static let isAvailable = false

    /// Shown under the menu's Save State / Load State buttons.
    static let unavailableReason = "Save states are not available in this build."

    /// Save-state slots the UI would offer. Battery saves are managed by the
    /// Save Manager page instead.
    static let slotCount = 1

    static func save(slot: Int) -> Result<Void, SaveStateError> {
        .failure(SaveStateError(message: unavailableReason))
    }

    static func load(slot: Int) -> Result<Void, SaveStateError> {
        .failure(SaveStateError(message: unavailableReason))
    }
}
