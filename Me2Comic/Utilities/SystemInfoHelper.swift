//
//  SystemInfoHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/7.
//

import Foundation

/// Provides system hardware information
enum SystemInfoHelper {
    // MARK: - Properties
    
    /// Cache for physical CPU core count
    private static let physicalCoreCount: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0)
        
        #if DEBUG
        if result == 0 {
            print("[SystemInfoHelper] Physical CPU cores detected: \(cores)")
        } else {
            print("[SystemInfoHelper] Failed to get physical CPU cores, falling back to 6")
        }
        #endif
        
        // Fallback to 6 if sysctlbyname fails or returns invalid value
        return result == 0 && cores > 0 ? Int(cores) : 6
    }()
    
    // MARK: - Public Methods
    
    /// Returns the number of physical CPU cores
    /// - Returns: Physical CPU core count, with a minimum of 1
    static func getPhysicalCPUCores() -> Int {
        max(1, physicalCoreCount)
    }
    
    /// Returns the maximum recommended thread count for image processing
    /// - Returns: Maximum thread count based on physical CPU cores
    static func getMaxThreadCount() -> Int {
        getPhysicalCPUCores()
    }
}
