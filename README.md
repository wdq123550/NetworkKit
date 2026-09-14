# NetworkKit

一套**协议化**的 Swift 网络请求框架，灵感来自 OC 时代的 YTKNetwork，用 Swift 现代特性重写：

- **底座**：原生 `URLSession`，零额外网络依赖
- **并发**：全程 `async/await`，所有类型 `Sendable`，为 Swift 6 严格并发做好准备
- **解析**：接入 [SmartCodable](https://github.com/iAmMccc/SmartCodable) 做强容错 JSON → 模型解析；也可以拿 `NetworkResponse` 用标准 `JSONDecoder` 或手工解析
- **参数**：`Codable` 结构体 / 松散字典 / 表单 / multipart / 原始 `Data`
- **协议化（而非继承）**：任意类型遵守 `NetworkRequest` 协议即获得完整请求能力。一个接口的全部信息（主机、路径、方法、参数、超时、重试、拦截器、外层字段映射、返回模型）都收敛在一个对象里，**看接口直接看这个类型**
- **多后端**：每个后端一份 `NetworkConfiguration`（主机 / 默认头 / 签名拦截器 / 外层壳），请求只需指向它
- **可扩展的管道**：请求体变换、响应体变换、带上下文的请求拦截器、可改写响应的响应拦截器、事件监听——「签明文、发密文」「DES 加密响应」「统一日志埋点」都不需要绕开框架

> 协议 + 协议扩展默认实现，等价于「基类写默认、子类按需重写」：不重写就走配置默认，要改哪个就重写哪个属性。

---

## 一、环境要求

| 项目 | 要求 |
| --- | --- |
| iOS / macOS | iOS 17.0+ / macOS 14.0+ |
| Swift | 5.9+ |
| Xcode | 15+ |
| 依赖 | SmartCodable 7.0.0+ |

---

## 二、安装（Swift Package Manager）

### 方式 A：Xcode 图形界面

1. `File > Add Package Dependencies...`
2. 输入本仓库地址，选择版本规则 `Up to Next Major`（建议锁 tag，不要跟 `main` 分支）
3. 把 `NetworkKit` 加到你的 App Target

### 方式 B：在 `Package.swift` 中声明

```swift
dependencies: [
    .package(url: "https://github.com/wdq123550/NetworkKit.git", from: "2.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "NetworkKit", package: "NetworkKit")
        ]
    )
]
```

> NetworkKit 内部已依赖 SmartCodable，你无需单独再加。

---

## 三、三步上手

### 第 1 步：App 启动时做一次配置

```swift
import NetworkKit

func setupNetwork() {
    let config = NetworkConfiguration.shared
    config.baseHost = "https://api.example.com"          // 默认主机
    config.defaultTimeout = 15                            // 默认超时（秒）
    config.enableLog = true                               // DEBUG 下把请求生命周期打到控制台

    // 后端字段是下划线风格时，设一次即可（默认空集合＝按属性名原样匹配）
    config.defaultDecodingOptions = [.key(.fromSnakeCase)]

    // 后端统一返回壳的字段映射（按你司后端字段名改）
    config.defaultEnvelope = ResponseEnvelope(
        codeKey: "code",        // 业务码字段名
        messageKey: "message",  // 提示语字段名
        dataPath: "data",       // 真正内容所在路径
        isSuccess: { $0 == 0 }  // code == 0 视为成功
    )
}
```

### 第 2 步：定义返回模型（遵守 SmartDecodable / SmartCodableX）

```swift
import SmartCodable

struct UserInfo: SmartCodableX {   // 只需解析也可用 SmartDecodable
    var id: Int = 0
    var name: String = ""
    var avatar: String = ""
}
```

> 单个模型作 `ResponseModel` 时遵守 `SmartDecodable` 就够了；但要把数组直接当 `ResponseModel`（如 `[Goods]`），元素类型**必须**遵守 `SmartCodableX`，详见「五、外层字段映射」里的「列表模型的协议约束」。

### 第 3 步：定义一个请求 = 一个遵守 `NetworkRequest` 的类型

```swift
import NetworkKit

struct LoginAPI: NetworkRequest {
    typealias ResponseModel = UserInfo   // 返回模型

    var path = "/user/login"
    var method: HTTPMethod = .post
    var task: RequestTask { .jsonBody(Body(phone: phone, code: code)) }

    let phone: String
    let code: String

    struct Body: Codable {
        let phone: String
        let code: String
    }
}
```

调用——一行 `async/await`：

```swift
do {
    let user = try await LoginAPI(phone: "13800000000", code: "1234").send()
    print("登录成功：\(user.name)")
} catch {
    print("登录失败：\(error.localizedDescription)")
}
```

---

## 四、发送管道（先看懂这张图，后面每一节都是它的一个环节）

每次尝试（含重试）都会完整走一遍：

```
组 URL + 编码参数            task / urlParameters / headers
   ↓
transformRequestBody         请求体整体变换（如 DES 加密）；变换前的明文保留在 context.originalBody
   ↓
请求拦截器  全局 → 自身        RequestInterceptor.intercept(&urlRequest, context:)  加签名 / token
   ↓
URLSession 发出
   ↓
响应拦截器  全局 → 自身        ResponseInterceptor.intercept(&response)  可改写 response.data；能看到 401 / 500
   ↓
校验 HTTP 状态码             acceptableStatusCodes，默认 200..<300
   ↓
transformResponseBody        响应体整体变换（如 DES 解密 / 解压），只对状态码合格的响应执行
   ↓
NetworkResponse              data / httpResponse / elapsed / context   ← response() 在这里返回
   ↓
按 envelope 拆壳 + SmartCodable 解析   ← send() 在这里返回 ResponseModel
```

任一环节抛错都会先经过重试判定（见「八、重试」），最终以 `NetworkError` 抛出。事件监听（见「十、事件监听」）在「发出前」「重试前」「结束」「解析后」四个点回调。

---

## 五、请求参数

参数通过 `task` 属性返回一个 `RequestTask`：

```swift
public enum RequestTask {
    case none                                   // 无参数
    case query(Encodable)                       // 结构体 → URL query
    case jsonBody(Encodable)                    // 结构体 → JSON body
    case queryParameters([String: Any])         // 松散字典 → URL query
    case jsonParameters([String: Any])          // 松散字典 → JSON body
    case formParameters([String: Any])          // 松散字典 → x-www-form-urlencoded 表单
    case multipart(MultipartFormData)           // 文件上传
    case rawBody(Data, contentType: String?)    // 原始 body 兜底（可顺带指定 Content-Type）
}
```

```swift
// 结构体 → JSON body
var task: RequestTask { .jsonBody(Body(phone: phone, code: code)) }

// 字典 → query
var task: RequestTask { .queryParameters(["page": 1, "size": 20, "onlyMine": true, "ids": [3, 4]]) }
//   → ?ids=3&ids=4&onlyMine=true&page=1&size=20   （Bool 是 true/false，数组默认重复键，键按字母排序）

// 表单
var task: RequestTask { .formParameters(["grant_type": "password", "username": name]) }

// 文件上传
var task: RequestTask {
    var form = MultipartFormData()
    form.append("avatar", name: "type")
    form.append(imageData, name: "file", fileName: "a.jpg", mimeType: "image/jpeg")
    return .multipart(form)
}

// 已经自己编码 / 加密好的原始数据
var task: RequestTask { .rawBody(encryptedData, contentType: "application/octet-stream") }
```

> GET / HEAD / OPTIONS 等无请求体的方法，即使传了 `jsonBody` / `jsonParameters` / `formParameters`，也会自动降级拼到 URL query。

### query 与 body 同时存在

`task` 是「请求体」与「GET 查询」二选一的载体。如果某个接口（常见于网关签名接口）需要**同时**带 URL query 参数和 JSON body，用独立的 `urlParameters` 属性，它始终拼到 URL，且与 body 共存：

```swift
struct ChatAPI: NetworkRequest {
    typealias ResponseModel = ChatResult
    var path = "/api/v2/chat"
    var method: HTTPMethod = .post
    var urlParameters: [String: Any] { ["api_key": apiKey, "timestamp": ts] }   // 始终拼到 URL
    var task: RequestTask { .jsonBody(Body(messages: messages)) }               // 请求体
}
```

### 编码规则可调

```swift
NetworkConfiguration.shared.queryEncoding.arrayEncoding = .brackets   // ids[]=1&ids[]=2；还有 .indexed / .commaSeparated
NetworkConfiguration.shared.queryEncoding.boolEncoding = .numeric     // 1 / 0
NetworkConfiguration.shared.queryEncoding.encodesPlusSign = true      // 值里的 + 转成 %2B（默认开，防止服务端当空格）
NetworkConfiguration.shared.queryEncoding.sortsKeys = true            // 按键排序（默认开，签名与日志稳定）
```

---

## 六、外层字段映射（适配不同后端）

不同后端的统一返回壳字段名各不相同，用 `ResponseEnvelope` 描述：

```swift
public struct ResponseEnvelope {
    var codeKey: String?              // 业务码字段名，如 "code" / "status" / "error_code"
    var messageKey: String?           // 提示语字段名
    var errorMessageKey: String?      // 失败时的错误字段名（不配则回退 messageKey）
    var dataPath: String?             // 内容数据路径，如 "data" / "result.list"
    var parsesRawWhenCodeMissing: Bool// 找不到业务码字段时是否整包解析
    var isSuccess: (ResponseCode?) -> Bool  // 成功判定，默认 code == 0
}
```

- **配置默认**：`NetworkConfiguration.defaultEnvelope`
- **单请求重写**：在该请求里重写 `envelope`

```swift
struct LegacyAPI: NetworkRequest {
    typealias ResponseModel = SomeModel
    var path = "/legacy/info"
    // 这个老接口：成功码 200，字段叫 status / msg / result
    var envelope: ResponseEnvelope {
        ResponseEnvelope(codeKey: "status", messageKey: "msg", dataPath: "result", isSuccess: { $0 == 200 })
    }
}
```

### 业务码不止是整数：`ResponseCode`

后端可能返回 `0`、`"0"`、`"OK"`、`true`。业务码统一收成 `ResponseCode`（`.int` / `.string` / `.bool`），比较时 `.int(0) == .string("0")`，并支持字面量，所以下面的写法都成立：

```swift
isSuccess: { $0 == 0 }        // 0 或 "0"
isSuccess: { $0 == "OK" }
isSuccess: { $0 == true }     // success: true
isSuccess: { [0, 200].contains($0 ?? -1) }
```

`NetworkError.business(code:message:raw:)` 里的 `code` 也是 `ResponseCode?`，用 `code?.intValue` / `code?.stringValue` 取值。

### 无外层壳 / 只改路径 / 有时有壳有时没壳

```swift
var envelope: ResponseEnvelope { .raw }                                          // 整包就是数据，恒成功
var envelope: ResponseEnvelope { configuration.defaultEnvelope.replacingDataPath("data.content") }  // 只改路径
var envelope: ResponseEnvelope {
    ResponseEnvelope(codeKey: "error_code", messageKey: "error_message", dataPath: "data",
                     parsesRawWhenCodeMissing: true)                             // 没壳就整包解析
}
```

`dataPath`、`codeKey`、`messageKey` 都支持 `a.b.c` 点路径，内容埋在第几层都能取到。

### 顶层直接返回数组的接口

后端直接返回 `[{...}, {...}]` 时**不需要任何额外配置**：框架识别出顶层不是 JSON 对象，自动跳过拆壳与业务码判定，整包解析成 `ResponseModel`。

### 列表模型的协议约束

把数组直接当返回模型（如 `typealias ResponseModel = [Goods]`）时，元素类型 `Goods` **必须遵守 `SmartCodableX`**，只遵守 `SmartDecodable` 会编译不过。原因：SmartCodable 只提供了 `extension Array: SmartCodableX where Element: SmartCodableX`。`SmartCodableX` 是 `SmartDecodable & SmartEncodable` 的 typealias，多实现一个编码能力即可。

> SmartCodable 7.0.0 里**没有**名为 `SmartCodable` 的协议，实际可用的只有 `SmartDecodable`、`SmartEncodable`、`SmartCodableX` 三个。

---

## 七、拿原始响应：`response()` 与 `NetworkResponse`

不想让框架解析、或者返回结构特殊（字段里嵌 JSON 字符串、顶层数组里再嵌数组……）时，用 `response()` 拿完整响应自己处理。host / query / 签名拦截器 / 重试 / 后台任务 / 状态码校验 / 事件监听全部照常生效，**只是不解析模型**：

```swift
struct LegacyListRequest: NetworkRequest {
    // 不写 typealias ResponseModel，默认 EmptyDecodable
    var path = "/legacy/list"
}

let response = try await LegacyListRequest().response()
response.data            // 原始 Data（经过响应拦截器与 transformResponseBody 之后）
response.statusCode      // 200
response.header("ETag")
response.elapsed         // 耗时（秒，含重试）
response.context         // 描述、原始请求体、第几次尝试
response.utf8String
let json = try response.jsonObject()                        // 任意 JSON 对象
let user = try response.decode(User.self)                   // 事后再按本请求的 envelope 解成 SmartCodable 模型
let plain = try response.decode(Plain.self, decoder: JSONDecoder())   // 或者用标准 JSONDecoder 解 Codable
```

`send()` 就是 `response()` 之后紧跟一次 `decode(ResponseModel.self)`。只要 `Data` 的话还有更短的 `sendForData()`。

---

## 八、重试

```swift
public struct RetryPolicy {
    var maxRetryCount: Int                      // 最大重试次数
    var delay: RetryDelay                       // .none / .constant(秒) / .exponential(initial:multiplier:maximum:jitter:)
    var rebuildsRequestOnRetry: Bool            // 重试时是否重新组包（默认 true）
    var shouldRetry: (NetworkError, Int) -> Bool// 自定义是否重试
}
```

```swift
// 配置默认：最多重试 2 次，每次间隔 1 秒（默认只对传输错误 / 超时重试，业务错误不重试）
NetworkConfiguration.shared.defaultRetryPolicy = RetryPolicy(maxRetryCount: 2, retryDelay: 1)

// 指数退避 + 对 5xx / 429 / 408 也重试
var retryPolicy: RetryPolicy {
    RetryPolicy(maxRetryCount: 3,
                delay: .exponential(initial: 0.5, multiplier: 2, maximum: 8, jitter: 0.2),
                shouldRetry: { RetryPolicy.transientShouldRetry($0, $1) })
}

// 完全自定义
var retryPolicy: RetryPolicy {
    RetryPolicy(maxRetryCount: 3, delay: .constant(0.5)) { error, retried in
        error.isTimeout && retried < 2
    }
}
```

**重试时默认会重新组包**：重新编码参数、重跑 `transformRequestBody` 与所有请求拦截器。这样签名里的 `timestamp` 每次都是新的，不会因为复用第一次的请求被网关按「时间戳过期」拒掉。确认接口幂等且不想重算时，把 `rebuildsRequestOnRetry` 设为 `false`。取消（`.cancelled`）永不重试。

---

## 九、拦截器与变换钩子

### 请求拦截器（带上下文）

```swift
public protocol RequestInterceptor: Sendable {
    func intercept(_ request: inout URLRequest, context: RequestContext) async throws
}

public struct RequestContext {
    let descriptor: RequestDescriptor   // id / name / host / path / method / timeout
    let originalBody: Data?             // 参数编码后、任何改写前的原始请求体
    let attempt: Int                    // 0 首发，1 第一次重试……
    let startTime: Date
}
```

```swift
struct AuthInterceptor: RequestInterceptor {
    func intercept(_ request: inout URLRequest, context: RequestContext) async throws {
        if let token = await TokenStore.shared.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}
```

### 响应拦截器（可改写响应）

```swift
public protocol ResponseInterceptor: Sendable {
    func intercept(_ response: inout NetworkResponse) async throws   // 改 response.data 即可
}
```

它跑在 HTTP 状态码校验**之前**，所以能看到 401 / 500，适合「登录失效统一跳转」这类逻辑；只是想对成功响应解密 / 解压，用下面的 `transformResponseBody` 更直接。

### 变换钩子（单请求最短路径）

```swift
protocol NetworkRequest {
    func transformRequestBody(_ body: Data) throws -> Data                      // 组包后、拦截器前
    func transformResponseBody(_ data: Data, response: HTTPURLResponse?) throws -> Data  // 状态码校验后、拆壳前
}
```

### 典型场景：签明文、发密文、收密文

后端要求：请求体 DES 加密，但 `X-Signature` 要按加密**前**的明文算；响应也是 DES 密文。过去这种接口只能绕开框架手工拆包，现在：

```swift
struct SupplementRequest: NetworkRequest {
    typealias ResponseModel = SupplementResult

    var host: String { AppConfig.supplementHost }
    var path: String { "/ISO1801612" }
    var method: HTTPMethod { .post }
    var headers: [String: String] { ["X-Crypto": "des"] }
    var urlParameters: [String: Any] { ["api_key": AppConfig.apiKey, "timestamp": Int(Date().timeIntervalSince1970 * 1000)] }
    var task: RequestTask { .jsonParameters(payload) }

    // 1. 请求体整体 DES 加密（明文仍保留在 context.originalBody）
    func transformRequestBody(_ body: Data) throws -> Data {
        guard let encrypted = EncryptHelper.encryptDESBinary(data: body, base64DESKey: AppConfig.desKey) else {
            throw CryptoError.encryptFailed
        }
        return encrypted
    }
    // 2. 签名拦截器默认读 originalBody（明文）
    var requestInterceptors: [RequestInterceptor] {
        [HMACSignatureInterceptor(secret: AppConfig.apiSecret)]
    }
    // 3. 响应体 DES 解密后，正常按 error_code / data 拆壳
    func transformResponseBody(_ data: Data, response: HTTPURLResponse?) throws -> Data {
        guard let decrypted = EncryptHelper.decryptDESBinary(data: data, base64DESKey: AppConfig.desKey) else {
            throw CryptoError.decryptFailed
        }
        return decrypted
    }
    var envelope: ResponseEnvelope {
        ResponseEnvelope(codeKey: "error_code", messageKey: "error_message", dataPath: "data")
    }
}
```

`error_code != 0` 自动变成 `NetworkError.business`，`data` 自动解成 `SupplementResult`，业务代码里不再有一行手工判码取值。

### 内置：`HMACSignatureInterceptor`

```swift
HMACSignatureInterceptor(
    headerName: "X-Signature",          // 默认
    secret: "…",
    algorithm: .sha256,                 // 默认；还有 .md5 / .sha1 / .sha512 …
    bodySource: .originalBody,          // 默认签明文；.currentBody 签当前请求体；.none 不带 body
    outputEncoding: .base64URLSafe,     // 默认；还有 .base64 / .hex
    material: { request, body in        // 默认 "\(METHOD)\n\(path)\n\(query)\n\(body)"
        "\(request.httpMethod ?? "")\n\(request.url?.path ?? "")\n\(request.url?.query ?? "")\n\(body)"
    }
)
```

密钥、字段名、主机等业务信息仍由宿主 App 传入；库里只有算法。

### 注册与执行顺序

```swift
// 对该配置下所有请求生效
config.globalRequestInterceptors = [AuthInterceptor()]
config.globalResponseInterceptors = [SessionExpiredInterceptor()]

// 只对单个请求生效
var requestInterceptors: [RequestInterceptor] { [HMACSignatureInterceptor(secret: secret)] }

// 特殊接口跳过全局拦截器
var ignoreGlobalInterceptors: Bool { true }                                            // 全跳
var globalInterceptorPolicy: GlobalInterceptorPolicy { .excluding(AuthInterceptor.self) }  // 只跳某几个
```

执行顺序：全局拦截器 → 单请求拦截器。

---

## 十、事件监听（统一日志 / 埋点）

不要在每个请求外面手写「发起 / 成功耗时 / 失败原因」。实现 `NetworkEventMonitor`（每个方法都有空默认实现，只写关心的）挂到配置上：

```swift
struct AppNetworkLogger: NetworkEventMonitor {
    func requestWillSend(_ urlRequest: URLRequest, context: RequestContext) {
        log("➡️ \(context.descriptor.name) \(urlRequest.url!)", tag: "Net")
    }
    func requestWillRetry(after error: NetworkError, delay: TimeInterval, context: RequestContext) {
        log("🔁 \(context.descriptor.name) 第 \(context.attempt + 1) 次重试 \(error.localizedDescription)", tag: "Net")
    }
    func requestDidFinish(_ result: Result<NetworkResponse, NetworkError>, context: RequestContext) {
        switch result {
        case .success(let response): log("✅ \(context.descriptor.name) \(response.statusCode ?? 0) \(response.elapsed)s", tag: "Net")
        case .failure(let error):    log("❌ \(context.descriptor.name) \(error.localizedDescription)", tag: "Net", status: .failure)
        }
    }
    func responseDidDecode(modelType: Any.Type, error: NetworkError?, context: RequestContext) { … }
    func downloadDidFinish(from url: URL, result: Result<URL, NetworkError>, elapsed: TimeInterval) { … }
}

NetworkConfiguration.shared.eventMonitors = [AppNetworkLogger()]
```

只想在控制台看：`config.enableLog = true`（DEBUG 下等价于挂一份内置的 `ConsoleEventMonitor`，也可以自己 `ConsoleEventMonitor(printsResponseBody: true)` 挂上去）。

---

## 十一、多后端：一份 `NetworkConfiguration` 对应一个后端

一个 App 往往同时对接业务网关、配置中心、审核服务、第三方时间服务，它们的主机、签名、外层壳各不相同。与其全塞进 `shared` 再让每个请求 `ignoreGlobalInterceptors`，不如每个后端一份配置：

```swift
enum Backends {
    static let goCloud: NetworkConfiguration = {
        let config = NetworkConfiguration()
        config.baseHost = AppConfig.goCloudHost
        config.defaultTimeout = 30
        config.globalRequestInterceptors = [HMACSignatureInterceptor(secret: AppConfig.goCloudSecret)]
        config.defaultEnvelope = ResponseEnvelope(codeKey: "error_code", messageKey: "error_message", dataPath: "data", parsesRawWhenCodeMissing: true)
        config.eventMonitors = [AppNetworkLogger()]
        return config
    }()

    static let serverTime: NetworkConfiguration = {
        let config = NetworkConfiguration()
        config.baseHost = AppConfig.serverTimeHost
        config.defaultEnvelope = ResponseEnvelope(codeKey: "success", messageKey: nil, dataPath: nil, isSuccess: { $0 == 1 })
        return config
    }()
}

struct ChatAPI: NetworkRequest {
    typealias ResponseModel = ChatResult
    var configuration: NetworkConfiguration { Backends.goCloud }   // ← 主机、签名、壳都跟着来了
    var path: String { "/api/v2/chat" }
    var method: HTTPMethod { .post }
    var task: RequestTask { .jsonBody(body) }
}
```

请求本身只剩 path 和参数。

---

## 十二、文件下载与后台任务

### 文件下载

```swift
let localURL = try await NetworkClient.shared.download(
    from: "https://cdn.example.com/a.png",
    to: saveURL,
    progress: { progress in
        print(progress.bytesReceived, progress.totalBytes ?? -1, progress.fraction ?? 0)
    }
)
```

- 并发上限由 `configuration.maxConcurrentDownloads` 控制（默认 3），超出的排队等待
- 自动建目录、覆盖同名文件；失败自动清理临时文件
- 传了 `progress` 走字节流下载并回调进度（后台线程）；不传走系统整文件下载，效率更高
- 通过 `configuration:` 参数指定用哪份配置的会话 / 默认头 / 事件监听
- 断点续传暂不支持

### 后台任务保护

用户何时切到后台不可控，所以 `runsInBackgroundTask` **默认就是 `true`**：框架会用 `UIApplication.beginBackgroundTask` 给每个请求 / 下载包一层后台保护，系统到期时自动结束（非 UIKit 平台自动空操作）。个别确实不需要的接口可以显式关掉：

```swift
var runsInBackgroundTask: Bool { false }
```

> `UIApplication.shared` 在 App Extension 里不可用，本库目前只面向主 App target。

---

## 十三、模型解析：解码选项与诊断

### 解码选项 `SmartDecodingOption`

```swift
// 配置级：对该配置下所有请求生效
NetworkConfiguration.shared.defaultDecodingOptions = [.key(.fromSnakeCase)]

// 单请求：个别接口字段风格不一致时重写
var decodingOptions: Set<SmartDecodingOption> { [.key(.firstLetterLower)] }
```

| 选项 | 说明 |
| --- | --- |
| `.key(.fromSnakeCase)` | 下划线转驼峰，`user_name` → `userName` |
| `.key(.firstLetterLower)` / `.key(.firstLetterUpper)` | 首字母大小写转换 |
| `.date(...)` | 日期策略，如 `.date(.iso8601)`、`.date(.secondsSince1970)` |
| `.data(.base64)` | `Data` 策略 |
| `.float(...)` | 浮点数策略，处理 NaN / 无穷 |

每种策略只能设一个，重复设置以最后一个为准。

### 解析诊断（进程级）

SmartCodable 的容错是**静默**的：字段类型不符会自动转换、字段缺失会填默认值，都不报错。后端偷偷改了字段名时，你拿到的是一堆默认值，日志上却显示「解析成功」。打开诊断即可逐字段看到发生了什么，并且 `NetworkError.decoding` 会带上最近一次诊断文本：

```swift
NetworkConfiguration.isDecodingDiagnosticsEnabled = true        // 开发期打开（静态属性：SmartSentinel 是进程级设施）
NetworkConfiguration.decodingDiagnosticsHandler = { log($0, tag: "Decode") }   // 不设则 DEBUG 下 print
```

> ⚠️ 底层是 SmartCodable 的 `SmartSentinel`，属于**进程级**设施。打开后 App 内所有经 SmartCodable 的解析都会产生诊断日志，**不限于本库发起的请求**。

---

## 十四、错误处理

所有入口（`send` / `response` / `sendForData` / `download`）抛出的错误都归一化成 `NetworkError`：

```swift
public enum NetworkError: Error {
    case invalidURL                                          // URL 非法
    case encoding(Error)                                     // 参数编码失败
    case transport(Error)                                    // 底层网络错误
    case timeout                                             // 超时
    case cancelled                                           // 取消（Task 取消 / URLError.cancelled）
    case httpStatus(code: Int, data: Data)                   // HTTP 状态码不在可接受范围
    case business(code: ResponseCode?, message: String?, raw: Data)   // 业务失败
    case decoding(message: String, raw: Data, diagnostics: String?)   // 模型解析失败
    case custom(Error)                                       // 拦截器 / 变换钩子抛出的自定义错误
}
```

便捷属性：`isCancelled` / `isTimeout` / `statusCode` / `businessCode` / `businessMessage` / `responseData` / `underlyingError`。

```swift
do {
    let user = try await LoginAPI(phone: phone, code: code).send()
} catch let error as NetworkError {
    switch error {
    case .business(let code, let message, _):
        showToast(message ?? "请求失败（\(code?.description ?? "-")）")
    case .timeout:
        showToast("网络超时，请重试")
    case .cancelled:
        break
    default:
        showToast(error.localizedDescription)   // 已内置中文描述
    }
}
```

---

## 十五、`NetworkRequest` 全部可重写项

| 属性 / 方法 | 说明 | 默认值 |
| --- | --- | --- |
| `configuration` | 归属的配置（主机、默认头、拦截器、会话、监听等的来源） | `NetworkConfiguration.shared` |
| `name` | 请求名字，日志用 | 类型名 |
| `host` | 主机地址（含 scheme） | `configuration.baseHost` |
| `path` | 接口路径 | 必填 |
| `method` | HTTP 方法 | `.get` |
| `task` | 请求参数（body 或 GET query 二选一） | `.none` |
| `urlParameters` | 始终拼到 URL 的查询参数（可与 body 共存） | `[:]` |
| `headers` | 请求头（叠加在配置默认头之上） | `[:]` |
| `timeout` | 超时（秒） | `configuration.defaultTimeout` |
| `cachePolicy` | URL 缓存策略 | `.useProtocolCachePolicy` |
| `retryPolicy` | 重试策略 | `configuration.defaultRetryPolicy` |
| `acceptableStatusCodes` | 可接受的 HTTP 状态码范围 | `configuration.defaultAcceptableStatusCodes`（200..<300） |
| `requestInterceptors` | 该请求专属请求拦截器 | `[]` |
| `responseInterceptors` | 该请求专属响应拦截器 | `[]` |
| `globalInterceptorPolicy` | 对全局拦截器的启用策略 `.all` / `.none` / `.excluding(...)` | 按 `ignoreGlobalInterceptors` |
| `ignoreGlobalInterceptors` | 全跳全局拦截器的简写 | `false` |
| `envelope` | 外层字段映射与成功判定 | `configuration.defaultEnvelope` |
| `decodingOptions` | 模型解码选项 | `configuration.defaultDecodingOptions` |
| `runsInBackgroundTask` | 是否在后台任务保护下执行 | `true` |
| `transformRequestBody(_:)` | 组包后、拦截器前变换请求体 | 原样返回 |
| `transformResponseBody(_:response:)` | 状态码校验后、拆壳前变换响应体 | 原样返回 |
| `response()` | 发送并返回 `NetworkResponse` | 内置实现 |
| `send()` | 发送并解析为 `ResponseModel` | 内置实现 |
| `sendForData()` | `response().data` 的简写 | 内置实现 |

---

## 十六、`NetworkConfiguration` 一览

| 属性 | 说明 |
| --- | --- |
| `baseHost` | 默认主机 |
| `defaultHeaders` | 默认请求头（默认 `Content-Type: application/json`） |
| `defaultTimeout` | 默认超时 |
| `defaultEnvelope` | 默认外层字段映射 |
| `defaultDecodingOptions` | 默认模型解码选项 |
| `defaultRetryPolicy` | 默认重试策略 |
| `defaultAcceptableStatusCodes` | 默认可接受状态码范围 |
| `queryEncoding` | query / 表单编码选项 |
| `globalRequestInterceptors` / `globalResponseInterceptors` | 全局拦截器 |
| `eventMonitors` | 事件监听 |
| `enableLog` | DEBUG 下把生命周期打到控制台 |
| `session` | 底层 `URLSession` |
| `maxConcurrentDownloads` | 下载并发上限 |
| `NetworkConfiguration.isDecodingDiagnosticsEnabled`（静态） | 解析诊断开关（进程级） |
| `NetworkConfiguration.decodingDiagnosticsHandler`（静态） | 解析诊断输出出口 |

`shared` 是默认实例；`NetworkConfiguration()` 可以随便建，见「十一、多后端」。所有属性应在 App 启动时配置好，运行期不要频繁改动。

---

## 十七、加解密工具 `EncryptHelper`

与公司网关配套的几个纯函数，业务密钥由宿主传入：

| 方法 | 说明 |
| --- | --- |
| `encodeRequestBody(data:desKey:)` | 明文 → DES → Base64 字符串（UTF-8 明文 key） |
| `encryptDESBinary(data:base64DESKey:)` / `decryptDESBinary(...)` | DES 二进制加解密（URL-safe Base64 编码的 key） |
| `getSignature(request:requestBody:signatureKey:)` | 与 `HMACSignatureInterceptor` 默认口径一致的 HMAC-SHA256 签名 |
| `encodeBase64URLSafeString(data:)` / `decodeBase64URLSafeString(_:)` | Base64 URL-safe 编解码 |

以及 `Data.enCrypt / deCrypt(algorithm:keyData:)`（AES / DES / 3DES …）、`Data.digest(_:key:)`、`String.md5 / sha256 …`。

---

## 十八、完整示例

```swift
import NetworkKit
import SmartCodable

// 1. 模型（要用作 [Article] 列表模型，必须遵守 SmartCodableX）
struct Article: SmartCodableX {
    var id: Int = 0
    var title: String = ""
    var content: String = ""
}

// 2. 列表请求
struct ArticleListAPI: NetworkRequest {
    typealias ResponseModel = [Article]
    var path = "/articles"
    var task: RequestTask { .queryParameters(["page": page, "size": 20]) }
    let page: Int
}

// 3. 详情请求（路径参数）
struct ArticleDetailAPI: NetworkRequest {
    typealias ResponseModel = Article
    var path: String { "/articles/\(id)" }
    let id: Int
}

// 4. 调用
func loadData() async {
    do {
        let list = try await ArticleListAPI(page: 1).send()
        let first = try await ArticleDetailAPI(id: list[0].id).send()
        print(first.title)
    } catch let error as NetworkError {
        print(error.localizedDescription)
    } catch {}
}
```

---

## 附：网络状态监听 `NetworkObserver`

```swift
import NetworkKit

// App 启动时开启监听（仅需一次）
NetworkObserver.shared.beginObservation()

// 读取状态（@Observable，可直接在 SwiftUI 中观察，或用 Perceptions / Observations 在逻辑层监听）
NetworkObserver.shared.isNetworkAvailable
NetworkObserver.shared.networkType        // .wifi / .cellular(.g5) / .wired / .noConnection …
NetworkObserver.shared.isVPNActive
NetworkObserver.shared.isExpensive        // 蜂窝 / 热点
NetworkObserver.shared.isConstrained      // 低数据模式
NetworkObserver.shared.enableLog = false  // 关掉 DEBUG 状态变化日志
```

---

## 从 1.x 迁移

| 1.x | 2.x |
| --- | --- |
| `RequestInterceptor.intercept(_ request: inout URLRequest)` | 多了 `context:` 参数，`context.originalBody` 是明文请求体 |
| `ResponseInterceptor.intercept(data:response:for:)`（只读） | `intercept(_ response: inout NetworkResponse)`，可改写 `response.data` |
| `sendForDataResponse()` → `(data, response)` | `response()` → `NetworkResponse`（旧方法保留但已标记弃用） |
| `ResponseEnvelope.isSuccess: (Int?) -> Bool` | `(ResponseCode?) -> Bool`；`{ $0 == 0 }` 写法不变 |
| `NetworkError.business(code: Int?, …)` | `code: ResponseCode?`，取整数用 `code?.intValue` |
| `NetworkError.decoding(message:raw:)` | 多了 `diagnostics:` |
| 未知错误被包成 `.transport` | 拦截器 / 钩子抛出的自定义错误包成 `.custom` |
| `RetryPolicy.retryDelay: TimeInterval` | `delay: RetryDelay`；`RetryPolicy(maxRetryCount:retryDelay:)` 便捷初始化保留 |
| `NetworkConfiguration.enableDecodingDiagnostics` / `decodingDiagnosticsHandler`（实例） | 改为静态 `isDecodingDiagnosticsEnabled` / `decodingDiagnosticsHandler` |
| `NetworkConfiguration` 是 `@Observable` 单例 | 普通类，可多实例；请求通过 `configuration` 指定 |
| `.rawBody(Data)` | `.rawBody(Data, contentType: String? = nil)`，旧写法兼容 |
| 手写签名拦截器 | 直接用 `HMACSignatureInterceptor` |
| 手动 `sendForData` + 解密 + 判 `error_code` | `transformResponseBody` 解密 + `envelope` 判码，走 `send()` |
