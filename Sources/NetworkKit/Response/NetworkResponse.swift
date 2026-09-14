//
//  NetworkResponse.swift
//  NetworkKit
//
//  一次请求的完整响应：原始数据 + HTTP 元信息 + 上下文，并提供按 envelope 拆壳解码的能力
//

import Foundation
import SmartCodable

//MARK: - NetworkResponse
/// 请求成功返回后的完整响应。`data` 可被响应拦截器改写（解密 / 解压），其余为只读元信息
public struct NetworkResponse: @unchecked Sendable {
    //MARK: - 存储属性
    /// 响应体（响应拦截器与 `transformResponseBody` 可以改写它）
    public var data: Data
    /// HTTP 响应元信息；非 HTTP 响应时为 nil
    public let httpResponse: HTTPURLResponse?
    /// 实际发出的 URLRequest（拦截器改写之后）
    public let urlRequest: URLRequest
    /// 请求上下文（描述、原始请求体、第几次尝试）
    public let context: RequestContext
    /// 从发起到拿到本响应的耗时（秒，含全部重试）
    public let elapsed: TimeInterval
    /// 本请求使用的外层壳配置，`decode` 默认按它拆壳
    public let envelope: ResponseEnvelope
    /// 本请求使用的 SmartCodable 解码选项，`decode` 默认按它解析
    public let decodingOptions: Set<SmartDecodingOption>

    /// 完整初始化
    public init(
        data: Data,
        httpResponse: HTTPURLResponse?,
        urlRequest: URLRequest,
        context: RequestContext,
        elapsed: TimeInterval,
        envelope: ResponseEnvelope,
        decodingOptions: Set<SmartDecodingOption>
    ) {
        self.data = data
        self.httpResponse = httpResponse
        self.urlRequest = urlRequest
        self.context = context
        self.elapsed = elapsed
        self.envelope = envelope
        self.decodingOptions = decodingOptions
    }
}

//MARK: - 计算属性
extension NetworkResponse {
    /// HTTP 状态码；非 HTTP 响应时为 nil
    public var statusCode: Int? { httpResponse?.statusCode }
    /// 响应体按 UTF-8 解成的字符串；不是文本时为 nil
    public var utf8String: String? { String(data: data, encoding: .utf8) }
    /// 响应头 Content-Type
    public var contentType: String? { header("Content-Type") }
}

//MARK: - 方法
extension NetworkResponse {
    /// 读取某个响应头（不区分大小写）
    public func header(_ name: String) -> String? {
        httpResponse?.value(forHTTPHeaderField: name)
    }

    /// 把响应体反序列化成 JSON 对象（字典 / 数组 / 标量）
    public func jsonObject(options: JSONSerialization.ReadingOptions = [.fragmentsAllowed]) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: options)
        } catch {
            throw NetworkError.decoding(message: "响应不是合法 JSON：\(error.localizedDescription)", raw: data, diagnostics: nil)
        }
    }

    /// 按本请求的 envelope 与解码选项拆壳并解析成 SmartCodable 模型
    public func decode<Model: SmartDecodable>(_ type: Model.Type) throws -> Model {
        try decode(type, envelope: envelope, options: decodingOptions)
    }

    /// 用指定的 envelope 与解码选项拆壳并解析成 SmartCodable 模型（想临时换一套壳时用）
    public func decode<Model: SmartDecodable>(
        _ type: Model.Type,
        envelope: ResponseEnvelope,
        options: Set<SmartDecodingOption>
    ) throws -> Model {
        let unwrapped = try envelope.unwrap(data)
        NetworkConfiguration.clearLastDecodingDiagnostics()
        // 顶层是字典就复用已反序列化的结果，其余形态回落到用原始 Data 解析
        let model: Model?
        if let rootDictionary = unwrapped.rootDictionary {
            model = Model.deserialize(from: rootDictionary, designatedPath: unwrapped.dataPath, options: options)
        } else {
            model = Model.deserialize(from: data, designatedPath: unwrapped.dataPath, options: options)
        }
        guard let model else {
            let pathDescription = unwrapped.dataPath.map { "解析路径 \($0)" } ?? "整包解析"
            throw NetworkError.decoding(
                message: "SmartCodable 解析为 \(Model.self) 失败（\(pathDescription)）",
                raw: data,
                diagnostics: NetworkConfiguration.lastDecodingDiagnostics
            )
        }
        return model
    }

    /// 按本请求的 envelope 拆壳后，用标准 JSONDecoder 解析成 Codable 模型（不想用 SmartCodable 的场景）
    public func decode<Model: Decodable>(_ type: Model.Type, decoder: JSONDecoder) throws -> Model {
        try decode(type, decoder: decoder, envelope: envelope)
    }

    /// 用指定 envelope 拆壳后，用标准 JSONDecoder 解析成 Codable 模型
    public func decode<Model: Decodable>(_ type: Model.Type, decoder: JSONDecoder, envelope: ResponseEnvelope) throws -> Model {
        let unwrapped = try envelope.unwrap(data)
        let payload: Data
        if let rootDictionary = unwrapped.rootDictionary, let dataPath = unwrapped.dataPath {
            guard let value = envelope.value(forKeyPath: dataPath, in: rootDictionary) else {
                throw NetworkError.decoding(message: "响应里不存在路径 \(dataPath)", raw: data, diagnostics: nil)
            }
            do {
                payload = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            } catch {
                throw NetworkError.decoding(message: "路径 \(dataPath) 下的内容无法序列化：\(error.localizedDescription)", raw: data, diagnostics: nil)
            }
        } else {
            payload = data
        }
        do {
            return try decoder.decode(Model.self, from: payload)
        } catch {
            throw NetworkError.decoding(message: "JSONDecoder 解析为 \(Model.self) 失败：\(error)", raw: data, diagnostics: nil)
        }
    }
}
