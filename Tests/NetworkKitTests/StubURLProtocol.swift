//
//  StubURLProtocol.swift
//  NetworkKitTests
//
//  测试用的 URLProtocol 桩：按主机名分发到各测试注册的处理闭包，测试之间互不干扰、可并行
//

import Foundation
@testable import NetworkKit

//MARK: - StubURLProtocol
/// 拦截所有请求并交给按主机注册的处理闭包
final class StubURLProtocol: URLProtocol {
    //MARK: - Handler
    /// 处理闭包：收到请求，返回 HTTP 状态码、响应头与响应体，或抛错模拟传输失败
    typealias Handler = @Sendable (URLRequest) throws -> (statusCode: Int, headers: [String: String], body: Data)

    //MARK: - 存储属性
    /// 主机名 → 处理闭包
    private static let handlers = LockedValue<[String: Handler]>([:])
    /// 主机名 → 收到的全部请求（供断言拦截器 / 重试行为）
    private static let recordedRequests = LockedValue<[String: [URLRequest]]>([:])
}

//MARK: - 方法
extension StubURLProtocol {
    /// 为某个主机注册处理闭包
    static func register(host: String, handler: @escaping Handler) {
        handlers.withValue { $0[host] = handler }
        recordedRequests.withValue { $0[host] = [] }
    }

    /// 取出某主机收到的全部请求
    static func requests(for host: String) -> [URLRequest] {
        recordedRequests.value[host] ?? []
    }

    /// 生成一个仅本测试使用的随机主机名
    static func makeHost() -> String {
        "https://\(UUID().uuidString.lowercased()).test"
    }

    /// 生成一份走本桩的 NetworkConfiguration
    static func makeConfiguration(host: String) -> NetworkConfiguration {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let configuration = NetworkConfiguration()
        configuration.baseHost = host
        configuration.session = URLSession(configuration: sessionConfiguration)
        return configuration
    }

    /// 把 JSON 对象编码成响应体
    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}

//MARK: - URLProtocol
extension StubURLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let scheme = url.scheme, let hostName = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let hostKey = "\(scheme)://\(hostName)"
        // URLSession 会把 httpBody 转成 httpBodyStream，这里读回来便于断言
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.readAll(from: stream)
        }
        Self.recordedRequests.withValue { $0[hostKey, default: []].append(recorded) }

        guard let handler = Self.handlers.value[hostKey] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let result = try handler(recorded)
            let response = HTTPURLResponse(url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1", headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// 把输入流读完
    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
