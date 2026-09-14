//
//  NetworkError.swift
//  NetworkKit
//
//  网络请求统一错误类型：send / response / download 抛出的错误一律是它
//

import Foundation

//MARK: - 枚举定义
/// 网络请求统一错误类型
public enum NetworkError: Error, Sendable {
    /// URL 拼接非法
    case invalidURL
    /// 请求参数编码失败（Encodable -> Data）
    case encoding(Error)
    /// 底层传输错误（URLSession 抛出的网络错误）
    case transport(Error)
    /// 请求超时
    case timeout
    /// 请求被取消
    case cancelled
    /// HTTP 状态码不在可接受范围内（携带状态码与原始返回体）
    case httpStatus(code: Int, data: Data)
    /// 业务失败：外层 code 未命中成功判定（携带业务码、提示语与原始返回体）
    case business(code: ResponseCode?, message: String?, raw: Data)
    /// 模型解析失败（携带说明、原始返回体，以及打开解析诊断时 SmartCodable 给出的字段级诊断）
    case decoding(message: String, raw: Data, diagnostics: String?)
    /// 拦截器 / 请求体或响应体变换钩子抛出的自定义错误，原样包在里面
    case custom(Error)
}

//MARK: - 计算属性
extension NetworkError {
    /// 是否为取消
    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
    /// 是否为超时
    public var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
    /// HTTP 状态码（仅 `.httpStatus` 有值）
    public var statusCode: Int? {
        if case .httpStatus(let code, _) = self { return code }
        return nil
    }
    /// 业务码（仅 `.business` 有值）
    public var businessCode: ResponseCode? {
        if case .business(let code, _, _) = self { return code }
        return nil
    }
    /// 后端返回的提示语（仅 `.business` 有值）
    public var businessMessage: String? {
        if case .business(_, let message, _) = self { return message }
        return nil
    }
    /// 原始返回体（`.httpStatus` / `.business` / `.decoding` 有值）
    public var responseData: Data? {
        switch self {
        case .httpStatus(_, let data), .business(_, _, let data), .decoding(_, let data, _): return data
        default: return nil
        }
    }
    /// 被包裹的底层错误（`.encoding` / `.transport` / `.custom` 有值）
    public var underlyingError: Error? {
        switch self {
        case .encoding(let error), .transport(let error), .custom(let error): return error
        default: return nil
        }
    }
}

//MARK: - 方法
extension NetworkError {
    /// 把任意错误归一化成 NetworkError：已是 NetworkError 原样返回；取消 / URLError 映射到对应 case；其余包进 `.custom`
    public static func normalize(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError { return networkError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .transport(urlError)
            }
        }
        return .custom(error)
    }
}

//MARK: - LocalizedError
extension NetworkError: LocalizedError {
    /// 面向用户 / 日志的中文错误描述
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的请求地址"
        case .encoding(let error):
            return "请求参数编码失败：\(error.localizedDescription)"
        case .transport(let error):
            return "网络连接失败：\(error.localizedDescription)"
        case .timeout:
            return "请求超时"
        case .cancelled:
            return "请求已取消"
        case .httpStatus(let code, _):
            return "服务异常（HTTP \(code)）"
        case .business(let code, let message, _):
            // 优先用后端返回的提示语，没有再兜底
            return message ?? "业务请求失败（code: \(code?.description ?? "nil")）"
        case .decoding(let message, _, _):
            return "数据解析失败：\(message)"
        case .custom(let error):
            return error.localizedDescription
        }
    }
}
