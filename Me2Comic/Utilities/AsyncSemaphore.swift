//
//  AsyncSemaphore.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Async semaphore for concurrency control
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = min(available + 1, limit)
        }
    }
}
