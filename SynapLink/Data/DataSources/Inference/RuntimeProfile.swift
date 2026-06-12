//
//  RuntimeProfile.swift
//  SynapLink
//
//  Device-tier engine tuning — the single place that decides context size,
//  threads and KV quantization per RAM class. Values for the 4 GB tier are
//  NeuraLink's device-sweep results (LLMRuntimeProfile): ctx 1024, 2 threads
//  (more spills onto E-cores and hurts decode), q4_0 KV + flash attention.
//  Pulled forward from Phase 5 after E2B-on-iPhone-11 jetsam crashes showed
//  the one-size default (ctx 2048 / 4 threads / q8_0) was wrong for A13.
//

import Foundation

enum RuntimeProfile {

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Engine parameters tuned for this device, for the given model files.
    static func engineParams(modelPath: String, mmprojPath: String?) -> EngineParams {
        var params = EngineParams(modelPath: modelPath)
        params.mmprojPath = mmprojPath

        let gb = physicalMemoryGB
        switch gb {
        case ..<5.0:
            // iPhone 11/12/13 class — proven NeuraLink 4 GB profile.
            params.nCtx = 1024
            params.nThreads = 2
            params.kvTypeK = .q4_0
            params.kvTypeV = .q4_0
        case ..<7.0:
            params.nCtx = 2048
            params.nThreads = 4
            params.kvTypeK = .q8_0
            params.kvTypeV = .q8_0
        default:
            params.nCtx = 4096
            params.nThreads = 4
            params.kvTypeK = .q8_0
            params.kvTypeV = .q8_0
        }

        // Never exceed physical cores (SMT overcommit hurts throughput).
        params.nThreads = min(params.nThreads, Int32(ProcessInfo.processInfo.processorCount))
        return params
    }
}
