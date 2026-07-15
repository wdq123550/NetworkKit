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
    /// 文件下载并发限制器（默认最多 3 个并发）
    private let downloadLimiter = DownloadLimiter(maxConcurrent: 3)
}

// MARK: - 方法
extension NetworkClient {
    /// 发送请求并解析为返回模型
    public func send<R: NetworkRequest>(_ request: R) async throws -> R.ResponseModel {
        guard request.runsInBackgroundTask else {
            return try await sendCore(request)
        }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.send.\(request.path)") {
            try await sendCore(request)
        }
    }

    /// 发送请求的核心流程
    private func sendCore<R: NetworkRequest>(_ request: R) async throws -> R.ResponseModel {
        let urlRequest = try await buildURLRequest(for: request)
        let (data, response) = try await performWithRetry(urlRequest, request: request)
        try await runResponseInterceptors(data: data, response: response, urlRequest: urlRequest, request: request)
        try validateHTTPStatus(response: response, data: data)
        return try decode(data: data, request: request)
    }

    /// 发送请求并返回原始响应数据（不走 SmartCodable 解析，适合自定义解析的接口）
    public func sendForData<R: NetworkRequest>(_ request: R) async throws -> Data {
        guard request.runsInBackgroundTask else {
            return try await sendForDataCore(request)
        }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.sendForData.\(request.path)") {
            try await sendForDataCore(request)
        }
    }

    /// 返回原始数据的核心流程（含拦截器与状态码校验，仅跳过 SmartCodable 解析）
    private func sendForDataCore<R: NetworkRequest>(_ request: R) async throws -> Data {
        let urlRequest = try await buildURLRequest(for: request)
        let (data, response) = try await performWithRetry(urlRequest, request: request)
        try await runResponseInterceptors(data: data, response: response, urlRequest: urlRequest, request: request)
        try validateHTTPStatus(response: response, data: data)
        return data
    }

    /// 发送请求并返回原始响应数据 + HTTP 响应元信息（不走 SmartCodable 解析）。
    /// 成功（2xx）时可从返回的 response 取状态码；非 2xx 会抛 NetworkError.httpStatus（其 code 即状态码）。
    public func sendForDataResponse<R: NetworkRequest>(_ request: R) async throws -> (data: Data, response: HTTPURLResponse?) {
        guard request.runsInBackgroundTask else {
            return try await sendForDataResponseCore(request)
        }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.sendForDataResponse.\(request.path)") {
            try await sendForDataResponseCore(request)
        }
    }

    /// 返回原始数据 + HTTP 响应的核心流程（含拦截器与状态码校验，仅跳过 SmartCodable 解析）
    private func sendForDataResponseCore<R: NetworkRequest>(_ request: R) async throws -> (data: Data, response: HTTPURLResponse?) {
        let urlRequest = try await buildURLRequest(for: request)
        let (data, response) = try await performWithRetry(urlRequest, request: request)
        try await runResponseInterceptors(data: data, response: response, urlRequest: urlRequest, request: request)
        try validateHTTPStatus(response: response, data: data)
        return (data, response as? HTTPURLResponse)
    }

    /// 组装 URLRequest（拼 URL、编码参数、铺 header、跑请求拦截器）
    private func buildURLRequest<R: NetworkRequest>(for request: R) async throws -> URLRequest {
        guard var components = URLComponents(string: request.host + request.path) else {
            throw NetworkError.invalidURL
        }

        // 查询参数：显式 query/queryParameters；或无 body 的方法即便传了 body 参数也降级拼到 query
        var items: [URLQueryItem] = []
        switch request.task {
        case .query(let params):
            items += try queryItems(fromEncodable: params)
        case .queryParameters(let dict):
            items += queryItems(fromDict: dict)
        case .jsonBody(let params) where request.method.prefersBodyEncoding == false:
            items += try queryItems(fromEncodable: params)
        case .jsonParameters(let dict) where request.method.prefersBodyEncoding == false:
            items += queryItems(fromDict: dict)
        case .none, .jsonBody, .jsonParameters, .rawBody:
            break
        }
        // urlParameters 始终附加，可与请求体共存
        if !request.urlParameters.isEmpty {
            items += queryItems(fromDict: request.urlParameters)
        }
        if !items.isEmpty {
            components.queryItems = items
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
        // 实际解析路径：默认走 dataPath，遇到「无壳」场景会被改成整包解析
        var effectiveDataPath = envelope.dataPath

        // 有业务码字段才做成功判定与拆包；否则直接整包解析
        if let codeKey = envelope.codeKey {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let codeFieldExists = envelope.value(forKeyPath: codeKey, in: object) != nil
            if codeFieldExists {
                let code = envelope.resolveCode(in: object)
                guard envelope.isSuccess(code) else {
                    let message = envelope.resolveMessage(in: object, isFailure: true)
                    log("❌ 业务失败 code=\(code.map(String.init) ?? "nil") message=\(message ?? "")")
                    throw NetworkError.business(code: code, message: message, raw: data)
                }
            } else if envelope.parsesRawWhenCodeMissing {
                // 没有外层壳：忽略 dataPath，直接整包解析
                effectiveDataPath = nil
            } else {
                // 业务码字段缺失，仍按成功判定一次（保持严格行为）
                guard envelope.isSuccess(nil) else {
                    let message = envelope.resolveMessage(in: object, isFailure: true)
                    throw NetworkError.business(code: nil, message: message, raw: data)
                }
            }
        }

        guard let model = R.ResponseModel.deserialize(from: data, designatedPath: effectiveDataPath) else {
            throw NetworkError.decoding(message: "SmartCodable 解析为 \(R.ResponseModel.self) 失败", raw: data)
        }
        log("✅ 解析成功 \(R.ResponseModel.self)")
        return model
    }
}

// MARK: - 文件下载
extension NetworkClient {
    /// 下载文件到指定本地路径
    /// - Parameters:
    ///   - urlString: 文件完整地址
    ///   - destination: 保存到的本地文件 URL（已存在会被覆盖）
    ///   - headers: 额外请求头（不叠加全局默认头，下载通常无需）
    ///   - timeout: 超时（秒）；nil 则用会话默认
    ///   - runsInBackgroundTask: 是否在后台任务保护下执行；默认 true
    /// - Returns: 下载完成后的本地文件 URL
    @discardableResult
    public func download(
        from urlString: String,
        to destination: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil,
        runsInBackgroundTask: Bool = true
    ) async throws -> URL {
        guard runsInBackgroundTask else {
            return try await performDownload(from: urlString, to: destination, headers: headers, timeout: timeout)
        }
        return try await BackgroundTaskRunner.run(name: "NetworkKit.download") {
            try await performDownload(from: urlString, to: destination, headers: headers, timeout: timeout)
        }
    }

    /// 实际下载逻辑（受并发限制器约束，最多 3 个并发）
    private func performDownload(
        from urlString: String,
        to destination: URL,
        headers: [String: String],
        timeout: TimeInterval?
    ) async throws -> URL {
        guard let url = URL(string: urlString) else { throw NetworkError.invalidURL }

        await downloadLimiter.acquire()
        defer { Task { await downloadLimiter.release() } }

        var urlRequest = URLRequest(url: url)
        if let timeout { urlRequest.timeoutInterval = timeout }
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        do {
            let (tempURL, response) = try await NetworkConfiguration.shared.session.download(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NetworkError.httpStatus(code: http.statusCode, data: Data())
            }
            // 确保目录存在；已有同名文件先删除再移动
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            log("⬇️ 下载完成 \(url.absoluteString)")
            return destination
        } catch let error as NetworkError {
            throw error
        } catch {
            throw mapTransportError(error)
        }
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

// MARK: - DownloadLimiter
/// 下载并发限制器：用 actor + 续体实现的简单信号量，限制同时进行的下载数量
actor DownloadLimiter {
    /// 最大并发数
    private let maxConcurrent: Int
    /// 当前占用数
    private var current = 0
    /// 等待队列
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    /// 申请一个下载名额（满则挂起等待）
    func acquire() async {
        if current < maxConcurrent {
            current += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 释放一个下载名额（有等待者则直接放行）
    func release() {
        if waiters.isEmpty {
            current = max(0, current - 1)
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
