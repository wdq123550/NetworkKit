//
//  NetworkKitTests.swift
//  NetworkKitTests
//
//  发送管道、拆壳解码、重试、拦截器、编码规则的行为测试
//

import Foundation
import Testing
import SmartCodable
@testable import NetworkKit

//MARK: - 测试模型
/// 普通返回模型
struct User: SmartCodableX, Equatable {
    var id: Int = 0
    var name: String = ""
}

/// 通用测试请求：所有属性都可在构造时指定
struct TestRequest<Model: SmartDecodable>: NetworkRequest {
    typealias ResponseModel = Model
    let configuration: NetworkConfiguration
    var path: String = "/echo"
    var method: HTTPMethod = .get
    var task: RequestTask = .none
    var urlParameters: [String: Any] = [:]
    var headers: [String: String] = [:]
    var retryPolicy: RetryPolicy = .none
    var envelope: ResponseEnvelope
    var requestInterceptors: [RequestInterceptor] = []
    var responseInterceptors: [ResponseInterceptor] = []
    var acceptableStatusCodes: Range<Int> = 200..<300
    var requestBodyTransform: (@Sendable (Data) throws -> Data)?
    var responseBodyTransform: (@Sendable (Data) throws -> Data)?
    var runsInBackgroundTask: Bool { false }

    init(configuration: NetworkConfiguration, envelope: ResponseEnvelope = ResponseEnvelope()) {
        self.configuration = configuration
        self.envelope = envelope
    }

    func transformRequestBody(_ body: Data) throws -> Data {
        try requestBodyTransform?(body) ?? body
    }

    func transformResponseBody(_ data: Data, response: HTTPURLResponse?) throws -> Data {
        try responseBodyTransform?(data) ?? data
    }
}

/// 记录调用次数的请求拦截器
struct CountingInterceptor: RequestInterceptor {
    let counter: LockedValue<Int>
    let contexts: LockedValue<[RequestContext]>

    func intercept(_ request: inout URLRequest, context: RequestContext) async throws {
        counter.withValue { $0 += 1 }
        contexts.withValue { $0.append(context) }
        request.setValue("\(context.attempt)", forHTTPHeaderField: "X-Attempt")
    }
}

/// 把响应体整体替换的响应拦截器
struct ReplacingResponseInterceptor: ResponseInterceptor {
    let replacement: Data

    func intercept(_ response: inout NetworkResponse) async throws {
        response.data = replacement
    }
}

//MARK: - 拆壳与解码
@Suite("拆壳与解码")
struct EnvelopeDecodingTests {
    @Test("标准外层壳：code == 0 成功并按 dataPath 解析")
    func standardEnvelope() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 0, "message": "ok", "data": ["id": 7, "name": "Tom"]]))
        }
        let user = try await TestRequest<User>(configuration: configuration).send()
        #expect(user == User(id: 7, name: "Tom"))
    }

    @Test("业务失败：抛 business 并带上 code 与 message")
    func businessFailure() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 1001, "message": "登录失效"]))
        }
        await #expect(throws: NetworkError.self) {
            try await TestRequest<User>(configuration: configuration).send()
        }
        do {
            _ = try await TestRequest<User>(configuration: configuration).send()
        } catch let error as NetworkError {
            #expect(error.businessCode == 1001)
            #expect(error.businessMessage == "登录失效")
        }
    }

    @Test("字符串业务码：\"0\" 与 0 视为相等，\"OK\" 可直接比较")
    func stringCode() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { request in
            if request.url?.path == "/string-zero" {
                return (200, [:], StubURLProtocol.json(["code": "0", "data": ["id": 1, "name": "a"]]))
            }
            return (200, [:], StubURLProtocol.json(["status": "OK", "data": ["id": 2, "name": "b"]]))
        }
        var zero = TestRequest<User>(configuration: configuration)
        zero.path = "/string-zero"
        #expect(try await zero.send().id == 1)

        var ok = TestRequest<User>(configuration: configuration, envelope: ResponseEnvelope(codeKey: "status", dataPath: "data", isSuccess: { $0 == "OK" }))
        ok.path = "/string-ok"
        #expect(try await ok.send().id == 2)
    }

    @Test("布尔业务码：success == true")
    func boolCode() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["success": true, "data": ["id": 3, "name": "c"]]))
        }
        let request = TestRequest<User>(configuration: configuration, envelope: ResponseEnvelope(codeKey: "success", dataPath: "data", isSuccess: { $0 == true }))
        #expect(try await request.send().id == 3)
    }

    @Test("顶层直接是数组：跳过拆壳整包解析")
    func topLevelArray() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json([["id": 1, "name": "a"], ["id": 2, "name": "b"]]))
        }
        let users = try await TestRequest<[User]>(configuration: configuration).send()
        #expect(users.map(\.id) == [1, 2])
    }

    @Test("parsesRawWhenCodeMissing：没有壳时整包解析")
    func rawWhenCodeMissing() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["id": 9, "name": "raw"]))
        }
        let request = TestRequest<User>(configuration: configuration, envelope: ResponseEnvelope(codeKey: "error_code", dataPath: "data", parsesRawWhenCodeMissing: true))
        #expect(try await request.send().id == 9)
    }

    @Test("NetworkResponse 用标准 JSONDecoder 解析 Codable")
    func codableDecode() async throws {
        struct Plain: Decodable, Equatable { let id: Int; let name: String }
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 5, "name": "plain"]]))
        }
        let response = try await TestRequest<EmptyDecodable>(configuration: configuration).response()
        let model = try response.decode(Plain.self, decoder: JSONDecoder())
        #expect(model == Plain(id: 5, name: "plain"))
        #expect(response.statusCode == 200)
        #expect(response.context.attempt == 0)
    }

    @Test("ResponseCode 相等与字面量")
    func responseCodeEquality() {
        #expect(ResponseCode.int(0) == ResponseCode.string("0"))
        #expect(ResponseCode.string("OK") == "OK")
        #expect(ResponseCode.bool(true) == "true")
        #expect(ResponseCode.int(1) != ResponseCode.bool(true))
        #expect(ResponseCode(raw: NSNumber(value: true)) == .bool(true))
        #expect(ResponseCode(raw: 200) == 200)
        #expect(ResponseCode(raw: NSNull()) == nil)
    }
}

//MARK: - 状态码与重试
@Suite("状态码与重试")
struct StatusAndRetryTests {
    @Test("非 2xx 抛 httpStatus；自定义可接受范围可放行")
    func statusCodes() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (404, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]]))
        }
        do {
            _ = try await TestRequest<User>(configuration: configuration).send()
            Issue.record("应当抛出 httpStatus")
        } catch let error as NetworkError {
            #expect(error.statusCode == 404)
        }
        var lenient = TestRequest<User>(configuration: configuration)
        lenient.acceptableStatusCodes = 200..<500
        #expect(try await lenient.send().id == 1)
    }

    @Test("重试时重新组包：拦截器每次都跑、attempt 递增；用尽后抛最后一次错误")
    func retryRebuildsRequest() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            throw URLError(.networkConnectionLost)
        }
        let counter = LockedValue(0)
        let contexts = LockedValue<[RequestContext]>([])
        var request = TestRequest<User>(configuration: configuration)
        request.retryPolicy = RetryPolicy(maxRetryCount: 2, delay: .none)
        request.requestInterceptors = [CountingInterceptor(counter: counter, contexts: contexts)]
        do {
            _ = try await request.send()
            Issue.record("应当失败")
        } catch let error as NetworkError {
            guard case .transport = error else {
                Issue.record("应为 transport，实际 \(error)")
                return
            }
        }
        #expect(counter.value == 3)
        #expect(contexts.value.map(\.attempt) == [0, 1, 2])
        #expect(StubURLProtocol.requests(for: host).map { $0.value(forHTTPHeaderField: "X-Attempt") } == ["0", "1", "2"])
    }

    @Test("业务错误默认不重试")
    func noRetryOnBusiness() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 500, "message": "boom"]))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.retryPolicy = RetryPolicy(maxRetryCount: 3, delay: .none)
        _ = try? await request.send()
        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test("transientShouldRetry 对 5xx 重试并在成功时返回")
    func retryOnServerError() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        let hits = LockedValue(0)
        StubURLProtocol.register(host: host) { _ in
            let count = hits.withValue { $0 += 1; return $0 }
            if count < 3 { return (503, [:], Data()) }
            return (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "ok"]]))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.retryPolicy = RetryPolicy(maxRetryCount: 5, delay: .none, shouldRetry: { RetryPolicy.transientShouldRetry($0, $1) })
        let user = try await request.send()
        #expect(user.name == "ok")
        #expect(hits.value == 3)
    }

    @Test("指数退避间隔")
    func exponentialDelay() {
        let delay = RetryDelay.exponential(initial: 1, multiplier: 2, maximum: 5)
        #expect(delay.interval(forRetry: 1) == 1)
        #expect(delay.interval(forRetry: 2) == 2)
        #expect(delay.interval(forRetry: 3) == 4)
        #expect(delay.interval(forRetry: 4) == 5)
    }
}

//MARK: - 拦截器与变换
@Suite("拦截器与变换")
struct InterceptorTests {
    @Test("签明文发密文：transformRequestBody 加密，HMAC 拦截器按 originalBody 签名")
    func signPlaintextSendCiphertext() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        let secret = "secret-key"
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]]))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.method = .post
        request.path = "/api/v2/chat"
        request.urlParameters = ["api_key": "k", "timestamp": 123]
        request.task = .jsonParameters(["hello": "world"])
        request.requestBodyTransform = { Data($0.reversed()) }
        request.requestInterceptors = [HMACSignatureInterceptor(secret: secret)]
        _ = try await request.send()

        let sent = try #require(StubURLProtocol.requests(for: host).first)
        let plaintext = StubURLProtocol.json(["hello": "world"])
        #expect(sent.httpBody == Data(plaintext.reversed()))

        // 用旧的 EncryptHelper 口径独立算一遍，确认签名对的是明文
        var reference = sent
        reference.httpBody = plaintext
        let expected = EncryptHelper.getSignature(request: reference, requestBody: String(decoding: plaintext, as: UTF8.self), signatureKey: secret)
        #expect(sent.value(forHTTPHeaderField: "X-Signature") == expected)
        #expect(sent.url?.query == "api_key=k&timestamp=123")
    }

    @Test("transformResponseBody 在状态码校验后解密，随后正常拆壳")
    func transformResponse() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        let plaintext = StubURLProtocol.json(["code": 0, "data": ["id": 42, "name": "dec"]])
        StubURLProtocol.register(host: host) { _ in
            (200, [:], Data(plaintext.reversed()))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.responseBodyTransform = { Data($0.reversed()) }
        #expect(try await request.send().id == 42)
    }

    @Test("响应拦截器可改写响应体，且能看到非 2xx")
    func responseInterceptorRewrites() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in
            (200, [:], Data("garbage".utf8))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.responseInterceptors = [ReplacingResponseInterceptor(replacement: StubURLProtocol.json(["code": 0, "data": ["id": 8, "name": "r"]]))]
        #expect(try await request.send().id == 8)
    }

    @Test("全局拦截器策略：excluding 只跳过指定类型")
    func globalInterceptorPolicy() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        let counter = LockedValue(0)
        configuration.globalRequestInterceptors = [
            CountingInterceptor(counter: counter, contexts: LockedValue([])),
            HMACSignatureInterceptor(secret: "s")
        ]
        StubURLProtocol.register(host: host) { _ in
            (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]]))
        }
        struct Excluding: NetworkRequest {
            typealias ResponseModel = User
            let configuration: NetworkConfiguration
            var path: String { "/x" }
            var globalInterceptorPolicy: GlobalInterceptorPolicy { .excluding(HMACSignatureInterceptor.self) }
            var runsInBackgroundTask: Bool { false }
        }
        _ = try await Excluding(configuration: configuration).send()
        #expect(counter.value == 1)
        #expect(StubURLProtocol.requests(for: host).first?.value(forHTTPHeaderField: "X-Signature") == nil)
    }

    @Test("拦截器抛出的自定义错误包进 custom")
    func customErrorWrapped() async throws {
        struct MyError: Error {}
        struct Throwing: RequestInterceptor {
            func intercept(_ request: inout URLRequest, context: RequestContext) async throws { throw MyError() }
        }
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], Data()) }
        var request = TestRequest<User>(configuration: configuration)
        request.requestInterceptors = [Throwing()]
        do {
            _ = try await request.send()
            Issue.record("应当失败")
        } catch let error as NetworkError {
            #expect(error.underlyingError is MyError)
        }
    }
}

//MARK: - 参数编码
@Suite("参数编码")
struct EncodingTests {
    @Test("query：Bool 字面量、数组重复键、+ 转义、按键排序")
    func queryEncoding() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]])) }
        var request = TestRequest<User>(configuration: configuration)
        request.task = .queryParameters(["flag": true, "ids": [1, 2], "q": "a+b c", "n": 3])
        _ = try await request.send()
        let query = StubURLProtocol.requests(for: host).first?.url?.query
        #expect(query == "flag=true&ids=1&ids=2&n=3&q=a%2Bb%20c")
    }

    @Test("GET 带 jsonBody 时降级拼到 query")
    func getDowngradesBodyToQuery() async throws {
        struct Params: Encodable { let page: Int; let size: Int }
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]])) }
        var request = TestRequest<User>(configuration: configuration)
        request.task = .jsonBody(Params(page: 1, size: 20))
        _ = try await request.send()
        let sent = StubURLProtocol.requests(for: host).first
        #expect(sent?.url?.query == "page=1&size=20")
        #expect(sent?.httpBody == nil)
    }

    @Test("表单请求体与 Content-Type")
    func formBody() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]])) }
        var request = TestRequest<User>(configuration: configuration)
        request.method = .post
        request.task = .formParameters(["b": "2", "a": "x y"])
        _ = try await request.send()
        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
        #expect(String(decoding: sent.httpBody ?? Data(), as: UTF8.self) == "a=x%20y&b=2")
    }

    @Test("multipart 请求体与 boundary")
    func multipartBody() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]])) }
        var form = MultipartFormData(boundary: "B")
        form.append("tom", name: "user")
        form.append(Data([0x01, 0x02]), name: "file", fileName: "a.bin", mimeType: "application/octet-stream")
        var request = TestRequest<User>(configuration: configuration)
        request.method = .post
        request.task = .multipart(form)
        _ = try await request.send()
        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"user\"\r\n\r\ntom\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test("rawBody 可指定 Content-Type，请求头覆盖默认头")
    func rawBodyContentType() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        StubURLProtocol.register(host: host) { _ in (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]])) }
        var request = TestRequest<User>(configuration: configuration)
        request.method = .post
        request.task = .rawBody(Data([0xFF]), contentType: "application/octet-stream")
        request.headers = ["X-Crypto": "des"]
        _ = try await request.send()
        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(sent.value(forHTTPHeaderField: "X-Crypto") == "des")
        #expect(sent.httpBody == Data([0xFF]))
    }
}

//MARK: - 事件监听
@Suite("事件监听")
struct MonitorTests {
    /// 记录事件的监听者
    final class RecordingMonitor: NetworkEventMonitor, @unchecked Sendable {
        let events = LockedValue<[String]>([])
        func requestWillSend(_ urlRequest: URLRequest, context: RequestContext) { events.withValue { $0.append("send:\(context.attempt)") } }
        func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext) { events.withValue { $0.append("retry") } }
        func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext) {
            events.withValue { $0.append(result.isSuccess ? "finish:ok" : "finish:fail") }
        }
        func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext) {
            events.withValue { $0.append(error == nil ? "decode:ok" : "decode:fail") }
        }
    }

    @Test("完整生命周期事件顺序")
    func lifecycle() async throws {
        let host = StubURLProtocol.makeHost()
        let configuration = StubURLProtocol.makeConfiguration(host: host)
        let monitor = RecordingMonitor()
        configuration.eventMonitors = [monitor]
        let hits = LockedValue(0)
        StubURLProtocol.register(host: host) { _ in
            let count = hits.withValue { $0 += 1; return $0 }
            if count == 1 { throw URLError(.timedOut) }
            return (200, [:], StubURLProtocol.json(["code": 0, "data": ["id": 1, "name": "x"]]))
        }
        var request = TestRequest<User>(configuration: configuration)
        request.retryPolicy = RetryPolicy(maxRetryCount: 1, delay: .none)
        _ = try await request.send()
        #expect(monitor.events.value == ["send:0", "retry", "send:1", "finish:ok", "decode:ok"])
    }
}

//MARK: - Result 辅助
private extension Result {
    /// 是否为成功
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
