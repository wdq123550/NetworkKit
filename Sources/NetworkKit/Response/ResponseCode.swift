//
//  ResponseCode.swift
//  NetworkKit
//
//  后端业务码：兼容整数、数字字符串、任意字符串与布尔三种形态
//

import Foundation

//MARK: - 枚举定义
/// 外层壳里的业务码。不同后端可能返回 `0`、`"0"`、`"OK"`、`true`，这里统一收口，
/// 比较时 `.int(0)` 与 `.string("0")` 视为相等，所以 `isSuccess: { $0 == 0 }` 对两种后端都成立
public enum ResponseCode: Sendable, CustomStringConvertible {
    /// 整数业务码
    case int(Int)
    /// 字符串业务码（可能是数字字符串，也可能是 "OK" 这类文本）
    case string(String)
    /// 布尔业务码（如 `success: true`）
    case bool(Bool)

    /// 从 JSONSerialization 解出的原始值构造；不是数字 / 字符串 / 布尔时返回 nil
    init?(raw: Any?) {
        guard let raw, raw is NSNull == false else { return nil }
        if type(of: raw) == Bool.self, let bool = raw as? Bool {
            self = .bool(bool)
            return
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9_007_199_254_740_992 {
                self = .int(number.intValue)
            } else {
                self = .string(number.stringValue)
            }
            return
        }
        if let string = raw as? String {
            self = .string(string)
            return
        }
        return nil
    }
}

//MARK: - 计算属性
extension ResponseCode {
    /// 按整数取值：整数原样，数字字符串解析，布尔与其它文本返回 nil
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        case .bool: return nil
        }
    }
    /// 按字符串取值：布尔转成 "true" / "false"
    public var stringValue: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        }
    }
    /// 按布尔取值：只有 `.bool` 与 "true" / "false" 文本才有值
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        case .int: return nil
        }
    }
    /// 日志用描述
    public var description: String { stringValue }
    /// 用于相等比较与哈希的归一化键：能解成整数的按整数比，否则按字符串比
    private var normalizedKey: String {
        if let intValue { return "i:\(intValue)" }
        return "s:\(stringValue)"
    }
}

//MARK: - Equatable
extension ResponseCode: Equatable {
    /// `.int(0)`、`.string("0")` 视为相等；`.bool(true)` 与 `.string("true")` 视为相等
    public static func == (lhs: ResponseCode, rhs: ResponseCode) -> Bool {
        lhs.normalizedKey == rhs.normalizedKey
    }
}

//MARK: - Hashable
extension ResponseCode: Hashable {
    /// 与 `==` 保持一致，按归一化键做哈希
    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedKey)
    }
}

//MARK: - ExpressibleByIntegerLiteral
extension ResponseCode: ExpressibleByIntegerLiteral {
    /// 允许直接写 `code == 0`
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

//MARK: - ExpressibleByStringLiteral
extension ResponseCode: ExpressibleByStringLiteral {
    /// 允许直接写 `code == "OK"`
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

//MARK: - ExpressibleByBooleanLiteral
extension ResponseCode: ExpressibleByBooleanLiteral {
    /// 允许直接写 `code == true`
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}
