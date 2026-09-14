//
//  LockedValue.swift
//  NetworkKit
//
//  用互斥锁保护的可变值，供跨线程读写的少量共享状态使用
//

import Foundation

//MARK: - LockedValue
/// 用 NSLock 保护的可变值容器
final class LockedValue<Value>: @unchecked Sendable {
    //MARK: - 存储属性
    /// 互斥锁
    private let lock = NSLock()
    /// 被保护的值
    private var storage: Value

    /// 用初值初始化
    init(_ value: Value) {
        self.storage = value
    }
}

//MARK: - 计算属性
extension LockedValue {
    /// 加锁读写整个值
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

//MARK: - 方法
extension LockedValue {
    /// 在锁内对值做一次原地修改并返回结果
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&storage) }
    }
}
