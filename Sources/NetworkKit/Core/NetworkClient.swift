//
//  NetworkClient.swift
//  NetworkKit
//
//  请求执行引擎：组包 / 变换 / 拦截 / 发送 / 重试 / 校验 / 解析
//

import Foundation
import SmartCodable

//MARK: - NetworkClient
/// 请求执行引擎。本身无状态（配置全部来自请求的 `configuration`），一般直接用 `shared`
public final class NetworkClient: @unchecked Sendable {
    //MARK: - 存储属性
    /// 单例实例
    public static let shared = NetworkClient()
    /// 请求体 / 查询参数编码器
    private let encoder = JSONEncoder()
    /// 每份配置对应一个下载并发限制器（按配置对象身份区分）
    private let downloadSemaphores = LockedValue<[ObjectIdentifier: AsyncSemaphore]>([:])

    /// 创建一个独立的执行引擎（通常不需要，用 `shared` 即可）
    public init() {}
}

//MARK: - PreparedRequest
private extension NetworkClient {
    /// 一次尝试组好的请求：拦截器改写后的 URLRequest + 变换前的原始请求体
    struct PreparedRequest {
        /// 实际发出的请求
        var urlRequest: URLRequest
        /// 参数编码后、任何改写之前的原始请求体
        let originalBody: Data?
    }
}

//MARK: - 发送
extension NetworkClient {
    /// 发送请求并返回完整响应（不解析模型）
    public func response<R: NetworkRequest>(for request: R) async throws -> NetworkResponse {
        guard request.runsInBackgroundTask else {
            return try await responseCore(request)
        }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.\(request.name)") {
            try await responseCore(request)
        }
    }

    /// 发送请求并按 envelope 拆壳、解析为返回模型
    public func send<R: NetworkRequest>(_ request: R) async throws -> R.ResponseModel {
        let response = try await response(for: request)
        let monitors = request.configuration.effectiveEventMonitors
        do {
            let model = try response.decode(R.ResponseModel.self)
            monitors.responseDidDecode(modelType: R.ResponseModel.self, error: nil, context: response.context)
            return model
        } catch {
            let networkError = NetworkError.normalize(error)
            monitors.responseDidDecode(modelType: R.ResponseModel.self, error: networkError, context: response.context)
            throw networkError
        }
    }
}

//MARK: - 发送管道
private extension NetworkClient {
    /// 核心流程：带重试地「组包 → 拦截 → 发送 → 响应拦截 → 校验状态码 → 变换响应体」
    func responseCore<R: NetworkRequest>(_ request: R) async throws -> NetworkResponse {
        let configuration = request.configuration
        let monitors = configuration.effectiveEventMonitors
        let policy = request.retryPolicy
        let startTime = Date()
        let descriptor = RequestDescriptor(
            name: request.name,
            host: request.host,
            path: request.path,
            method: request.method,
            timeout: request.timeout
        )
        var attempt = 0
        var lastPrepared: PreparedRequest?

        while true {
            // 组包：首发必组；重试时按策略决定重组还是复用上一次的最终请求
            var context = RequestContext(descriptor: descriptor, originalBody: lastPrepared?.originalBody, attempt: attempt, startTime: startTime)
            do {
                let prepared: PreparedRequest
                if let lastPrepared, policy.rebuildsRequestOnRetry == false {
                    prepared = lastPrepared
                } else {
                    var base = try buildBaseRequest(for: request, configuration: configuration)
                    context = RequestContext(descriptor: descriptor, originalBody: base.originalBody, attempt: attempt, startTime: startTime)
                    if let body = base.originalBody {
                        base.urlRequest.httpBody = try request.transformRequestBody(body)
                    }
                    try await runRequestInterceptors(&base.urlRequest, request: request, configuration: configuration, context: context)
                    prepared = base
                }
                lastPrepared = prepared

                monitors.requestWillSend(prepared.urlRequest, context: context)
                let (data, urlResponse) = try await configuration.session.data(for: prepared.urlRequest)
                var response = NetworkResponse(
                    data: data,
                    httpResponse: urlResponse as? HTTPURLResponse,
                    urlRequest: prepared.urlRequest,
                    context: context,
                    elapsed: Date().timeIntervalSince(startTime),
                    envelope: request.envelope,
                    decodingOptions: request.decodingOptions
                )
                try await runResponseInterceptors(&response, request: request, configuration: configuration)
                try validateStatusCode(of: response, acceptable: request.acceptableStatusCodes)
                response.data = try request.transformResponseBody(response.data, response: response.httpResponse)
                monitors.requestDidFinish(.success(response), context: context)
                return response
            } catch {
                let networkError = NetworkError.normalize(error)
                guard networkError.isCancelled == false,
                      attempt < policy.maxRetryCount,
                      policy.shouldRetry(networkError, attempt) else {
                    monitors.requestDidFinish(.failure(networkError), context: context)
                    throw networkError
                }
                attempt += 1
                let delay = policy.delay.interval(forRetry: attempt)
                monitors.requestWillRetry(after: networkError, delay: delay, context: context)
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        monitors.requestDidFinish(.failure(.cancelled), context: context)
                        throw NetworkError.cancelled
                    }
                }
            }
        }
    }

    /// 组装基础 URLRequest（拼 URL、编码参数、铺 header），不跑拦截器与变换
    func buildBaseRequest<R: NetworkRequest>(for request: R, configuration: NetworkConfiguration) throws -> PreparedRequest {
        guard var components = URLComponents(string: request.host + request.path) else {
            throw NetworkError.invalidURL
        }
        let queryOptions = configuration.queryEncoding

        // 查询参数：显式 query 类；或无请求体的方法即便传了 body 类参数也降级拼到 query
        var items: [URLQueryItem] = []
        switch request.task {
        case .query(let params):
            items += try QueryEncoder.queryItems(from: params, encoder: encoder, options: queryOptions)
        case .queryParameters(let dict):
            items += QueryEncoder.queryItems(from: dict, options: queryOptions)
        case .jsonBody(let params) where request.method.prefersBodyEncoding == false:
            items += try QueryEncoder.queryItems(from: params, encoder: encoder, options: queryOptions)
        case .jsonParameters(let dict) where request.method.prefersBodyEncoding == false,
             .formParameters(let dict) where request.method.prefersBodyEncoding == false:
            items += QueryEncoder.queryItems(from: dict, options: queryOptions)
        case .none, .jsonBody, .jsonParameters, .formParameters, .multipart, .rawBody:
            break
        }
        // urlParameters 始终附加，可与请求体共存
        if request.urlParameters.isEmpty == false {
            items += QueryEncoder.queryItems(from: request.urlParameters, options: queryOptions)
        }
        if items.isEmpty == false {
            components.queryItems = items
            components.percentEncodedQuery = QueryEncoder.percentEncodedQuery(of: components, options: queryOptions)
        }
        guard let url = components.url else { throw NetworkError.invalidURL }

        var urlRequest = URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue

        // header：配置默认头 → 参数承载方式决定的 Content-Type → 请求自定义头
        var headers = configuration.defaultHeaders
        var originalBody: Data?
        if request.method.prefersBodyEncoding {
            switch request.task {
            case .jsonBody(let params):
                originalBody = try encodeJSONBody(fromEncodable: params)
                headers["Content-Type"] = "application/json"
            case .jsonParameters(let dict):
                originalBody = try encodeJSONBody(fromDict: dict)
                headers["Content-Type"] = "application/json"
            case .formParameters(let dict):
                let formItems = QueryEncoder.queryItems(from: dict, options: queryOptions)
                originalBody = QueryEncoder.formBody(from: formItems, options: queryOptions)
                headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
            case .multipart(let form):
                originalBody = form.encoded()
                headers["Content-Type"] = form.contentType
            case .rawBody(let data, let contentType):
                originalBody = data
                if let contentType { headers["Content-Type"] = contentType }
            case .none, .query, .queryParameters:
                break
            }
        }
        for (key, value) in request.headers { headers[key] = value }
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = originalBody

        return PreparedRequest(urlRequest: urlRequest, originalBody: originalBody)
    }

    /// 执行请求拦截器（全局在前，请求自身在后）
    func runRequestInterceptors<R: NetworkRequest>(
        _ urlRequest: inout URLRequest,
        request: R,
        configuration: NetworkConfiguration,
        context: RequestContext
    ) async throws {
        let policy = request.globalInterceptorPolicy
        for interceptor in configuration.globalRequestInterceptors where policy.allows(interceptor) {
            try await interceptor.intercept(&urlRequest, context: context)
        }
        for interceptor in request.requestInterceptors {
            try await interceptor.intercept(&urlRequest, context: context)
        }
    }

    /// 执行响应拦截器（全局在前，请求自身在后）
    func runResponseInterceptors<R: NetworkRequest>(
        _ response: inout NetworkResponse,
        request: R,
        configuration: NetworkConfiguration
    ) async throws {
        let policy = request.globalInterceptorPolicy
        for interceptor in configuration.globalResponseInterceptors where policy.allows(interceptor) {
            try await interceptor.intercept(&response)
        }
        for interceptor in request.responseInterceptors {
            try await interceptor.intercept(&response)
        }
    }

    /// 校验 HTTP 状态码（不在可接受范围内视为 httpStatus 错误；非 HTTP 响应不校验）
    func validateStatusCode(of response: NetworkResponse, acceptable: Range<Int>) throws {
        guard let statusCode = response.statusCode else { return }
        guard acceptable.contains(statusCode) else {
            throw NetworkError.httpStatus(code: statusCode, data: response.data)
        }
    }
}

//MARK: - 编码辅助方法
private extension NetworkClient {
    /// 把 Encodable 结构体编码成 JSON 请求体
    func encodeJSONBody(fromEncodable value: Encodable) throws -> Data {
        do {
            return try encoder.encode(AnyEncodable(value))
        } catch {
            throw NetworkError.encoding(error)
        }
    }

    /// 把松散字典编码成 JSON 请求体
    func encodeJSONBody(fromDict dict: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: dict)
        } catch {
            throw NetworkError.encoding(error)
        }
    }
}

//MARK: - 下载并发
extension NetworkClient {
    /// 取出某份配置对应的下载并发限制器（首次使用时按该配置的 `maxConcurrentDownloads` 创建）
    func downloadSemaphore(for configuration: NetworkConfiguration) -> AsyncSemaphore {
        downloadSemaphores.withValue { table in
            let key = ObjectIdentifier(configuration)
            if let existing = table[key] { return existing }
            let semaphore = AsyncSemaphore(limit: configuration.maxConcurrentDownloads)
            table[key] = semaphore
            return semaphore
        }
    }
}
