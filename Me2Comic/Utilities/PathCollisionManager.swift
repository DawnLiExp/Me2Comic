//
//  PathCollisionManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Thread-safe management of output path collisions
actor PathCollisionManager {
    private var reservedPaths: Set<String> = []
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    /// Generate unique output path with collision avoidance
    /// - Parameters:
    ///   - basePath: Base path without extension
    ///   - suffix: Suffix including extension (e.g., ".jpg", "-1.jpg")
    /// - Returns: Unique path guaranteed not to collide
    func generateUniquePath(basePath: String, suffix: String) -> String {
        var candidate = basePath + suffix
        var candidateKey = candidate.lowercased()
        var attempt = 0
        
        while reservedPaths.contains(candidateKey) && attempt < 10000 {
            attempt += 1
            candidate = "\(basePath)-\(attempt)\(suffix)"
            candidateKey = candidate.lowercased()
        }
        
        // Fallback to timestamp if too many collisions
        if reservedPaths.contains(candidateKey) {
            #if DEBUG
            logger?("Excessive path collisions detected, using timestamp fallback", .debug, "PathCollisionManager")
            #endif
            
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            candidate = "\(basePath)-\(timestamp)\(suffix)"
            candidateKey = candidate.lowercased()
        }
        
        reservedPaths.insert(candidateKey)
        
        #if DEBUG
        if attempt > 0 {
            logger?("Path collision resolved: \(attempt) attempts for \(basePath)", .debug, "PathCollisionManager")
        }
        #endif
        
        return candidate
    }
    
    /// Clear all reserved paths
    func reset() {
        #if DEBUG
        logger?("Path collision manager reset, cleared \(reservedPaths.count) reserved paths", .debug, "PathCollisionManager")
        #endif
        reservedPaths.removeAll()
    }
}
