//
//  NetworkError.swift
//  NetworkKit
//
//  网络请求统一错误类型
//

import Foundation

// MARK: - 枚举定义
/// 网络请求统一错误类型
public enum NetworkError: Error {
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
    /// HTTP 状态码非 2xx（携带状态码与原始返回体）
    case httpStatus(code: Int, data: Data)
    /// 业务失败：外层 code 未命中成功判定（携带业务码、提示语与原始返回体）
    case business(code: Int?, message: String?, raw: Data)
    /// 模型解析失败（SmartCodable 返回 nil 或结构不符）
    case decoding(message: String, raw: Data)
}

// MARK: - LocalizedError
extension NetworkError: LocalizedError {
    /// 面向用户/日志的中文错误描述
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
            return message ?? "业务请求失败（code: \(code.map(String.init) ?? "nil")）"
        case .decoding(let message, _):
            return "数据解析失败：\(message)"
        }
    }
}
