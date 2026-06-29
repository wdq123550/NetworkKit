//
//  ResponseEnvelope.swift
//  NetworkKit
//
//  外层返回结构的字段映射与成功判定（兼容多后端不同字段名）
//

import Foundation

// MARK: - ResponseEnvelope
/// 外层返回结构的字段映射配置
///
/// 不同后端的统一返回壳字段名各不相同（有的叫 code/msg/data，有的叫 status/message/result），
/// 这里把「业务码 / 提示语 / 错误语 / 内容数据路径 / 成功判定」都做成可配置，
/// 全局给一套默认，单个请求可在协议里重写覆盖。
public struct ResponseEnvelope {
    /// 业务码字段名（如 "code"、"status"）；为 nil 表示无业务码、直接视为成功
    public var codeKey: String?
    /// 通用提示语字段名（如 "message"、"msg"）
    public var messageKey: String?
    /// 业务失败时的错误提示字段名（部分后端失败用单独字段）；为 nil 时回退到 messageKey
    public var errorMessageKey: String?
    /// 内容数据路径，直接传给 SmartCodable 的 designatedPath（如 "data"、"result.list"）；为 nil 表示整包解析
    public var dataPath: String?
    /// 成功判定：入参为解析出的业务码，返回 true 表示业务成功
    public var isSuccess: (_ code: Int?) -> Bool

    /// 完整初始化
    /// - Parameters:
    ///   - codeKey: 业务码字段名
    ///   - messageKey: 提示语字段名
    ///   - errorMessageKey: 失败提示语字段名（不传则回退 messageKey）
    ///   - dataPath: 内容数据路径（SmartCodable designatedPath）
    ///   - isSuccess: 成功判定闭包，默认 code == 0
    public init(
        codeKey: String? = "code",
        messageKey: String? = "message",
        errorMessageKey: String? = nil,
        dataPath: String? = "data",
        isSuccess: @escaping (_ code: Int?) -> Bool = { $0 == 0 }
    ) {
        self.codeKey = codeKey
        self.messageKey = messageKey
        self.errorMessageKey = errorMessageKey
        self.dataPath = dataPath
        self.isSuccess = isSuccess
    }

    /// 无外层壳：整包就是数据，恒成功（直接把整个返回体解析成模型）
    public static let raw = ResponseEnvelope(
        codeKey: nil,
        messageKey: nil,
        errorMessageKey: nil,
        dataPath: nil,
        isSuccess: { _ in true }
    )
}

// MARK: - 便捷构造
extension ResponseEnvelope {
    /// 基于当前配置复制一份、仅替换内容数据路径（便于单请求只改 dataPath，其余继承全局默认）
    /// - Parameter newPath: 新的内容数据点路径，如 "data.content"；传 nil 表示整包解析
    public func replacingDataPath(_ newPath: String?) -> ResponseEnvelope {
        var copy = self
        copy.dataPath = newPath
        return copy
    }
}

// MARK: - 解析辅助方法
extension ResponseEnvelope {
    /// 从已反序列化的字典里按 keyPath（支持 "a.b.c" 点路径）取值
    /// - Parameters:
    ///   - keyPath: 形如 "data" 或 "result.list" 的路径，nil 直接返回 nil
    ///   - object: JSONSerialization 得到的字典
    /// - Returns: 命中的原始值
    func value(forKeyPath keyPath: String?, in object: [String: Any]) -> Any? {
        guard let keyPath, !keyPath.isEmpty else { return nil }
        var current: Any = object
        for key in keyPath.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    /// 从返回字典里解析业务码（兼容 Int / 数字字符串）
    func resolveCode(in object: [String: Any]) -> Int? {
        guard let raw = value(forKeyPath: codeKey, in: object) else { return nil }
        if let intValue = raw as? Int { return intValue }
        if let strValue = raw as? String { return Int(strValue) }
        if let numValue = raw as? NSNumber { return numValue.intValue }
        return nil
    }

    /// 从返回字典里解析提示语（成功用 messageKey，失败优先 errorMessageKey）
    /// - Parameter isFailure: 当前是否为业务失败场景
    func resolveMessage(in object: [String: Any], isFailure: Bool) -> String? {
        if isFailure, let errorKey = errorMessageKey,
           let value = value(forKeyPath: errorKey, in: object) as? String {
            return value
        }
        return value(forKeyPath: messageKey, in: object) as? String
    }
}
