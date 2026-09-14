//
//  ResponseEnvelope.swift
//  NetworkKit
//
//  外层返回结构的字段映射与成功判定（兼容多后端不同字段名）
//

import Foundation

//MARK: - ResponseEnvelope
/// 外层返回结构的字段映射配置
///
/// 不同后端的统一返回壳字段名各不相同（有的叫 code/msg/data，有的叫 status/message/result），
/// 这里把「业务码 / 提示语 / 错误语 / 内容数据路径 / 成功判定」都做成可配置，
/// 全局给一套默认，单个请求可在协议里重写覆盖。所有 key 都支持 `a.b.c` 点路径。
public struct ResponseEnvelope: Sendable {
    /// 业务码字段名（如 "code"、"status"）；为 nil 表示无业务码、直接视为成功
    public var codeKey: String?
    /// 通用提示语字段名（如 "message"、"msg"）
    public var messageKey: String?
    /// 业务失败时的错误提示字段名（部分后端失败用单独字段）；为 nil 时回退到 messageKey
    public var errorMessageKey: String?
    /// 内容数据路径，直接传给 SmartCodable 的 designatedPath（如 "data"、"result.list"）；为 nil 表示整包解析
    public var dataPath: String?
    /// 当响应里找不到 codeKey 字段时，是否跳过拆包、直接整包解析（兼容「有的接口包了外层壳、有的没包」）。默认 false
    public var parsesRawWhenCodeMissing: Bool
    /// 成功判定：入参为解析出的业务码，返回 true 表示业务成功。`ResponseCode` 支持字面量，可直接写 `{ $0 == 0 }`、`{ $0 == "OK" }`
    public var isSuccess: @Sendable (_ code: ResponseCode?) -> Bool

    /// 完整初始化
    /// - Parameters:
    ///   - codeKey: 业务码字段名
    ///   - messageKey: 提示语字段名
    ///   - errorMessageKey: 失败提示语字段名（不传则回退 messageKey）
    ///   - dataPath: 内容数据路径（SmartCodable designatedPath）
    ///   - parsesRawWhenCodeMissing: 找不到业务码字段时是否整包解析
    ///   - isSuccess: 成功判定闭包，默认 code == 0
    public init(
        codeKey: String? = "code",
        messageKey: String? = "message",
        errorMessageKey: String? = nil,
        dataPath: String? = "data",
        parsesRawWhenCodeMissing: Bool = false,
        isSuccess: @escaping @Sendable (_ code: ResponseCode?) -> Bool = { $0 == 0 }
    ) {
        self.codeKey = codeKey
        self.messageKey = messageKey
        self.errorMessageKey = errorMessageKey
        self.dataPath = dataPath
        self.parsesRawWhenCodeMissing = parsesRawWhenCodeMissing
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

//MARK: - UnwrapResult
extension ResponseEnvelope {
    /// 拆壳结果：业务码校验通过后，告诉解码阶段「根对象是什么、模型从哪个路径解」
    public struct UnwrapResult {
        /// 已反序列化的顶层字典；顶层不是 JSON 对象（如接口直接返回数组）时为 nil
        public let rootDictionary: [String: Any]?
        /// 模型的实际解析路径；nil 表示整包解析
        public let dataPath: String?
        /// 解析出的业务码；没有业务码字段时为 nil
        public let code: ResponseCode?
        /// 解析出的提示语
        public let message: String?
    }
}

//MARK: - 便捷构造
extension ResponseEnvelope {
    /// 基于当前配置复制一份、仅替换内容数据路径（便于单请求只改 dataPath，其余继承全局默认）
    /// - Parameter newPath: 新的内容数据点路径，如 "data.content"；传 nil 表示整包解析
    public func replacingDataPath(_ newPath: String?) -> ResponseEnvelope {
        var copy = self
        copy.dataPath = newPath
        return copy
    }

    /// 基于当前配置复制一份、仅替换成功判定
    public func replacingSuccessRule(_ rule: @escaping @Sendable (ResponseCode?) -> Bool) -> ResponseEnvelope {
        var copy = self
        copy.isSuccess = rule
        return copy
    }
}

//MARK: - 方法
extension ResponseEnvelope {
    /// 校验外层壳的业务码，并给出模型的实际解析路径；业务失败抛 `NetworkError.business`
    /// - Parameter data: 原始响应数据
    public func unwrap(_ data: Data) throws -> UnwrapResult {
        // 整份 JSON 只反序列化一次，业务码判定与模型解析复用同一结果；顶层不是 JSON 对象时为 nil
        let rootDictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // 未配置业务码字段：无需做成功判定，按配置的路径解析
        guard let codeKey else {
            return UnwrapResult(rootDictionary: rootDictionary, dataPath: dataPath, code: nil, message: nil)
        }
        // 顶层不是 JSON 对象（如接口直接返回一个数组）：没有外层壳可拆，整包解析
        guard let rootDictionary else {
            return UnwrapResult(rootDictionary: nil, dataPath: nil, code: nil, message: nil)
        }

        let codeFieldExists = value(forKeyPath: codeKey, in: rootDictionary) != nil
        guard codeFieldExists else {
            // 响应里找不到业务码字段：按配置决定是整包解析，还是仍走一次成功判定（保持严格行为）
            if parsesRawWhenCodeMissing {
                return UnwrapResult(rootDictionary: rootDictionary, dataPath: nil, code: nil, message: nil)
            }
            let message = resolveMessage(in: rootDictionary, isFailure: true)
            guard isSuccess(nil) else {
                throw NetworkError.business(code: nil, message: message, raw: data)
            }
            return UnwrapResult(rootDictionary: rootDictionary, dataPath: dataPath, code: nil, message: message)
        }

        let code = resolveCode(in: rootDictionary)
        guard isSuccess(code) else {
            let message = resolveMessage(in: rootDictionary, isFailure: true)
            throw NetworkError.business(code: code, message: message, raw: data)
        }
        return UnwrapResult(
            rootDictionary: rootDictionary,
            dataPath: dataPath,
            code: code,
            message: resolveMessage(in: rootDictionary, isFailure: false)
        )
    }

    /// 从已反序列化的字典里按 keyPath（支持 "a.b.c" 点路径）取值
    /// - Parameters:
    ///   - keyPath: 形如 "data" 或 "result.list" 的路径，nil 直接返回 nil
    ///   - object: JSONSerialization 得到的字典
    /// - Returns: 命中的原始值
    public func value(forKeyPath keyPath: String?, in object: [String: Any]) -> Any? {
        guard let keyPath, keyPath.isEmpty == false else { return nil }
        var current: Any = object
        for key in keyPath.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    /// 从返回字典里解析业务码（兼容整数 / 数字字符串 / 文本 / 布尔）
    func resolveCode(in object: [String: Any]) -> ResponseCode? {
        ResponseCode(raw: value(forKeyPath: codeKey, in: object))
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
