# 端口冲突处理设计（P1.2）

> 日期: 2026-06-17
> 状态: 设计中（待评审）
> 关联: `NEXT.md` P1.2、`DENY.md` 第三节、`docs/design/communication-protocol.md`
> 更新: 2026-06-17 — 用户确认 App Group 文件读取已验证不可行（DENY.md 第三节成立）；据此方案 A 废弃，端口发现仅留 Bonjour

---

## 1. 问题陈述

Container App 通过 `RPCServer.start()` 用 `NWListener` 监听固定端口
`Constants.rpcPort = 57421`（`Shared/Constants.swift:27`）。当前 `start()` 的
bind 失败分支只做一件事：

```swift
// Shared/RPC/RPCSession.swift:224-240
public func start() {
    do {
        let listener = try NWListener(using: params, on: ...Constants.rpcPort)
        ...
        logger.notice("[Con] RPCServer: listening on ...")
    } catch {
        logger.error("RPCServer: failed to start listener: \(...)")
    }
}
```

**问题不在「要不要换端口」，而在「失败不可见」。** `start()` 返回 `void`，
bind 失败被吞进一行 error 日志，Container 进程照常运行、UI 看起来一切正常，
但 Extension 永远连不上。

### 失败传导链（这才是 P1.2 的真实危害）

```
57421 bind 失败
  └─ Container 进程仍在跑，写了 container.lock（含 PID）
       └─ Extension connect() 失败 → resetAndRetry() → launchContainerIfNeeded()
            └─ isContainerProcessAlive()：读 container.lock → PID 活着 →「Container 在，别拉起」
                 └─ 只重连、不拉起新实例 → 无限 2s 重连失败
                      └─ 右键菜单点击静默失效，用户无任何反馈
```

要点：**现有的「连接失败自动拉起 Container」机制在端口冲突时会误判 Container 健康
（因为它判断的是进程存活，不是端口可达），从而拒绝自救。** 所以修复必须从
Container 端的「bind 结果可见 + 可恢复」入手。

---

## 2. 根因分析：端口 57421 何时 bind 失败

| 场景 | 是否发生 | 原因 |
|---|---|---|
| 旧 Container 还活着、仍在 LISTEN | ❌ 已被防住 | `AppState.init()`（`AppState.swift:81-83`）`acquireInstanceLock()` 用 `flock(LOCK_EX\|LOCK_NB)` 排他锁，抢不到即 `exit(0)`，**同机永远只有一个 Container 能监听** |
| Container crash 后立即重启 | ⚠️ 边缘 | crash 时 OS 自动释放 flock fd 与 LISTEN socket；LISTEN socket 关闭后端口通常立即可重 bind。`TIME_WAIT` 主要影响 ESTABLISHED 连接的主动关闭方，对 LISTEN 重 bind 影响有限。仅在 crash 瞬间存在大量残留子连接时理论可能 |
| **外部进程占用 57421** | ✅ **真实风险** | 开发期 `nc -l 57421` / `lsof` 调试残留、僵尸进程、或恰好另一个程序用了该端口。生产用户罕见（57421 冷门），但开发期高频 |

**结论**：固定端口的真实冲突源主要是「外部占用」，且因单实例锁的存在，「自占用」
已被排除。这意味着**自动换端口的收益很低**（触发条件罕见），而「让失败可见」的
收益很高（一旦触发，当前完全静默）。

---

## 3. 核心约束：端口协商的「鸡生蛋」与带外通道不可用

若要让 Extension 跟随 Container 切换到备用端口（方案 A），必须有一个**带外通道**
把新端口号告诉 Extension——因为 Extension 在连上 Container 之前收不到任何 in-band
RPC（鸡生蛋）。带外通道的唯一候选是共享文件，而本项目的沙盒边界决定了它**不可用**。

**沙盒边界（用户实测确认，2026-06-17）**：

| 方向 | 可行性 | 说明 |
|---|---|---|
| Ext 读**自己** App 目录下文件 | ✅ | Ext 对自有 sandbox container 有权 |
| Ext 读其他任意文件 | ❌ TCC | 沙盒拦截，触发弹窗 |
| Con 读 Ext App 目录下文件 | ✅ | Con 非沙盒，读不受限 |
| Con **写** Ext App 目录 | ❌ TCC | `~/Library/Containers/<ext-bundle>/` 跨进程写被拦（DENY.md 第三节已证） |
| App Group 文件读取（作为同步机制） | ❌ | 已验证不可行（DENY.md 第三节：cfprefsd 断连 + 裸文件 TCC） |

端口协商需要的是 **Con 写 → Ext 读** 方向。上表里 Ext 读取虽有自己的口子，但 **Con
找不到一个「可写 + Ext 能稳定读到」的中立位置**：Con 写 Ext 私有容器被 TCC 拦，App Group
文件读取已验证不可行。**因此方案 A 的带外通道不存在，方案废弃。**

> **既存代码观察**：`isContainerProcessAlive()`（`RPCSession.swift:772-779`）让 Ext 用
> `Data(contentsOf:)` 读 App Group 容器的 `container.lock`。按上述「App Group 文件读取
> 不可行」结论，该 best-effort 链路的有效性存疑；但它是**降级安全**的（读不到即视为
> Container 已死 → 触发拉起新实例，不会产生错误行为），且**不影响本设计结论**（方案 A
> 因 Con 写入方向不可用而废弃，与该读取链路无关）。建议另行确认该链路在实际环境的稳定性。

---

## 4. 候选方案

### 方案 A — 备用端口 + App Group 端口协商文件

Container bind 57421 失败 → 尝试 57422/57423… → 成功后把实际端口写入 App Group 文件
（如 `rpc.port`）；Extension 连接前先读该文件拿到端口，连不上则回退默认端口。

- ✅ 端口占用时自动恢复，对用户透明
- ❌ **带外通道不存在**：Con 写 Ext 目录被 TCC 拦、App Group 文件读取已验证不可行（§3）→ **方案废弃**
- ❌ 复杂度最高：需端口发现 + 回退 + 文件读写竞态（Extension 读到半写端口）
- ❌ 对「自占用」（已被单实例锁防住）零收益；对「外部长期占用」才有用

### 方案 B — bind 失败检测 + 用户提示（可观测性优先）⭐

`start()` 改为返回 `Result`/`Bool`；bind 失败时 Container 探测占用者（`lsof -i :57421`），
在 UI（`ExtensionsSettingsTab` 已显示 `host:port`，:12）展示「端口被占用 / RPC 不可用」
banner，引导用户释放端口。

- ✅ 直击真实痛点（静默失效 → 可见）
- ✅ 不改通信协议、不碰 App Group 文件、无 TCC 风险
- ✅ 改动小，与现有代码契合（`ExtensionsSettingsTab` 已有 host:port 展示位）
- ❌ 不能自动恢复，需用户介入（开发期足够，生产几乎不触发）

### 方案 C — Bonjour 服务发现（`NWBrowser` / `NWListener` with `NWEndpoint.service`）

Container 不再固定端口，而是以 Bonjour 名字注册服务；Extension 用 `NWBrowser` 发现
服务后连接。彻底解耦固定端口。

- ✅ 一劳永逸，端口冲突概念消失；天然支持多实例
- ❌ 引入 mDNS 依赖，Extension 沙盒需额外 entitlement（`com.apple.security.network.bonjour`?）
- ❌ 较重，属于架构演进，非短期修复
- ❌ Bonjour 在纯 loopback 场景是否被沙盒允许需验证

### 方案 D — 地址复用 / bind 重试（针对 TIME_WAIT）

若 §2 的「crash + 残留子连接 → TIME_WAIT」被证实，则让 listener 在重 bind 时复用地址。
Network framework（`NWParameters`/`NWListener`）未直接暴露 `SO_REUSEADDR` 等价 API；
可能需回退 BSD socket 或验证 `NWParameters` 是否隐含复用。

- ✅ 治 TIME_WAIT 的本
- ❌ Network framework 无公开复用 API（**待验证**，§8）
- ❌ 仅对边缘的 TIME_WAIT 场景有效，对外部占用无效

---

## 5. 方案裁决表

| 维度 | A 备用端口 | B 可见性提示 | C Bonjour | D 地址复用 |
|---|---|---|---|---|
| 直击静默失效 | ✅ | ✅✅ | ✅ | ⚠️ |
| 改动复杂度 | 高 | **低** | 高 | 中 |
| 协议/契约变更 | 有 | 无 | 有 | 无 |
| TCC / 沙盒风险 | ❌ 已确认不可行 | **无** | ⚠️ 待验证 | 无 |
| 对「自占用」收益 | 0 | — | — | — |
| 短期可落地 | ❌ | **✅** | ❌ | ❌ |

---

## 6. 推荐方案（分阶段）

**总体判断**：真实冲突源（外部占用）罕见但当前完全静默，故**第一优先级是把失败做可见、
做可恢复，而非做端口协商**。端口协商（A/C）性价比最低且依赖待澄清的带外通道，仅在
未来确实出现「固定端口被外部长期占用」时再演进。

### 阶段一（必做）— 可观测性：bind 失败可见 + 探测占用者

落地方案 B 的核心。这是 P1.2 的最小闭环。

### 阶段二（建议）— 可恢复：bind 重试 + 自杀让位

- bind 失败 → 在固定窗口内（如 10s，每 2s）重试一次，吸收极短的 TIME_WAIT / 端口释放延迟；
- 仍失败 → 进入阶段一的「占用者提示」状态；
- 可选：若探测到占用者**正是本 bundle 的僵尸 Container 进程**（单实例锁失效的兜底），
  Container 自行退出（`exit(0)`），让 Extension 的自动拉起机制接管。

### 阶段三（按需，长期）— 端口发现

仅当真实用户反馈固定端口冲突频发时再做。方案 A（App Group 协商文件）已因带外通道
不可用废弃，**仅剩 Bonjour 服务发现（方案 C）一条路**，需先验证其在 Extension 沙盒
+ loopback 下的可用性与所需 entitlement。

---

## 7. 阶段一详细设计

### 7.1 `RPCServer.start()` 暴露结果

```swift
// Shared/RPC/RPCSession.swift
public enum RPCStartError: Error {
    case bindFailed(underlying: Error)
}

public func start() -> Result<Void, RPCStartError> {
    do {
        let listener = try NWListener(using: .tcp,
                                      on: .Port(integerLiteral: Constants.rpcPort))
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        startPingTimer()
        return .success(())
    } catch {
        logger.error("RPCServer: failed to start listener: \(...)")
        return .failure(.bindFailed(underlying: error))
    }
}
```

### 7.2 AppState 持有监听状态

```swift
// mac-right-menu/ViewModels/AppState.swift
@Published var rpcListening: Bool = false
@Published var rpcPortOccupant: String? = nil   // 占用进程的可读描述，nil=未知/自身

// init() 内，_ = rpcServer 之后：
let result = rpcServer.start()
switch result {
case .success:
    rpcListening = true
case .failure:
    rpcListening = false
    rpcPortOccupant = await Self.probePortOccupant()   // 见 7.3
}
```

### 7.3 占用者探测（仅 Container，非沙盒）

Container 非沙盒，可自由执行 `lsof`，不存在 TCC 问题：

```swift
nonisolated private static func probePortOccupant() async -> String? {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/sbin/lsof"
            task.arguments = ["-nP", "-iTCP:\(Constants.rpcPort)", "-sTCP:LISTEN"]
            // 解析输出首行的 PID/进程名，返回 "python (pid 12345)" 之类
            ...
            cont.resume(returning: parsed)
        }
    }
}
```

### 7.4 UI 反馈

`ExtensionsSettingsTab` 已有 `\(Constants.rpcHost):\(String(Constants.rpcPort))`（:12），
在其旁/下增加状态指示：

- `rpcListening == true` → 绿点 + 「RPC 监听中」
- `false` → 红点 + 「端口 57421 被占用」+（若有）`rpcPortOccupant` + 「释放后重启 App」按钮

### 7.5 Extension 侧的连带改善（可选，小）

`isContainerProcessAlive()` 只判进程存活。可在 Extension 连接失败重试时，叠加一次
「Container 是否真在监听」的轻量判定——但 Extension 无权 `lsof`，且连不上本身就是
最强信号，所以**最小做法是不改 Extension**，仅靠 Container UI 提示即可覆盖根因。

---

## 8. 待澄清 / 验证项（实施前必须确认）

1. **App Group 文件读取可行性 — 已确认（用户实测，2026-06-17）**
   - 结论：不可行（DENY.md 第三节成立）。沙盒边界见 §3 表格。
   - 据此：方案 A 废弃；阶段三端口发现仅留 Bonjour（方案 C）。
   - 残留建议：确认既存 `isContainerProcessAlive()` 读取 `container.lock` 的链路在
     实际环境的稳定性（该结论与该链路表面并存；因属 best-effort 降级，不阻塞本设计）。

2. **Network framework 是否提供端口/地址复用**
   - 查证 `NWParameters` 是否有 `SO_REUSEADDR` 等价物，或 `NWListener` 重 bind 同端口的
     实际行为，决定方案 D 是否成立。

3. **LISTEN socket 在进程 crash 后的重 bind 时延**
   - 实测 `kill -9` Container 后立即重启，端口多久可重 bind，决定阶段二重试窗口。

---

## 9. 风险与回滚

| 风险 | 缓解 |
|---|---|
| `start()` 改返回值是 API 变更，影响 Container 启动流程 | 单一调用点（`AppState.init()`），改动局部，回滚即恢复 void |
| `lsof` 探测耗时/缺失 | 放后台队列、设超时；`lsof` 缺失时 `rpcPortOccupant = nil`，UI 退化为通用提示 |
| 阶段一不改协议，但若未来上阶段三需改 Extension | 阶段三独立，不影响阶段一/二的可独立交付 |

---

## 10. 小结

P1.2 的本质不是「端口协商」，而是 **`RPCServer.start()` 失败的静默吞没**。单实例锁
已排除最常见的自占用场景，真正残留的外部占用虽罕见但当前完全无反馈。**推荐立即落地
阶段一（可见性 + 占用者探测）**，阶段二（重试 + 自杀让位）作为增强，阶段三（端口发现）
推迟到确有需求；方案 A（App Group 协商文件）已因带外通道不可用废弃，阶段三仅剩
Bonjour（方案 C）。
