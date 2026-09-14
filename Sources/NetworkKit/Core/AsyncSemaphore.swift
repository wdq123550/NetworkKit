//
//  AsyncSemaphore.swift
//  NetworkKit
//
//  async/await 版计数信号量：限制同时进行的下载数量
//

import Foundation

//MARK: - AsyncSemaphore
/// 用锁 + 续体实现的计数信号量。`acquire` 会在名额用尽时挂起，`release` 是同步的，可以直接放在 defer 里
final class AsyncSemaphore: @unchecked Sendable {
    //MARK: - 存储属性
    /// 互斥锁
    private let lock = NSLock()
    /// 最大并发数
    private let limit: Int
    /// 当前占用数
    private var current = 0
    /// 等待队列
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 用最大并发数初始化
    init(limit: Int) {
        self.limit = max(1, limit)
    }
}

//MARK: - 方法
extension AsyncSemaphore {
    /// 申请一个名额（满则挂起等待）
    func acquire() async {
        let acquired: Bool = lock.withLock {
            guard current < limit else { return false }
            current += 1
            return true
        }
        if acquired { return }
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }

    /// 释放一个名额（有等待者则直接把名额交给它）
    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                current = max(0, current - 1)
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
