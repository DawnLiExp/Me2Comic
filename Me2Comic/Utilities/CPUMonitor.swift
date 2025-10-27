//
//  CPUMonitor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/13.
//

import AppKit
import Combine
import Foundation

// MARK: - CPU Usage Data

struct CPUUsageData: Sendable {
    let usage: Double
    let timestamp: Date
}

// MARK: - CPU Load Info

private struct CPULoadInfo {
    let user: Int32
    let system: Int32
    let idle: Int32
    let nice: Int32
    
    var total: Int64 {
        Int64(user) + Int64(system) + Int64(idle) + Int64(nice)
    }
    
    var active: Int64 {
        Int64(user) + Int64(system) + Int64(nice)
    }
}

// MARK: - CPU Monitor

@MainActor
final class CPUMonitor: ObservableObject {
    // MARK: - Properties
    
    @Published private(set) var usageHistory: [CPUUsageData] = []
    @Published private(set) var currentUsage: Double = 0.0
    @Published private(set) var isMonitoring = false
    
    private var monitoringTask: Task<Void, Never>?
    private var previousLoadInfo: CPULoadInfo?
    
    // MARK: - Constants
    
    private enum Constants {
        static let maxDataPoints = 30
        static let foregroundInterval: Duration = .seconds(2)
        static let backgroundInterval: Duration = .seconds(5)
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        previousLoadInfo = nil
        
        monitoringTask = Task { [weak self] in
            await self?.monitoringLoop()
        }
    }
    
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        previousLoadInfo = nil
    }
    
    func clearHistory() {
        usageHistory.removeAll()
        currentUsage = 0.0
        previousLoadInfo = nil
    }
    
    // MARK: - Private Methods
    
    private func monitoringLoop() async {
        while !Task.isCancelled {
            await sampleCPUUsage()
            
            let interval = isAppActive() ? Constants.foregroundInterval : Constants.backgroundInterval
            
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
        }
    }
    
    private func isAppActive() -> Bool {
        #if os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
    }
    
    private func sampleCPUUsage() async {
        let usage = await getCPUUsage()
        updateUsageData(usage)
    }
    
    private func updateUsageData(_ usage: Double) {
        let data = CPUUsageData(usage: usage, timestamp: Date())
        usageHistory.append(data)
        
        if usageHistory.count > Constants.maxDataPoints {
            usageHistory.removeFirst(usageHistory.count - Constants.maxDataPoints)
        }
        
        currentUsage = usage
    }
    
    private nonisolated func getCPUUsage() async -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0
        
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCpus,
            &cpuInfo,
            &numCpuInfo
        )
        
        guard result == KERN_SUCCESS, let cpuInfo else {
            return 0.0
        }
        
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(numCpuInfo * UInt32(MemoryLayout<natural_t>.size))
            )
        }
        
        let cpuLoadArray = Array(
            UnsafeBufferPointer(
                start: cpuInfo,
                count: Int(numCpuInfo)
            )
        )
        
        var totalUser: Int32 = 0
        var totalSystem: Int32 = 0
        var totalIdle: Int32 = 0
        var totalNice: Int32 = 0
        
        for i in stride(from: 0, to: Int(numCpus), by: 1) {
            let baseIndex = Int(CPU_STATE_MAX) * i
            totalUser += cpuLoadArray[baseIndex + Int(CPU_STATE_USER)]
            totalSystem += cpuLoadArray[baseIndex + Int(CPU_STATE_SYSTEM)]
            totalIdle += cpuLoadArray[baseIndex + Int(CPU_STATE_IDLE)]
            totalNice += cpuLoadArray[baseIndex + Int(CPU_STATE_NICE)]
        }
        
        let currentLoadInfo = CPULoadInfo(
            user: totalUser,
            system: totalSystem,
            idle: totalIdle,
            nice: totalNice
        )
        
        let usage: Double
        if let previous = await MainActor.run(body: { self.previousLoadInfo }) {
            let totalDelta = currentLoadInfo.total - previous.total
            let activeDelta = currentLoadInfo.active - previous.active
            
            usage = totalDelta > 0 ? Double(activeDelta) / Double(totalDelta) : 0.0
        } else {
            usage = 0.0
        }
        
        await MainActor.run {
            self.previousLoadInfo = currentLoadInfo
        }
        
        return max(0.0, min(1.0, usage))
    }
}
