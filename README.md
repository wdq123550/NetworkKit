# NetworkKit

一套**协议化**的 iOS 网络请求框架，灵感来自 OC 时代的 YTKNetwork，但用 Swift 现代特性重写：

- **底座**：原生 `URLSession`，零额外网络依赖
- **并发**：全程 `async/await`，告别闭包与代理回调
- **解析**：接入 [SmartCodable](https://github.com/iAmMccc/SmartCodable) 做强容错 JSON → 模型解析，支持全局/单请求两级解码选项与字段级解析诊断
- **参数**：用 `Codable` 结构体或松散字典，自动编码成 JSON body / URL query
- **协议化（而非继承）**：任意类型遵守 `NetworkRequest` 协议即获得完整请求能力。一个接口的全部信息（主机、路径、方法、参数、超时、重试、拦截器、外层字段映射、返回模型）都收敛在一个对象里，**看接口直接看这个类型**
- **多后端兼容**：通过可配置的「外层字段映射」适配不同后端的 `code/message/data` 字段名与成功判定

> 协议 + 协议扩展默认实现，等价于「基类写默认、子类按需重写」：不重写就走全局默认，要改哪个就重写哪个属性。

---

## 一、环境要求

| 项目 | 要求 |
| --- | --- |
| iOS | 17.0+ |
| Swift | 5.9+ |
| Xcode | 15+ |
| 依赖 | SmartCodable 7.0.0+ |

---

## 二、安装（Swift Package Manager）

### 方式 A：Xcode 图形界面

1. `File > Add Package Dependencies...`
2. 输入本仓库地址，选择版本规则 `Up to Next Major`
3. 把 `NetworkKit` 加到你的 App Target

### 方式 B：在 `Package.swift` 中声明

```swift
dependencies: [
    .package(url: "<本仓库地址>", from: "1.0.0")
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

### 第 1 步：App 启动时做一次全局配置

```swift
import NetworkKit

func setupNetwork() {
    let config = NetworkConfiguration.shared
    config.baseHost = "https://api.example.com"          // 默认主机
    config.defaultTimeout = 15                            // 默认超时（秒）
    config.enableLog = true                              // DEBUG 下打印请求日志
    config.enableDecodingDiagnostics = true              // DEBUG 下打印字段级解析诊断（开发期建议开）

    // 后端字段是下划线风格时，全局设一次即可（默认空集合＝按属性名原样匹配）
    config.defaultDecodingOptions = [.key(.fromSnakeCase)]

    // 配置后端统一返回壳的字段映射（按你司后端字段名改）
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

    // 请求参数结构体（自动转 JSON）
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

## 四、请求参数：结构体 / 字典 / 单值都支持

参数通过 `task` 属性返回一个 `RequestTask`：

```swift
public enum RequestTask {
    case none                              // 无参数
    case query(Encodable)                  // 结构体 → URL query
    case jsonBody(Encodable)               // 结构体 → JSON body
    case queryParameters([String: Any])    // 松散字典 → URL query（免定义结构体）
    case jsonParameters([String: Any])     // 松散字典 → JSON body（免定义结构体）
    case rawBody(Data)                     // 原始 body 兜底
}
```

示例：

```swift
// 结构体 → JSON body
var task: RequestTask { .jsonBody(Body(phone: phone, code: code)) }

// 字典/单值 → query，免定义结构体
var task: RequestTask { .queryParameters(["page": 1, "size": 20]) }

// 整个 body 是裸数组/裸值，也能直接走 jsonBody
var task: RequestTask { .jsonBody([1, 2, 3]) }
```

> GET / HEAD 等无请求体的方法，即使传了 `jsonBody` / `jsonParameters`，也会自动降级拼到 URL query。

### query 与 body 同时存在

`task` 是「请求体」与「GET 查询」二选一的载体。如果某个接口（常见于网关签名接口）需要 **同时** 带 URL query 参数和 JSON body，用独立的 `urlParameters` 属性，它始终拼到 URL，且与 body 共存：

```swift
struct ChatAPI: NetworkRequest {
    typealias ResponseModel = ChatResult
    var path = "/api/v2/chat"
    var method: HTTPMethod = .post
    // 始终拼到 URL 的查询参数（与 body 共存）
    var urlParameters: [String: Any] { ["api_key": apiKey, "timestamp": ts] }
    // 请求体
    var task: RequestTask { .jsonBody(Body(messages: messages)) }
}
```

---

## 五、外层字段映射（适配不同后端）

不同后端的统一返回壳字段名各不相同，用 `ResponseEnvelope` 描述：

```swift
public struct ResponseEnvelope {
    var codeKey: String?         // 业务码字段名，如 "code" / "status"
    var messageKey: String?      // 提示语字段名，如 "message" / "msg"
    var errorMessageKey: String? // 失败时的错误字段名（不配则回退 messageKey）
    var dataPath: String?        // 内容数据路径，如 "data" / "result.list"
    var isSuccess: (Int?) -> Bool // 成功判定，默认 code == 0
}
```

- **全局默认**：在 `NetworkConfiguration.shared.defaultEnvelope` 设置。
- **单请求重写**：某个接口的成功码/字段名特殊时，在该请求里重写 `envelope`：

```swift
struct LegacyAPI: NetworkRequest {
    typealias ResponseModel = SomeModel
    var path = "/legacy/info"

    // 这个老接口：成功码 200，字段叫 status / msg / result
    var envelope: ResponseEnvelope {
        ResponseEnvelope(
            codeKey: "status",
            messageKey: "msg",
            dataPath: "result",
            isSuccess: { $0 == 200 }
        )
    }
}
```

- **无外层壳**（整包就是数据）：用内置的 `.raw`：

```swift
var envelope: ResponseEnvelope { .raw }
```

返回的内容数据会通过 SmartCodable 的 `designatedPath`（即 `dataPath`）自动定位并解析成 `ResponseModel`；`dataPath` 为空时则整包解析。解析时套用的键名/日期等策略见「五点五、模型解析：解码选项与诊断」。

### 内容数据的层级（一层 / 多层都支持）

`dataPath`、`codeKey`、`messageKey` 都支持用 `.` 表示的「点路径」，所以无论真正内容埋在第几层都能取到：

```swift
// 一层就能拿到：{ "code": 0, "data": {...} }
dataPath: "data"

// 两层：{ "code": 0, "data": { "content": {...} } }
dataPath: "data.content"

// 更深：{ "code": 0, "result": { "list": [...] } }
dataPath: "result.list"
```

### 外层壳「有时有、有时没有」

如果同一套接口里，有的返回 `{code, data}` 包了壳、有的直接返回裸数据，把 `parsesRawWhenCodeMissing` 设为 `true`：响应里能找到 `codeKey` 字段就正常拆包+成功判定，找不到就忽略 `dataPath`、整包解析成模型。

```swift
var envelope: ResponseEnvelope {
    ResponseEnvelope(
        codeKey: "error_code",
        messageKey: "error_message",
        dataPath: "data",
        parsesRawWhenCodeMissing: true   // 没有外层壳时直接整包解析
    )
}
```

如果大多数接口是一层、个别接口多一层，不必重写整套 `envelope`，用 `replacingDataPath` 只改路径、其余继承全局默认：

```swift
struct ProfileAPI: NetworkRequest {
    typealias ResponseModel = Profile
    var path = "/user/profile"
    // 仅这个接口内容多包了一层 content
    var envelope: ResponseEnvelope {
        NetworkConfiguration.shared.defaultEnvelope.replacingDataPath("data.content")
    }
}
```

### 顶层直接返回数组的接口

有些接口不带 `{code, data}` 外层壳，直接返回 `[{...}, {...}]` 这样的顶层数组。这类接口**不需要任何额外配置**：框架会识别出顶层不是 JSON 对象，自动跳过拆壳与业务码判定，整包解析成 `ResponseModel`。

```swift
// 后端直接返回：[{"id":1,...},{"id":2,...}]
struct GoodsListAPI: NetworkRequest {
    typealias ResponseModel = [Goods]
    var path = "/goods/list"
}
```

> 早期版本在全局配置了 `codeKey` 时会把这种响应误判为业务失败并抛 `NetworkError.business`，现已修复。

### 列表模型的协议约束

把数组直接当返回模型（如 `typealias ResponseModel = [Goods]`）时，元素类型 `Goods` **必须遵守 `SmartCodableX`**，只遵守 `SmartDecodable` 会编译不过：

```swift
struct Goods: SmartCodableX {    // 可用作 [Goods]
    var id: Int = 0
    var title: String = ""
}

struct Coupon: SmartDecodable {  // 单独用没问题，但用作 [Coupon] 会编译报错
    var id: Int = 0
}
```

原因：SmartCodable 7.0.0 只提供了 `extension Array: SmartCodableX where Element: SmartCodableX`，并没有为 `Element: SmartDecodable` 的数组提供协议遵守。`SmartCodableX` 是 `SmartDecodable & SmartEncodable` 的 typealias，多实现一个编码能力即可。

> 另外，SmartCodable 7.0.0 里**没有**名为 `SmartCodable` 的协议（官方 README 部分示例是过时写法），实际可用的只有 `SmartDecodable`、`SmartEncodable`、`SmartCodableX` 三个。单个模型（非数组）作 `ResponseModel` 时，遵守 `SmartDecodable` 就够了。

---

## 五点五、模型解析：解码选项与诊断

### 解码选项 `SmartDecodingOption`

解析时的键名、日期、`Data`、浮点数策略通过 `Set<SmartDecodingOption>` 配置，分全局与单请求两级：

```swift
// 全局：App 启动配置里设一次，对所有请求生效
NetworkConfiguration.shared.defaultDecodingOptions = [.key(.fromSnakeCase)]

// 单请求：个别接口字段风格不一致时重写
struct OrderDetailAPI: NetworkRequest {
    typealias ResponseModel = Order
    var path = "/order/detail"
    // 这个老接口是首字母大写的字段名
    var decodingOptions: Set<SmartDecodingOption> { [.key(.firstLetterLower)] }
}
```

可选项：

| 选项 | 说明 |
| --- | --- |
| `.key(.fromSnakeCase)` | 下划线转驼峰，`user_name` → `userName` |
| `.key(.firstLetterLower)` | 首字母转小写，`UserName` → `userName` |
| `.key(.firstLetterUpper)` | 首字母转大写 |
| `.date(...)` | 日期策略，传 `JSONDecoder.DateDecodingStrategy`，如 `.date(.iso8601)`、`.date(.secondsSince1970)` |
| `.data(.base64)` | `Data` 策略，传 `JSONDecoder.SmartDataDecodingStrategy` |
| `.float(...)` | 浮点数策略，传 `JSONDecoder.NonConformingFloatDecodingStrategy`，处理 NaN / 无穷 |

- 默认是**空集合**，即按模型属性名原样匹配 JSON 字段。
- 每种策略只能设一个，重复设置以最后一个为准（如同时给两个 `.key(...)`，只有最后一个生效）。
- 后端整体是下划线风格时，在启动配置里设一次 `[.key(.fromSnakeCase)]` 即可，不用给每个模型写 `mappingForKey`。

### 解析诊断 `enableDecodingDiagnostics`

SmartCodable 的容错是**静默**的：字段类型不符会自动转换、字段缺失会填默认值，都不报错。后端偷偷改了字段名时，你拿到的是一堆默认值，日志上却显示「解析成功」。打开诊断开关即可逐字段看到发生了什么：

```swift
NetworkConfiguration.shared.enableDecodingDiagnostics = true   // 开发期打开
```

输出形如（仅 DEBUG 下打印，前缀 `[debugLog] NetworkKit 解析诊断`）：

```
[debugLog] NetworkKit 解析诊断
age 期望 Int 实际 String，已自动转换
email 字段不存在，使用默认值
```

> 排查「模型字段莫名为空」这类问题时特别有用：建议开发期常开，发布前关掉。

---

## 六、拦截器（请求前 / 返回后）

```swift
// 请求拦截器：发请求前改 header、加 token、加签名
struct AuthInterceptor: RequestInterceptor {
    func intercept(_ request: inout URLRequest) async throws {
        if let token = await TokenStore.shared.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

// 返回拦截器：统一日志、登录失效处理、解密等
struct LoggingInterceptor: ResponseInterceptor {
    func intercept(data: Data, response: URLResponse, for request: URLRequest) async throws {
        // ... 统一埋点 / 日志 / 失效跳转
    }
}
```

注册：

```swift
// 全局生效（对所有请求）
NetworkConfiguration.shared.globalRequestInterceptors = [AuthInterceptor()]
NetworkConfiguration.shared.globalResponseInterceptors = [LoggingInterceptor()]
```

```swift
// 只对单个请求生效
struct UploadAPI: NetworkRequest {
    typealias ResponseModel = EmptyModel
    var path = "/upload"
    var requestInterceptors: [RequestInterceptor] { [SignInterceptor()] }
}
```

特殊接口（如登录、刷新 token）想跳过全局拦截器：

```swift
var ignoreGlobalInterceptors: Bool { true }
```

执行顺序：全局拦截器 → 单请求拦截器。

---

## 七、重试机制

```swift
public struct RetryPolicy {
    var maxRetryCount: Int                       // 最大重试次数
    var retryDelay: TimeInterval                 // 重试间隔（秒）
    var shouldRetry: (Error, Int) -> Bool        // 自定义是否重试
}
```

全局默认不重试（`.none`）。按需配置：

```swift
// 全局：失败最多重试 2 次，每次间隔 1 秒（默认只对网络传输错误/超时重试，业务错误不重试）
NetworkConfiguration.shared.defaultRetryPolicy = RetryPolicy(maxRetryCount: 2, retryDelay: 1)

// 单请求自定义
struct WeakNetAPI: NetworkRequest {
    typealias ResponseModel = SomeModel
    var path = "/info"
    var retryPolicy: RetryPolicy {
        RetryPolicy(maxRetryCount: 3, retryDelay: 0.5) { error, retried in
            // 只在前两次对超时重试
            if case NetworkError.timeout = error { return retried < 2 }
            return false
        }
    }
}
```

---

## 七点五、文件下载与后台任务

### 文件下载

`NetworkClient.shared.download` 提供 async/await 文件下载，内置最多 3 个并发限制，自动建目录、覆盖同名文件：

```swift
let localURL = try await NetworkClient.shared.download(
    from: "https://cdn.example.com/a.png",
    to: saveURL
)   // 默认已开启后台任务保护，切后台也争取时间下完
```

### 后台任务保护

用户何时切到后台不可控，所以 `runsInBackgroundTask` **默认就是 `true`**：框架会用 `UIApplication.beginBackgroundTask` 给每个请求包一层后台保护（非 UIKit 平台自动空操作）。个别确实不需要的接口可以显式关掉：

```swift
struct PingAPI: NetworkRequest {
    typealias ResponseModel = EmptyModel
    var path = "/ping"
    var runsInBackgroundTask: Bool { false }   // 这个接口不需要后台保护
}
```

## 七点六、自定义解析（返回原始 Data）

有些接口的返回结构很特殊（如字段里嵌套 JSON 字符串、需要手写解析），不适合 SmartCodable。这类请求可以不指定 `ResponseModel`（默认 `EmptyDecodable`），改用 `sendForData()` 拿原始 `Data` 自己解析；host/query/签名拦截器/重试/后台任务等能力照常生效：

```swift
struct LegacyListRequest: NetworkRequest {
    // 不写 typealias ResponseModel，默认 EmptyDecodable
    var host = "https://api.example.com"
    var path = "/legacy/list"
    var urlParameters: [String: Any] { ["api_key": key] }
    var requestInterceptors: [RequestInterceptor] { [MySignatureInterceptor()] }
}

let data = try await LegacyListRequest().sendForData()
let json = try JSONSerialization.jsonObject(with: data)   // 自定义解析
```

## 八、错误处理

所有错误都归一化成 `NetworkError`：

```swift
public enum NetworkError: Error {
    case invalidURL                                   // URL 非法
    case encoding(Error)                              // 参数编码失败
    case transport(Error)                             // 底层网络错误
    case timeout                                      // 超时
    case cancelled                                    // 取消
    case httpStatus(code: Int, data: Data)            // HTTP 非 2xx
    case business(code: Int?, message: String?, raw: Data) // 业务失败（code 未命中成功判定）
    case decoding(message: String, raw: Data)         // 模型解析失败
}
```

```swift
do {
    let user = try await LoginAPI(phone: phone, code: code).send()
} catch let error as NetworkError {
    switch error {
    case .business(let code, let message, _):
        showToast(message ?? "请求失败（\(code ?? -1)）")
    case .timeout:
        showToast("网络超时，请重试")
    default:
        showToast(error.localizedDescription)   // 已内置中文描述
    }
}
```

---

## 九、`NetworkRequest` 全部可重写项

| 属性 | 说明 | 默认值 |
| --- | --- | --- |
| `host` | 主机地址（含 scheme） | 全局 `baseHost` |
| `path` | 接口路径 | 必填 |
| `method` | HTTP 方法 | `.get` |
| `task` | 请求参数（body 或 GET query 二选一） | `.none` |
| `urlParameters` | 始终拼到 URL 的查询参数（可与 body 共存） | `[:]` |
| `headers` | 请求头（叠加在全局头之上） | `[:]` |
| `timeout` | 超时（秒） | 全局 `defaultTimeout` |
| `retryPolicy` | 重试策略 | 全局 `defaultRetryPolicy` |
| `requestInterceptors` | 该请求专属请求拦截器 | `[]` |
| `responseInterceptors` | 该请求专属返回拦截器 | `[]` |
| `envelope` | 外层字段映射与成功判定 | 全局 `defaultEnvelope` |
| `decodingOptions` | 模型解码选项（键名/日期/Data/浮点数策略） | 全局 `defaultDecodingOptions` |
| `cachePolicy` | URL 缓存策略 | `.useProtocolCachePolicy` |
| `ignoreGlobalInterceptors` | 是否忽略全局拦截器 | `false` |
| `runsInBackgroundTask` | 是否在后台任务保护下执行 | `true` |
| `send()` | 发送请求（async） | 内置实现，一般无需重写 |

---

## 十、全局配置项一览（`NetworkConfiguration.shared`）

| 属性 | 说明 |
| --- | --- |
| `baseHost` | 默认主机 |
| `defaultHeaders` | 默认请求头 |
| `defaultTimeout` | 默认超时 |
| `defaultEnvelope` | 默认外层字段映射 |
| `defaultDecodingOptions` | 默认模型解码选项（默认空集合，按属性名原样匹配） |
| `defaultRetryPolicy` | 默认重试策略 |
| `globalRequestInterceptors` | 全局请求拦截器 |
| `globalResponseInterceptors` | 全局返回拦截器 |
| `enableLog` | 是否打印调试日志（仅 DEBUG） |
| `enableDecodingDiagnostics` | 是否打印字段级解析诊断（默认 false，仅 DEBUG） |
| `session` | 自定义底层 `URLSession` |

---

## 十一、完整示例

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
    typealias ResponseModel = [Article]   // 数组也可解析（顶层直接返回数组同样支持）

    var path = "/articles"
    var method: HTTPMethod = .get
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
    } catch {
        print(error.localizedDescription)
    }
}
```

---

## 附：网络状态监听 `NetworkObserver`

本库还内置了一个网络状态观察者，可观测网络可用性、物理网络类型（WiFi / 2G~5G）、VPN 状态：

```swift
import NetworkKit

// App 启动时开启监听（仅需一次）
NetworkObserver.shared.beginObservation()

// 读取状态（@Observable，可直接在 SwiftUI 中观察）
let available = NetworkObserver.shared.isNetworkAvailable
let type = NetworkObserver.shared.networkType        // .wifi / .cellular(.g5) / ...
let vpn = NetworkObserver.shared.isVPNActive
```
