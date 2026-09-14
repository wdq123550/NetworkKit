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

//MARK: - BackgroundTaskRunner
/// 用 UIApplication.beginBackgroundTask 为异步操作包一层后台保护；非 UIKit 平台为空操作
///
/// 注意：`UIApplication.shared` 在 App Extension 里不可用，本库目前只面向主 App target
enum BackgroundTaskRunner {
    /// 在后台任务保护下执行异步操作
    /// - Parameters:
    ///   - name: 后台任务名称（便于在系统日志里识别）
    ///   - operation: 需要被保护的异步操作
    static func run<T>(name: String, operation: () async throws -> T) async rethrows -> T {
        #if canImport(UIKit) && !os(watchOS)
        let handle = await BackgroundTaskHandle.begin(name: name)
        defer { handle.end() }
        return try await operation()
        #else
        return try await operation()
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
//MARK: - BackgroundTaskHandle
/// 一次后台任务的句柄：保证 endBackgroundTask 只会被调用一次（正常结束与系统到期二者取先到者）
private final class BackgroundTaskHandle: @unchecked Sendable {
    //MARK: - 存储属性
    /// 系统分配的后台任务标识
    private let identifier: LockedValue<UIBackgroundTaskIdentifier> = LockedValue(.invalid)
    /// 是否已经结束过
    private let hasEnded = LockedValue(false)

    /// 私有初始化，只能通过 begin 创建
    private init() {}
}

//MARK: - 方法
private extension BackgroundTaskHandle {
    /// 在主线程申请后台任务；系统到期回调里自动结束，避免被强杀
    @MainActor static func begin(name: String) -> BackgroundTaskHandle {
        let handle = BackgroundTaskHandle()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            handle.end()
        }
        handle.identifier.value = identifier
        return handle
    }

    /// 结束后台任务（幂等；异步切主线程释放）
    func end() {
        let shouldEnd = hasEnded.withValue { ended -> Bool in
            guard ended == false else { return false }
            ended = true
            return true
        }
        guard shouldEnd else { return }
        let identifier = identifier.value
        guard identifier != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
#endif
