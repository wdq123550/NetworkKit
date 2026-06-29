//
//  BackgroundTaskRunner.swift
//  NetworkKit
//
//  后台任务断言：App 切后台时为正在进行的网络请求争取一段额外执行时间
//

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// MARK: - BackgroundTaskRunner
/// 用最简单的 UIApplication.beginBackgroundTask 为异步操作包一层后台保护；非 UIKit 平台为空操作
enum BackgroundTaskRunner {
    /// 在后台任务保护下执行异步操作
    /// - Parameters:
    ///   - name: 后台任务名称（便于在系统日志里识别）
    ///   - operation: 需要被保护的异步操作
    static func run<T>(name: String, operation: () async throws -> T) async rethrows -> T {
        #if canImport(UIKit) && !os(watchOS)
        let taskID = await beginTask(name: name)
        defer { endTask(taskID) }
        return try await operation()
        #else
        return try await operation()
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// 在主线程申请后台任务标识
    @MainActor private static func beginTaskOnMain(name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }
    /// 申请后台任务（异步切主线程）
    private static func beginTask(name: String) async -> UIBackgroundTaskIdentifier {
        await beginTaskOnMain(name: name)
    }
    /// 结束后台任务（异步切主线程释放）
    private static func endTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(id)
        }
    }
    #endif
}
