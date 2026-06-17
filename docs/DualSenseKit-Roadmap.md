# DualSenseKit 长程任务指南

本文档是 DualSenseKit 的长期开发攻略手册，用于把硬件测试 MVP 逐步推进成可复用 SDK 和稳定 Demo。每个功能点都按独立任务编写，后续可以单独开分支、单独实现、单独验收。

## 项目定位

DualSenseKit 当前由两部分组成：

- `DualSenseKit` SDK：负责 DualSense HID input report 解析、output report 编码、按钮/触控/传感器数据建模。
- `DualSenseKitDemo` macOS MVP：负责本地 HTTP/WebSocket API、菜单栏/无 Dock 运行、浏览器测试页、GameController 与 IOHID 集成。

长期目标是把硬件协议能力沉淀进 SDK，把 macOS 开发测试、调试面板、权限诊断、输入映射、音频实验保留在 Demo 层。

## 当前分支与基线

- 当前基线分支：`codex/backup-49ac4c0-light-fix`
- 当前基线提交：`80ee8d8 Back up 49ac4c0 light control fix`
- 历史基础提交：`49ac4c0 Rename project to DualSenseKit`
- 本地服务入口：`.manual-build/DualSenseKitDemo --headless-server`
- 本地测试页：`http://127.0.0.1:17395/test`
- 自测入口：`scripts/test.sh`
- 编译入口：`scripts/build.sh`

当前基线的关键状态：

- RGB 警灯控制优先走 Apple `GameController` 的 `GCDeviceLight`。
- 状态灯 player LEDs 普通控制只写 `mask`，不发送亮度字段。
- 状态灯颜色和线性亮度未确认支持，默认不开放。
- HID raw input 已能解析按钮、摇杆轴、扳机轴、触控点。
- UI 仍是纵向测试页，需要改成左侧操作栏 + 右侧日志。
- HID output 发包还没有统一事件日志。
- 陀螺仪/加速度计字段尚未建模到 SDK。

## 总体架构

目标架构按三层推进：

1. SDK 层
   - 只保留协议解析、output report 编码、数据模型、纯逻辑测试。
   - 不依赖 AppKit、GameController UI、HTTP 服务。

2. macOS 服务层
   - 集成 GameController、IOHID、CoreAudio、Accessibility。
   - 负责发事件、执行动作、写 HID report、暴露 HTTP/WebSocket。

3. 测试面板层
   - 只做本地浏览器调试和硬件可视化。
   - 所有实时数据走 `/v1/events` WebSocket。
   - 所有控制操作走本地 REST API。

事件约定：

- 输入事件使用 `button.*`、`hid.axis`、`hid.touch`、`hid.motion`。
- 输出事件使用 `hid.output.request`、`hid.output.success`、`hid.output.failure`。
- UI 操作日志使用 `ui.action`，用于对照用户点击和实际发包。

## 阶段路线图

### 阶段 1：测试面板可观测性

目标是让测试页变成真正的硬件调试台。

- 完成左侧操作栏 + 右侧实时日志。
- 所有 output report 发包必须可见。
- 触控板和陀螺仪必须可视化。
- 日志支持筛选、暂停、清空、自动滚动。

完成后，调试任何灯光/马达/扳机问题时，都能看到“点了什么、发了什么、系统返回什么”。

### 阶段 2：输入能力完整化

目标是稳定拿到所有按钮、摇杆、扳机、触控、陀螺仪、加速度计。

- 完善 HID input parser。
- 补齐 PS/Home、麦克风静音键、触控板按钮。
- 摇杆、扳机、D-pad、面键都进入统一事件模型。
- 为传感器数据建立 SDK 级测试。

### 阶段 3：输出能力稳定化

目标是把 RGB、状态灯、静音灯、马达、扳机统一成可测试输出能力。

- RGB 优先 GameController，HID 只作为实验路径。
- 状态灯普通路径只写 mask。
- 马达区分重/轻语义，并支持按住持续、松开停止。
- 扳机模式支持阻力、单点、连击、渐变阻力。

### 阶段 4：SDK 与 Demo 分层

目标是将协议能力做成正式 SDK。

- SDK 不引用 Demo 服务代码。
- Demo 只调用 SDK parser/encoder。
- README 给出 SDK 使用示例。
- Demo API 与 SDK API 各自清晰。

### 阶段 5：音频与系统能力探索

目标是明确 DualSense 音频能力边界。

- 普通 App 不承诺创建系统级音频设备。
- 虚拟扬声器/麦克风走 AudioDriverKit/System Extension。
- Demo 先做设备枚举和诊断，不假装蓝牙音频一定可用。

## 功能点详细计划

## 功能 1：测试页改为左侧操作栏 + 右侧实时日志

### 目标

把 `/test` 从纵向堆叠页面改成工作台式布局。左侧集中放控制和可视化，右侧专门显示实时日志。用户调试硬件时，不需要上下滚动寻找事件。

### 当前状态

- `APIServer.testPageHTML()` 内嵌整个测试页 HTML/CSS/JS。
- 当前页面按 section 从上到下排列。
- 日志目前在底部 `<pre id="events">`。
- WebSocket `/v1/events` 已存在。
- 最近事件 `/v1/events/recent` 已存在。

### 需要改动的模块

- `APIServer.testPageHTML()`：重写页面结构、CSS 和前端 JS。
- 不需要新增前端构建工具。
- 不需要新增静态资源文件。

### 后端实现细节

- 后端不用为布局新增 API。
- 保持 `/test` 返回单个 HTML 字符串。
- 保持现有 token 注入方式：`const TOKEN = "\(token)";`
- 保持 `/v1/events` WebSocket 作为实时数据源。

### 前端实现细节

页面结构建议：

```html
<body>
  <header>...</header>
  <main class="workspace">
    <aside class="control-pane">...</aside>
    <section class="log-pane">...</section>
  </main>
</body>
```

布局要求：

- 桌面端：
  - `.workspace` 使用 `display: grid`
  - 左侧宽度 `minmax(420px, 560px)`
  - 右侧 `minmax(360px, 1fr)`
  - 高度为 `calc(100vh - headerHeight)`
- 窄屏：
  - 改为单列布局。
  - 日志区域放在操作区下方。
- 左侧每个模块使用普通 section，不做卡片套卡片。
- 控件保持紧凑，适合反复测试。

左侧模块顺序：

1. 状态
2. 灯光测试
3. 马达与扳机
4. 陀螺仪 XYZ
5. 触控板
6. 按键测试

右侧日志模块：

- 顶部工具条：
  - 暂停/继续
  - 清空
  - 自动滚动开关
  - 过滤下拉：全部、发包、输入、UI 操作、错误
- 中间日志列表：
  - 每条日志一行摘要。
  - 点击或展开显示 JSON 详情。
- 底部统计：
  - 总事件数
  - 发包成功数
  - 发包失败数
  - 当前 WebSocket 状态

### 事件/API 设计

复用：

- `GET /v1/events/recent`
- `WS /v1/events`

前端内部新增日志分类函数：

- `classifyEvent(event)`
- 返回：`output`、`input`、`ui`、`error`、`other`

### 测试步骤

1. 编译并启动服务。
2. 打开 `/test`。
3. 确认左侧是操作栏，右侧是日志。
4. 点击灯光按钮，右侧日志立即增加事件。
5. 按手柄按钮，右侧日志立即增加输入事件。
6. 切换过滤器，日志数量和内容正确变化。
7. 点击暂停后，日志不再追加到 UI，但 WebSocket 仍保持连接。
8. 点击继续后，新事件恢复追加。

### 验收标准

- 页面首次打开不自动发包。
- 所有当前已有功能仍能点击。
- 右侧日志不会被长 JSON 撑破布局。
- 事件超过 500 条时页面仍可操作。
- 移动端或窄窗口下无文字重叠。

### 风险与回退方案

- 风险：内嵌 HTML 变长，维护困难。
- 回退：先保持单文件，但把 JS 函数分区注释清楚；后续再拆静态资源。
- 风险：高频事件导致 UI 卡顿。
- 回退：前端日志只保留最近 500 条，motion/touch 事件合并显示。

## 功能 2：每一次 HID output 发包都进入日志

### 目标

所有向手柄发送的 HID output report 都必须可见。调试时要能知道：用户点击了什么、后端准备发什么、IOHID 用哪种方式发送、macOS 返回什么结果。

### 当前状态

- 所有 HID output 基本经过 `DualSenseHIDService.sendReport(...)`。
- 当前只更新 `statusText`，没有为每次发包发布事件。
- 页面只能看到最后一个 `hidStatus`。

### 需要改动的模块

- `DualSenseHIDService`
- `ControllerService`
- `APIServer.testPageHTML()`
- `EventBus`

### 后端实现细节

为 `DualSenseHIDService` 增加 output 日志回调：

```swift
typealias OutputEvent = (BridgeEvent) -> Void
```

初始化时由 `ControllerService` 注入：

```swift
outputEvent: { [weak self] event in
    self?.eventBus.publish(event)
}
```

在 `sendReport(...)` 内发布三类事件：

- `hid.output.request`
- `hid.output.success`
- `hid.output.failure`

发包前事件字段：

- `intent`
- `sequence`
- `reportID`
- `reportLength`
- `reportBytesHexPrefix`
- `validFlag0`
- `validFlag1`
- `validFlag2`

每次 attempt 事件字段：

- `attempt`
- `reportID`
- `length`
- `result`
- `ok`

失败事件字段：

- `failures`
- `lastResult`
- `status`

intent 命名：

- `playerLEDs`
- `rumble`
- `micMuteLED`
- `lightbar`
- `adaptiveTrigger`

### 前端实现细节

右侧日志对输出事件做特殊显示：

- `hid.output.request` 显示为灰色。
- `hid.output.success` 显示为绿色。
- `hid.output.failure` 显示为红色。
- 摘要格式：

```text
[12:30:01.123] output success playerLEDs seq=4 attempt=output_payload result=00000000
```

每次点击 UI 控件时，在发送 fetch 前调用：

```js
appendLocalLog({
  type: "ui.action",
  payload: { action, endpoint, body }
});
```

### 事件/API 设计

不需要新增 HTTP API。

新增 WebSocket 事件：

- `hid.output.request`
- `hid.output.success`
- `hid.output.failure`
- `ui.action`

### 测试步骤

1. 点击 RGB 红色。
2. 日志出现 `ui.action`。
3. 日志出现 `hid.output.*` 或 GameController light 成功事件。
4. 点击状态灯玩家 1。
5. 日志出现 `hid.output.request` 和 success/failure。
6. 拔掉或断开手柄后点击状态灯。
7. 日志出现 failure，并包含 `hid_not_open` 或 IOHID 错误码。

### 验收标准

- 每一次发包都有日志。
- 失败不会静默。
- 日志里能看出尝试了哪种 `IOHIDDeviceSetReport` 发送方式。
- 发包日志不会被普通按钮事件覆盖掉。

### 风险与回退方案

- 风险：记录完整 report 导致日志过大。
- 回退：默认只记录前 16-24 字节；调试开关再显示完整 report。
- 风险：发包日志太多。
- 回退：右侧默认过滤显示 output + error，输入事件可切换查看。

## 功能 3：陀螺仪 XYZ 三轴实时显示

### 目标

实时显示 DualSense 回传的陀螺仪三轴 raw 数据，让用户能验证手柄运动传感器是否被正确解析。

### 当前状态

- `DualSenseInputReport` 目前包含 axes、hat、buttons、touchPoints。
- `DualSenseHIDService` 已解析 HID input report 并发布 `hid.axis`、`hid.touch`。
- 尚未解析 gyro/accelerometer。

### 需要改动的模块

- `Sources/DualSenseKit/DualSenseSDK.swift`
- `Sources/DualSenseKitDemoCore/DualSenseHIDService.swift`
- `Sources/DualSenseKitDemoCore/ControllerService.swift`
- `Tests/SelfTest/main.swift`
- `/test` 页面 HTML/JS

### 后端实现细节

新增 SDK 数据模型：

```swift
public struct DualSenseMotion: Equatable, Sendable {
    public var gyroX: Int16
    public var gyroY: Int16
    public var gyroZ: Int16
    public var accelX: Int16
    public var accelY: Int16
    public var accelZ: Int16
    public var timestamp: UInt32?
}
```

扩展：

```swift
public struct DualSenseInputReport {
    public var motion: DualSenseMotion?
}
```

解析规则：

- BT `0x31` report：`offset = 2`
- USB `0x01` report：`offset = 1`
- gyro raw `Int16 little-endian`
  - `gyroX = offset + 15`
  - `gyroY = offset + 17`
  - `gyroZ = offset + 19`
- accel raw `Int16 little-endian`
  - `accelX = offset + 21`
  - `accelY = offset + 23`
  - `accelZ = offset + 25`
- timestamp 可先读 `UInt32 little-endian`：
  - `offset + 27 ... offset + 30`

新增 helper：

```swift
private static func int16LE(_ bytes: [UInt8], _ index: Int) -> Int16
private static func uint32LE(_ bytes: [UInt8], _ index: Int) -> UInt32
```

`DualSenseHIDService.handleInputReport` 中：

- 解析到 motion 后，调用新的 `motionUpdate` 回调。
- 保留现有 axis/button/touch 逻辑。

`ControllerService`：

- 新增 `handleHIDMotion(_ motion: DualSenseMotion)`。
- 发布 `BridgeEvent(type: "hid.motion", payload: [...])`。

### 前端实现细节

左侧新增模块：

```html
<section id="motionPanel">
  <h2>陀螺仪 XYZ</h2>
  ...
</section>
```

每个轴显示：

- 轴名：X/Y/Z
- raw 数字
- range 条，范围 `-32768...32767`
- 中心线 0
- 最近更新时间

JS：

- 在 `addEvent(event)` 中处理 `hid.motion`。
- 更新 `gyroXValue`、`gyroYValue`、`gyroZValue`。
- 更新滚动条位置。
- 可选显示 accel raw，但不作为第一版主 UI。

### 事件/API 设计

新增事件：

```json
{
  "type": "hid.motion",
  "payload": {
    "gyroX": "...",
    "gyroY": "...",
    "gyroZ": "...",
    "accelX": "...",
    "accelY": "...",
    "accelZ": "...",
    "timestamp": "..."
  }
}
```

### 测试步骤

1. 构造 synthetic HID report，写入已知 gyro/accel bytes。
2. `scripts/test.sh` 验证 raw Int16 解析正确。
3. 启动服务。
4. 打开 `/test`。
5. 静止手柄时数值小幅波动。
6. 旋转手柄时 XYZ 至少一个轴明显变化。

### 验收标准

- 三轴数值实时更新。
- 不旋转时 UI 不疯狂刷屏导致卡顿。
- raw 值正负方向正确显示。
- 解析失败时不崩溃，不影响按钮/触控事件。

### 风险与回退方案

- 风险：不同连接模式 report offset 不一致。
- 回退：保留 raw HID report 最近记录，用日志对照修 offset。
- 风险：高频 motion 事件太多。
- 回退：后端或前端限制 UI 更新到 30 FPS。

## 功能 4：触控板多点触控可视化

### 目标

在测试页显示一个方形触控板区域，实时展示手指位置和 XY 坐标。一个手指显示一个半透明圆，两个手指显示两个半透明圆。

### 当前状态

- SDK 已有 `DualSenseTouchPoint`。
- HID parser 已解析两个 touch points。
- `DualSenseHIDService.emitTouch` 会逐个触点发布 `hid.touch`。
- GameController touchpad 也会发布 `touchpad.primary`、`touchpad.secondary`。

### 需要改动的模块

- `/test` 页面 HTML/JS/CSS。
- 可选改动 `DualSenseHIDService`，新增整帧事件 `hid.touchFrame`。

### 后端实现细节

最低实现：

- 继续使用现有 `hid.touch` 事件。
- 不改后端 parser。

推荐增强：

- 在每次 input report 后发布 `hid.touchFrame`。
- payload 包含两个触点：

```json
{
  "points": [
    {"index":"0","id":"12","x":"0.32","y":"0.44","active":"true"},
    {"index":"1","id":"13","x":"0.70","y":"0.20","active":"false"}
  ]
}
```

如果当前 `BridgeEvent.payload` 仍是 `[String:String]`，可以先用扁平字段：

- `point0Id`
- `point0X`
- `point0Y`
- `point0Active`
- `point1Id`
- `point1X`
- `point1Y`
- `point1Active`

### 前端实现细节

新增 UI：

```html
<section id="touchpadPanel">
  <h2>触控板</h2>
  <div id="touchpadSurface">
    <div id="finger0"></div>
    <div id="finger1"></div>
  </div>
  <div id="touchpadCoords"></div>
</section>
```

CSS：

- `#touchpadSurface`
  - `aspect-ratio: 1 / 1`
  - `position: relative`
  - 固定边框
  - 背景使用浅色网格，方便判断位置
- `.finger`
  - `position: absolute`
  - `width/height: 28px`
  - `border-radius: 50%`
  - `opacity: 0.65`
  - `transform: translate(-50%, -50%)`
- finger0 和 finger1 使用不同颜色。

JS：

- 保存 `touchState = { primary, secondary }`。
- 收到 `hid.touch`：
  - name 为 `primary` 更新 finger0。
  - name 为 `secondary` 更新 finger1。
- 收到 `touchpad.primary/secondary`：
  - 作为 fallback 更新对应 finger。
- 坐标渲染：
  - `x.toFixed(3)`
  - `y.toFixed(3)`
- 超过 500ms 未收到更新：
  - 圆点添加 `.stale`
  - opacity 降到 0

### 事件/API 设计

复用：

- `hid.touch`
- `touchpad.primary`
- `touchpad.secondary`

可选新增：

- `hid.touchFrame`

### 测试步骤

1. 单指触摸触控板左上、右上、左下、右下。
2. 圆点位置应随手指移动。
3. 单指时只显示一个圆。
4. 双指时显示两个圆。
5. 松手后圆点淡出。
6. XY 文本坐标实时变化。

### 验收标准

- 坐标范围保持 `0...1`。
- 圆点不会跑出方形区域。
- 多点显示不互相覆盖成不可区分。
- 高频触控移动时页面不卡顿。

### 风险与回退方案

- 风险：GameController 和 HID touch 坐标方向不一致。
- 回退：UI 标记事件来源，并以 HID 为主。
- 风险：inactive touch point 仍保留旧坐标。
- 回退：inactive 时立即隐藏圆点，坐标保留最后值但标记 inactive。

## 功能 5：警灯 RGB 控制稳定化

### 目标

让警灯 RGB 控制尽可能稳定，不再误以为 DualSense 左右彩灯可以独立控制。

### 当前状态

- 当前基线中 `/v1/light/lightbar` 已改为走 `LightService.setLightbar`。
- `LightService` 使用 Apple `GameController` 的 `GCDeviceLight`。
- HID lightbar report 在 macOS 蓝牙环境下不一定被手柄执行。

### 需要改动的模块

- `LightService`
- `APIServer`
- `/test` 页面

### 后端实现细节

默认路径：

- `PUT /v1/light`
- `PUT /v1/light/lightbar`
- 都走 `GCDeviceLight`。

HID lightbar：

- 只作为实验接口或内部调试。
- 不作为 UI 主按钮默认路径。

亮度：

- 亮度范围 `0.0...1.0`。
- 用 RGB 乘 brightness 实现。
- 不单独写 DualSense 私有 brightness 字段。

### 前端实现细节

灯光模块保留：

- 颜色按钮：红、绿、蓝、白、关闭 RGB。
- color picker。
- 警灯亮度滑块。

文案：

- 使用“警灯 RGB”。
- 不使用“左侧灯/右侧灯独立颜色”。

### 事件/API 设计

推荐新增事件：

- `lightbar.set`
- payload:
  - `r`
  - `g`
  - `b`
  - `brightness`
  - `path`: `gamecontroller`
  - `ok`

### 测试步骤

1. 点击红绿蓝白。
2. 拖动亮度滑块。
3. 点击关闭 RGB。
4. 观察手柄灯条。
5. 检查日志显示 path 为 `gamecontroller`。

### 验收标准

- API 返回 `ok:true` 时页面日志可见。
- 不承诺左右独立颜色。
- RGB 控制不影响 player LEDs mask。

### 风险与回退方案

- 风险：macOS GameController 不交出灯光控制权，手柄仍显示系统蓝色。
- 回退：页面显示“GameController Light 可用/不可用”，提示断开蓝牙重连。

## 功能 6：状态灯 player LEDs 控制

### 目标

稳定控制 DualSense 下方 5 颗白色 player LEDs 的组合亮灭。默认不支持颜色，不默认开放线性亮度。

### 当前状态

- 当前基线普通控制只写 `mask`。
- UI 已禁用状态灯亮度滑块。
- 状态灯按钮使用 mask：玩家 1、玩家 2、玩家 3、玩家 4、全亮、全灭。

### 需要改动的模块

- `DualSenseHIDService`
- `DualSenseProtocol`
- `APIServer`
- `/test` 页面
- `Tests/SelfTest/main.swift`

### 后端实现细节

普通控制：

- `PUT /v1/light/player-leds`
- body 只需要：

```json
{"mask": 4}
```

后端忽略 brightness。

普通 report：

- 设置 `playerIndicator = mask & 0x1f`
- 设置 `validFlag1 |= 0x10`
- 不设置 `validFlag2`
- 不写 `ledBrightness`
- 不写 motor bytes

亮度探测：

- 后续单独做实验接口。
- 不混入普通控制。

### 前端实现细节

保留按钮：

- 玩家 1
- 玩家 2
- 玩家 3
- 玩家 4
- 全亮
- 全灭

自由组合：

- 只显示确认有效的灯位。
- 如果灯 4/5 在硬件上重复或不可控，UI 应显示“待确认”，不要误导为可独立。

### 事件/API 设计

输出事件：

- `hid.output.request`
- `hid.output.success`
- `hid.output.failure`

业务事件可选：

- `playerLEDs.set`
- payload: `mask`, `ok`

### 测试步骤

1. 调用 `PUT /v1/light/player-leds {"mask":4}`。
2. 检查返回。
3. 检查 output report：
   - `report[46] == mask`
   - `report[5] == 0`
   - `report[6] == 0`
4. 依次测试玩家 1-4、全亮、全灭。

### 验收标准

- 点击状态灯不触发震动。
- 状态灯请求不影响 RGB 警灯。
- 全灭后再全亮仍会发送有效 report。

### 风险与回退方案

- 风险：macOS 接受 IOHID write，但手柄固件不执行 player LED。
- 回退：日志中明确区分 `IOHID ok` 与“肉眼硬件效果未确认”。

## 功能 7：马达与扳机控制

### 目标

把马达和自适应扳机做成可反复调试的硬件控制面板。

### 当前状态

- 已有 `PUT /v1/haptics/rumble`。
- 已有 `PUT /v1/triggers`。
- UI 有重马达、轻马达、扳机模式和滑块。
- 当前滑块是 input 后发一次 duration，不是完整按住持续模型。

### 需要改动的模块

- `ControllerService`
- `DualSenseHIDService`
- `APIServer.testPageHTML()`
- `Tests/SelfTest/main.swift`

### 后端实现细节

马达：

- API 继续接受：

```json
{"heavy":0.6,"light":0.2,"durationMs":1000}
```

- `durationMs = 0` 表示持续，直到下一次停止。
- 停止按钮发送：

```json
{"heavy":0,"light":0,"durationMs":0}
```

扳机：

- 保留模式：
  - `off`
  - `feedback`
  - `weapon`
  - `vibration`
  - `slopeFeedback`
- 优先使用 GameController adaptive trigger API。
- HID 私有 report 作为补充。

### 前端实现细节

马达：

- 滑块 pointerdown：
  - 立即发送当前值，`durationMs=0`
- input：
  - 以 40-80ms debounce 发送当前值
- pointerup / pointercancel / lostpointercapture：
  - 发送停止

扳机：

- 模式切换立即发送。
- 滑块变化 debounce 发送。
- 关闭扳机按钮把左右都设置为 `off`。

### 事件/API 设计

现有：

- `PUT /v1/haptics/rumble`
- `PUT /v1/triggers`

日志：

- 每次 rumble/trigger 都必须出现 `ui.action` 和 `hid.output.*`。

### 测试步骤

1. 按住重马达滑块拖动，震动持续。
2. 松开滑块，震动停止。
3. 按住轻马达滑块拖动，只轻震。
4. 点击停止震动，两个马达都停。
5. 设置 L2/R2 feedback，确认扳机阻力变化。
6. 关闭扳机，确认阻力消失。

### 验收标准

- 马达不会在松手后继续震动。
- 重/轻语义与实际硬件一致。
- 扳机关闭按钮可靠。
- 发包日志能定位每次马达/扳机命令。

### 风险与回退方案

- 风险：不同系统/连接模式下重轻马达字节语义相反。
- 回退：在 UI 增加“交换重轻马达”开发开关。

## 功能 8：按钮、短按、双击、长按测试

### 目标

测试每一个手柄按钮的 press、release、singleClick、doubleClick、longPress。

### 当前状态

- 已有 `ButtonGestureRecognizer`。
- 已有 `button.*` 事件。
- UI 显示单击、双击、长按通过状态。

### 需要改动的模块

- `ControllerService`
- `ButtonGestureRecognizer`
- `/test` 页面
- `Tests/SelfTest/main.swift`

### 后端实现细节

统一事件：

- `button.value`
- `button.press`
- `button.release`
- `button.singleClick`
- `button.doubleClick`
- `button.longPress`

按钮来源：

- GameController 作为普通按钮主来源。
- HID 补 PS/Home、触摸板按钮、麦克风静音键。

### 前端实现细节

按钮测试模块：

- 每个按钮一行。
- 列：press、release、singleClick、doubleClick、longPress。
- 每项通过后变绿。
- 提供“重置按键测试结果”按钮。

### 事件/API 设计

复用现有 WebSocket。

可选新增：

- `POST /v1/test/buttons/reset` 只清前端状态即可，不一定需要后端。

### 测试步骤

1. 对每个按钮单击。
2. 对每个按钮双击。
3. 对每个按钮长按。
4. 特别测试 PS/Home、麦克风静音、触控板按钮。

### 验收标准

- 页面能区分单击、双击、长按。
- release 不丢。
- 长按后不再误报 singleClick。
- 双击后不再误报两个 singleClick。

### 风险与回退方案

- 风险：PS/Home 被 macOS 系统抢占。
- 回退：记录 HID raw report，明确系统行为边界。

## 功能 9：音频与虚拟设备方向

### 目标

明确 DualSense 音频播放和麦克风录制的技术路线，避免普通 App 做不到的能力被误认为 bug。

### 当前状态

- 当前基础版本有 `AudioService`。
- macOS 蓝牙下通常不会把 DualSense 暴露为音频输出/输入。
- 普通 Swift App 不能静默创建系统级扬声器/麦克风设备。

### 需要改动的模块

- `AudioService`
- README / docs
- 后续新 target：`DualSenseKitAudioDriver`

### 后端实现细节

短期：

- 提供设备枚举。
- 显示是否存在 DualSense 真实音频端点。
- 显示虚拟驱动未安装状态。

长期：

- 走 AudioDriverKit/System Extension。
- 创建系统可见：
  - `DualSenseKit Speaker`
  - `DualSenseKit Microphone`
- Demo 服务负责桥接 PCM ring buffer。

### 前端实现细节

测试页音频模块显示：

- 系统输出设备。
- 系统输入设备。
- DualSense 音频端点。
- 虚拟驱动状态。
- 安装/授权步骤。

### 事件/API 设计

后续建议：

- `GET /v1/audio/devices`
- `GET /v1/audio/driver/status`
- `POST /v1/audio/driver/install-guide`

### 测试步骤

1. 蓝牙连接下枚举音频设备。
2. USB 连接下枚举音频设备。
3. 如果存在 DualSense 输出，尝试播放提示音。
4. 如果不存在，页面明确显示不可用。

### 验收标准

- 不假装蓝牙一定支持手柄扬声器/麦克风。
- 不自动绕过 macOS 系统扩展授权。
- 文档清楚说明 DriverKit 要求。

### 风险与回退方案

- 风险：DriverKit 需要 Apple Developer entitlement。
- 回退：先只做诊断，不交付虚拟驱动。

## 功能 10：SDK 化与 Demo 分层

### 目标

把协议能力固化为可复用 Swift SDK，把浏览器测试、macOS 权限和本地 API 保留在 Demo。

### 当前状态

- `Sources/DualSenseKit` 已存在。
- Demo 代码直接调用 SDK parser/output encoder。
- 部分协议实验逻辑仍散在 Demo 服务层。

### 需要改动的模块

- `Sources/DualSenseKit`
- `Sources/DualSenseKitDemoCore`
- `Tests/SelfTest`
- README

### 后端实现细节

SDK 应包含：

- HID input parser。
- HID output report encoder。
- DualSense 数据模型。
- CRC32。
- button/hat/touch/motion 纯逻辑。

Demo 应包含：

- IOHIDManager。
- GameController。
- HTTP/WebSocket。
- UI HTML。
- macOS Accessibility。
- CoreAudio。

### 前端实现细节

无直接前端要求。

### 事件/API 设计

SDK 不暴露 HTTP。

Demo API 使用 SDK 类型的结果，但不把 Demo-only 字段塞进 SDK。

### 测试步骤

1. SDK parser 独立测试。
2. SDK output report 独立测试。
3. Demo 编译测试。
4. `/test` 冒烟测试。

### 验收标准

- SDK target 不依赖 AppKit。
- SDK target 不依赖 GameController。
- SDK target 不依赖 Network。
- Demo 仍能编译运行。

### 风险与回退方案

- 风险：过早抽象导致改动变慢。
- 回退：只移动已经稳定的 parser/encoder，实验能力先留 Demo。

## 调试与验收清单

每次实现新功能后至少执行：

```sh
scripts/test.sh
scripts/build.sh
```

启动：

```sh
./.manual-build/DualSenseKitDemo --headless-server
```

基础接口：

```sh
curl -s http://127.0.0.1:17395/v1/status
```

浏览器：

```text
http://127.0.0.1:17395/test
```

硬件检查：

- 手柄已连接。
- `accessibilityTrusted` 为 true。
- `hidConnected` 为 true。
- `hidWritable` 为 true。
- WebSocket 日志有事件。
- 点击 UI 后有 `ui.action`。
- 发 HID 后有 `hid.output.*`。

## 已知限制

- 状态灯 player LEDs 默认视为白色指示灯。
- 状态灯颜色默认不支持。
- 状态灯线性亮度默认不支持。
- RGB lightbar 在 macOS 上优先依赖 GameController；如果系统不交控制权，可能仍显示默认蓝色。
- PS/Home 可能被 macOS 系统功能抢占。
- 蓝牙 DualSense 不保证暴露系统音频输入/输出。
- 虚拟扬声器/麦克风需要 DriverKit/System Extension，普通 App 不能静默创建。

## 后续决策记录

| 日期 | 决策 | 原因 | 后续影响 |
| --- | --- | --- | --- |
| 2026-06-17 | RGB 警灯优先走 GameController | macOS 下 HID lightbar 不稳定 | HID lightbar 仅作为实验路径 |
| 2026-06-17 | 状态灯普通控制只写 mask | brightness 字段会干扰实际效果 | 亮度探测必须独立成实验功能 |
| 2026-06-17 | 测试页继续内嵌在 APIServer | 当前 MVP 无前端构建链路 | 页面复杂后再考虑拆静态资源 |
| 2026-06-17 | 传感器先显示 raw 值 | 校准和单位换算需要更多资料 | 第一版只做 raw 验证 |
| 2026-06-17 | 音频虚拟设备不放进普通 App | macOS 需要系统扩展和授权 | 先做诊断，后续单独 DriverKit 项目 |

