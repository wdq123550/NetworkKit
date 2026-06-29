//
//  NetworkClient.swift
//  NetworkKit
//
//  请求执行引擎：组请求 / 拦截 / 重试 / 拆包 / SmartCodable 解析
//

import Foundation
import SmartCodable

public final class NetworkClient {
    // MARK: - 存储属性
    /// 单例实例
    public static let shared = NetworkClient()
    private init() {}
    /// 请求体/查询参数编码器
    private let encoder = JSONEncoder()
}

// MARK: - 方法
extension NetworkClient {
    /// 发送请求并解析为返回模型
    public func send<R: NetworkRequest>(_ request: R) async throws -> R.ResponseModel {
        let urlRequest = try await buildURLRequest(for: request)
        let (data, response) = try await performWithRetry(urlRequest, request: request)
        try await runResponseInterceptors(data: data, response: response, urlRequest: urlRequest, request: request)
        try validateHTTPStatus(response: response, data: data)
        return try decode(data: data, request: request)
    }

    /// 组装 URLRequest（拼 URL、编码参数、铺 header、跑请求拦截器）
    private func buildURLRequest<R: NetworkRequest>(for request: R) async throws -> URLRequest {
        guard var components = URLComponents(string: request.host + request.path) else {
            throw NetworkError.invalidURL
        }

        // 查询参数：显式 query/queryParameters；或无 body 的方法即便传了 body 参数也降级拼到 query
        switch request.task {
        case .query(let params):
            components.queryItems = try queryItems(fromEncodable: params)
        case .queryParameters(let dict):
            components.queryItems = queryItems(fromDict: dict)
        case .jsonBody(let params) where request.method.prefersBodyEncoding == false:
            components.queryItems = try queryItems(fromEncodable: params)
        case .jsonParameters(let dict) where request.method.prefersBodyEncoding == false:
            components.queryItems = queryItems(fromDict: dict)
        case .none, .jsonBody, .jsonParameters, .rawBody:
            break
        }

        guard let url = components.url else { throw NetworkError.invalidURL }

        var urlRequest = URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue

        // header：全局默认 -> 请求自定义
        var headers = NetworkConfiguration.shared.defaultHeaders
        for (key, value) in request.headers { headers[key] = value }
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        // 请求体：仅在支持 body 的方法上设置
        if request.method.prefersBodyEncoding {
            switch request.task {
            case .jsonBody(let params):
                urlRequest.httpBody = try encodeBody(fromEncodable: params)
            case .jsonParameters(let dict):
                urlRequest.httpBody = try encodeBody(fromDict: dict)
            case .rawBody(let data):
                urlRequest.httpBody = data
            case .none, .query, .queryParameters:
                break
            }
        }

        try await runRequestInterceptors(&urlRequest, request: request)
        log("➡️ \(request.method.rawValue) \(url.absoluteString)")
        return urlRequest
    }

    /// 执行请求拦截器（全局在前，请求自身在后）
    private func runRequestInterceptors<R: NetworkRequest>(_ urlRequest: inout URLRequest, request: R) async throws {
        if !request.ignoreGlobalInterceptors {
            for interceptor in NetworkConfiguration.shared.globalRequestInterceptors {
                try await interceptor.intercept(&urlRequest)
            }
        }
        for interceptor in request.requestInterceptors {
            try await interceptor.intercept(&urlRequest)
        }
    }

    /// 执行返回拦截器（全局在前，请求自身在后）
    private func runResponseInterceptors<R: NetworkRequest>(data: Data, response: URLResponse, urlRequest: URLRequest, request: R) async throws {
        if !request.ignoreGlobalInterceptors {
            for interceptor in NetworkConfiguration.shared.globalResponseInterceptors {
                try await interceptor.intercept(data: data, response: response, for: urlRequest)
            }
        }
        for interceptor in request.responseInterceptors {
            try await interceptor.intercept(data: data, response: response, for: urlRequest)
        }
    }

    /// 带重试的请求执行
    private func performWithRetry<R: NetworkRequest>(_ urlRequest: URLRequest, request: R) async throws -> (Data, URLResponse) {
        let policy = request.retryPolicy
        var retriedCount = 0
        while true {
            do {
                return try await perform(urlRequest)
            } catch {
                let mappedError = mapTransportError(error)
                guard retriedCount < policy.maxRetryCount, policy.shouldRetry(mappedError, retriedCount) else {
                    throw mappedError
                }
                retriedCount += 1
                log("🔁 第 \(retriedCount) 次重试：\(mappedError.localizedDescription)")
                if policy.retryDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(policy.retryDelay * 1_000_000_000))
                }
            }
        }
    }

    /// 单次发送
    private func perform(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        try await NetworkConfiguration.shared.session.data(for: urlRequest)
    }

    /// 校验 HTTP 状态码（非 2xx 视为 httpStatus 错误）
    private func validateHTTPStatus(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NetworkError.httpStatus(code: httpResponse.statusCode, data: data)
        }
    }

    /// 拆外层壳 + 用 SmartCodable 解析数据为模型
    private func decode<R: NetworkRequest>(data: Data, request: R) throws -> R.ResponseModel {
        let envelope = request.envelope

        // 有业务码字段才做成功判定与拆包；否则直接整包解析
        if envelope.codeKey != nil {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = envelope.resolveCode(in: object)
            guard envelope.isSuccess(code) else {
                let message = envelope.resolveMessage(in: object, isFailure: true)
                log("❌ 业务失败 code=\(code.map(String.init) ?? "nil") message=\(message ?? "")")
                throw NetworkError.business(code: code, message: message, raw: data)
            }
        }

        guard let model = R.ResponseModel.deserialize(from: data, designatedPath: envelope.dataPath) else {
            throw NetworkError.decoding(message: "SmartCodable 解析为 \(R.ResponseModel.self) 失败", raw: data)
        }
        log("✅ 解析成功 \(R.ResponseModel.self)")
        return model
    }
}

// MARK: - 编码辅助方法
extension NetworkClient {
    /// 把 Encodable 结构体编码成 JSON 请求体
    private func encodeBody(fromEncodable value: Encodable) throws -> Data {
        do {
            return try encoder.encode(AnyEncodable(value))
        } catch {
            throw NetworkError.encoding(error)
        }
    }

    /// 把松散字典编码成 JSON 请求体
    private func encodeBody(fromDict dict: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: dict)
        } catch {
            throw NetworkError.encoding(error)
        }
    }

    /// 把 Encodable 结构体转成 URL 查询项
    private func queryItems(fromEncodable value: Encodable) throws -> [URLQueryItem] {
        let data: Data
        do {
            data = try encoder.encode(AnyEncodable(value))
        } catch {
            throw NetworkError.encoding(error)
        }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return queryItems(fromDict: dict)
    }

    /// 把松散字典转成 URL 查询项
    private func queryItems(fromDict dict: [String: Any]) -> [URLQueryItem] {
        // 稳定排序，便于缓存与日志比对
        dict.keys.sorted().map { key in
            URLQueryItem(name: key, value: Self.queryStringValue(dict[key]))
        }
    }

    /// 把任意 JSON 值转成查询字符串
    private static func queryStringValue(_ value: Any?) -> String? {
        switch value {
        case let str as String: return str
        case let num as NSNumber: return num.stringValue
        case .none, is NSNull: return nil
        default: return "\(value!)"
        }
    }
}

// MARK: - 错误与日志辅助方法
extension NetworkClient {
    /// 把底层错误归一化为 NetworkError
    private func mapTransportError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError { return networkError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .transport(urlError)
            }
        }
        return .transport(error)
    }

    /// 调试日志（沿用项目 [debugLog] 风格，受全局开关控制）
    private func log(_ message: String) {
        #if DEBUG
        guard NetworkConfiguration.shared.enableLog else { return }
        print("[debugLog] NetworkClient \(message)")
        #endif
    }
}
