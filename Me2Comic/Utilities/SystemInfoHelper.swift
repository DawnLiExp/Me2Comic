//
//  SystemInfoHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/7.
//

import Foundation

/// Provides system hardware information with unified error handling
enum SystemInfoHelper {
    // MARK: - Private Properties
    
    /// Cache for physical CPU core count result
    private static let physicalCoreResult: Result<Int, ProcessingError> = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0)
        
        if result == 0, cores > 0 {
            return .success(Int(cores))
        } else {
            return .failure(.invalidParameter(
                parameter: "hw.physicalcpu",
                reason: "sysctlbyname failed with code \(result) or returned invalid cores: \(cores)"
            ))
        }
    }()
    
    // MARK: - Legacy Methods (Backward Compatibility)
    
    /// Returns the number of physical CPU cores (legacy method with fallback)
    /// - Returns: Physical CPU core count, with a minimum of 1 and fallback to 6
    static func getPhysicalCPUCores() -> Int {
        return getPhysicalCPUCoresWithFallback()
    }
    
    /// Returns the maximum recommended thread count for image processing (legacy method)
    /// - Returns: Maximum thread count based on physical CPU cores, with fallback
    static func getMaxThreadCount() -> Int {
        return getPhysicalCPUCores()
    }
    
    // MARK: - Enhanced Methods (With Error Handling)
    
    /// Returns the number of physical CPU cores with detailed error information
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Result containing physical CPU core count
    static func getPhysicalCPUCoresResult(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Int, ProcessingError> {
        switch physicalCoreResult {
        case .success(let cores):
            logger?("Physical CPU cores detected: \(cores)", .debug, "SystemInfoHelper")
            return .success(cores)
        case .failure(let error):
            logger?("Failed to get physical CPU cores: \(error.localizedDescription)", .warning, "SystemInfoHelper")
            return .failure(error)
        }
    }
    
    /// Returns the number of physical CPU cores with fallback and logging
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Physical CPU core count, with a minimum of 1 and fallback to 6
    static func getPhysicalCPUCoresWithFallback(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Int {
        switch getPhysicalCPUCoresResult(logger: logger) {
        case .success(let cores):
            return max(1, cores)
        case .failure:
            let fallbackCores = 6
            logger?("Using fallback value: \(fallbackCores) CPU cores", .info, "SystemInfoHelper")
            return fallbackCores
        }
    }
    
    /// Returns the maximum recommended thread count with detailed error information
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Result containing maximum thread count based on physical CPU cores
    static func getMaxThreadCountResult(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Int, ProcessingError> {
        return getPhysicalCPUCoresResult(logger: logger)
    }
    
    /// Returns the maximum recommended thread count with fallback and logging
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Maximum thread count based on physical CPU cores, with fallback
    static func getMaxThreadCountWithFallback(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Int {
        return getPhysicalCPUCoresWithFallback(logger: logger)
    }
    
    /// Get system memory information
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Result containing physical memory in bytes
    static func getPhysicalMemory(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<UInt64, ProcessingError> {
        var memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        
        if result == 0 && memory > 0 {
            logger?("Physical memory detected: \(memory / 1024 / 1024 / 1024) GB", .debug, "SystemInfoHelper")
            return .success(memory)
        } else {
            let error = ProcessingError.invalidParameter(
                parameter: "hw.memsize",
                reason: "sysctlbyname failed with code \(result) or returned invalid memory: \(memory)"
            )
            logger?("Failed to get physical memory: \(error.localizedDescription)", .warning, "SystemInfoHelper")
            return .failure(error)
        }
    }
    
    /// Check if the system supports high performance processing
    /// - Parameter logger: Optional logger for operation tracking
    /// - Returns: Result indicating whether high performance mode is recommended
    static func supportsHighPerformanceProcessing(
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Bool, ProcessingError> {
        switch getPhysicalCPUCoresResult(logger: logger) {
        case .success(let cores):
            let supportsHighPerf = cores >= 8
            logger?(
                "High performance processing \(supportsHighPerf ? "supported" : "not recommended") (CPU cores: \(cores))",
                .debug,
                "SystemInfoHelper"
            )
            return .success(supportsHighPerf)
        case .failure(let error):
            return .failure(error)
        }
    }
}
