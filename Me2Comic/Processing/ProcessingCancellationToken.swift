//
//  ProcessingCancellationToken.swift
//  Me2Comic
//
//  Cross-task cancellation token for detached processing work.
//

import Foundation

actor ProcessingCancellationToken {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func canContinue() -> Bool {
        !isCancelled && !Task.isCancelled
    }
}
