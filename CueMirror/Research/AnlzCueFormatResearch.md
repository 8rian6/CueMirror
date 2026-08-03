# ANLZ Cue 格式研究与 Swift 数据结构（第一阶段）

研究日期：2026-07-21

本阶段只完成格式对照、无损结构化解析和往返测试。没有运行 CueMirror 写入功能，没有修改 U 盘，也没有启用 `exportLibrary.db.cue` 写入。

## 依据

1. Deep Symmetry，*Rekordbox ANLZ File Format*：
   <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html>
2. rekordcrate 官方源码 `src/anlz.rs`：
   <https://github.com/Holzhaus/rekordcrate/blob/main/src/anlz.rs>
3. crates.io 发布包 `rekordcrate 0.3.0`：
   <https://crates.io/crates/rekordcrate/0.3.0>
4. 本工程已有的 Before/After 实测：`Research/MemoryCueBeforeAfterDiff.md`。

注意：crates.io 上标为 0.3.0 的归档源码仍使用旧的宽字符串实现；用户指定的 `LenPrefixedWideString` 和 `extended_cue_empty_comment_roundtrip` 位于 rekordcrate 官方仓库当前 `anlz.rs`。本实现以 Deep Symmetry 字段说明、当前上游修复和本地实测三者交叉确认，不引入 Rust 运行时。

## 已确认的通用结构

- ANLZ 整体和所有 tag 均为大端序。
- 每个 tag 的公共头是 12 字节：4 字节 magic、`headerLength: UInt32`、`totalLength: UInt32`。
- PMAI 是文件头；其 `headerLength` 到首个 tag 之间的字节必须保留。
- 不认识的 tag 不尝试重建，整段按原始字节保存。
- PMAI 声明长度之后的文件尾部字节也必须保存。

## PCOB / PCPT

### PCOB

- 标准 `headerLength = 24`。
- `+0x0c UInt32`：列表类型，`0` 为 Memory Cue，`1` 为 Hot Cue。
- `+0x10 UInt16`：未知。
- `+0x12 UInt16`：PCPT 数量。
- `+0x14 UInt32`：与 Memory Cue 数量有关，但确切语义仍未确认；结构中命名为 `memoryCount`，不自行推导。
- 超过标准头长度的字节保存为 `headerExtra`。

### PCPT

- 实测和文档中的条目总长为 56 字节，`headerLength = 28`。
- `+0x0c UInt32`：Hot Cue 编号；Memory Cue 为 0。
- `+0x10 UInt32`：状态；活动 Loop 可见值为 4，其余语义未知。
- `+0x14 UInt32`：未知。
- `+0x18/+0x1a UInt16`：排序/序号相关字段，确切语义未确认。
- `+0x1c UInt8`：类型，`1` 为 Cue，`2` 为 Loop。
- `+0x1d UInt8`、`+0x1e UInt16`：未知；常见组合包含 `00 03e8`。
- `+0x20 UInt32`：开始时间（毫秒）。
- `+0x24 UInt32`：Loop 结束时间（毫秒）；非 Loop 常见 `0xffffffff`。
- `+0x28` 之后全部保存为未知尾部。

## PCO2 / PCP2

### PCO2

- 标准 `headerLength = 20`。
- `+0x0c UInt32`：列表类型，`0` 为 Memory Cue，`1` 为 Hot Cue。
- `+0x10 UInt16`：PCP2 数量。
- `+0x12 UInt16`：未知。
- 超过标准头长度的字节保存为 `headerExtra`。

### PCP2

- `headerLength = 16`；`totalLength` 可变。
- `+0x0c UInt32`：Hot Cue 编号；Memory Cue 为 0。
- `+0x10 UInt8`：类型，`1` 为 Cue，`2` 为 Loop。
- `+0x11 UInt8`、`+0x12 UInt16`：未知；后者常见 1000 (`0x03e8`)。
- `+0x14 UInt32`：开始时间（毫秒）。
- `+0x18 UInt32`：Loop 结束时间（毫秒）。
- `+0x1c UInt8`：颜色 ID。
- 接下来的 7 字节：未知，逐字节保存。
- 接下来两个 `UInt16`：Loop 分子、Loop 分母。
- 接下来是长度前缀 UTF-16BE 评论。
- 评论之后 4 字节：Hot Cue 颜色索引以及 RGB。
- 再后的 5 个 `UInt32` 按 rekordcrate 的已观察布局结构化为未知字；其余全部进入 `trailing`，不解释、不清零。

### 空评论的关键修正

`LenPrefixedWideString` 的长度是评论 payload 的字节数：

- 空评论：长度为 0，后面没有 UTF-16 NUL。
- 非空评论：UTF-16BE 内容后包含一个 UTF-16 NUL，长度包括该 NUL。

不能把空评论强制按 NUL 结尾字符串读取。测试直接采用 rekordcrate `extended_cue_empty_comment_roundtrip` 中的真实 88 字节 PCP2，并要求逐字节写回一致。

## Swift 实现

新增 `AnlzFormat.swift`，包含：

- `AnlzSectionHeader`
- `AnlzLenPrefixedWideString`
- `AnlzCue`（PCPT）
- `AnlzCueList`（PCOB）
- `AnlzExtendedCue`（PCP2）
- `AnlzExtendedCueList`（PCO2）
- `AnlzSectionContent` / `AnlzSection`
- `AnlzDocument`（PMAI 与 tag 容器）

无损策略：

- 已确认字段使用大端整数或字符串结构化。
- 未确认字段仍保留明确的 `unknown...` 名称，不赋予推测语义。
- 可变未知尾部保存为 `Data`。
- 未识别 tag 保存完整原始 `Data`。
- 解析后不修改时，编码结果必须和输入逐字节相同。

## 下一阶段写入器的边界

真实副本写入器应按以下顺序实现：

1. 从 HC09–HC16 的来源 PCP2 克隆完整对象，连同未知字和 `trailing` 一并复制。
2. 只修改已确认的 Memory Cue 身份字段（首先是 `hotCueNumber = 0`；其他字段必须有样本或文档依据后才修改）。
3. 为 DAT 生成 type=0 PCOB/PCPT。
4. 为 EXT 生成 type=0 PCOB 和 type=0 PCO2/PCP2。
5. 除目标 Memory Cue tag 外，所有 ANLZ tag 保持原始字节和原始顺序。
6. 写入仅发生在输出副本；写后重新解析并执行规范化内容验证和整文件结构验证。

`exportLibrary.db.cue` 写入继续暂停。现有 Before/After 样本的 cue 表前后均为空，尚不足以确认数据库端真实 Memory Cue 行及其更新时间计数行为。

## 尚未确认

- PCPT 的状态、排序字段和剩余尾部字段的完整语义。
- PCP2 的 7 个未知字节、5 个未知 `UInt32` 和后续 trailing 的完整语义。
- 从 Hot Cue 克隆为 Memory Cue 时，除 `hotCueNumber` 外是否还有必须变化且可安全确认的定位字段。
- DAT 与 EXT 中 Memory PCOB 的计数/序号字段在 Cue、Loop、混合和删除重建场景下的所有取值规则。
- `exportLibrary.db.cue` 的真实 Memory Cue 行、ID 分配及 content 更新计数规则。

因此，当前信息足以实现并验证 ANLZ 的无损读写基础设施；要启用真实 Memory Cue 副本写入，还应先用包含 Hot Cue 来源与其手动转换结果的配对样本确认最小身份字段变更集合。数据库写入仍不具备足够证据。

## 2026-07-21：普通 Cue A / C 的 After 内部配对

来源只读文件：

- `<OneLibrary-USB>/PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.DAT`
- `<OneLibrary-USB>/PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.EXT`

分析前 SHA-256：

- DAT：`1b644d645b17f614f7497808d32606957011610cacf96d2843c7df2d2df88d66`
- EXT：`318a6f1c077eccd924b210cf4fcd5d1115cc96ffc04f77b35166c9c1c4e0c6f5`

旧的 `before` 快照不是添加本次 A/C 前的干净快照：其中 Hot Cue 和 Memory Cue 状态与当前文件不一致。因此本节不把旧 Before/After 的变化混入结论，只比较当前 After 文件内部的精确时间配对。

### 配对和时间验证

| 配对 | Hot PCP2 offset | Memory PCP2 offset | Hot 编号 | Hot 时间 | Memory 时间 | 二进制时间一致 |
|---|---:|---:|---:|---:|---:|---|
| A | 66060 | 66808 | 1 | 245 ms | 245 ms | 是 |
| C | 66172 | 66896 | 3 | 76,435 ms | 76,435 ms | 是 |

配对依据是 ANLZ 中完整的毫秒 `UInt32`，不是 Rekordbox 界面的取整秒数。Hot Cue B 为 `cueType=2`、53,578–61,197 ms，本轮排除。

### PCP2 完整差异

两组变化模式一致：Hot PCP2 均为 56 字节，Memory PCP2 均为 88 字节。

| PCP2 字段/相对偏移 | Hot A | Memory A | Hot C | Memory C | 分类 |
|---|---:|---:|---:|---:|---|
| `totalLength` `+0x08` | 56 | 88 | 56 | 88 | Memory 记录重建 |
| `hotCueNumber` `+0x0c` | 1 | 0 | 3 | 0 | 必须修改：Memory 身份 |
| `cueType` `+0x10` | 1 | 1 | 1 | 1 | 可克隆（仅普通 Cue 已验证） |
| unknown1 `+0x11` | 0 | 0 | 0 | 0 | 相同，但语义未知 |
| unknown2 `+0x12` | 1000 | 1000 | 1000 | 1000 | 可按样本克隆，语义未知 |
| startTime `+0x14` | 245 | 245 | 76,435 | 76,435 | 必须保留来源值 |
| loopTime `+0x18` | `0xffffffff` | `0xffffffff` | `0xffffffff` | `0xffffffff` | 普通 Cue 可克隆；Loop 未验证 |
| colorID `+0x1c` | 0 | 0 | 0 | 0 | 相同；颜色复制未验证 |
| unknown byte `+0x1d` | 0 | 1 | 0 | 1 | Memory 记录重建，必须变化 |
| unknown `+0x1e…+0x23` | 全 0 | 全 0 | 全 0 | 全 0 | 相同，语义未知 |
| Loop numerator / denominator `+0x24/+0x26` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 普通 Cue 相同；Loop 未验证 |
| comment length/payload `+0x28` | 0 / 空 | 0 / 空 | 0 / 空 | 0 / 空 | 空值相同；评论复制未验证 |
| Hot color index `+0x2c` | 0 | 0 | 0 | 0 | 相同；颜色复制未验证 |
| RGB `+0x2d…+0x2f` | `#00E0FF` | `#000000` | `#00E0FF` | `#000000` | 手工新建 Memory 没有复制颜色；不能推导转换策略 |
| unknown UInt32 `+0x30` | 0 | 0 | 0 | 0 | 相同，未知 |
| unknown UInt32 `+0x34` | 0 | 10,240 (`0x2800`) | 0 | 3,369,984 (`0x336c00`) | Memory 生成且随时间变化，算法未知 |
| unknown UInt32 `+0x38…+0x43` | 不存在 | 0, 0, 0 | 不存在 | 0, 0, 0 | Memory 扩展区域，未知 |
| trailing `+0x44…+0x57` | 不存在 | `0000610900000000000000000000040000000000` | 不存在 | `00d2899600000000000000000000040000000000` | Memory 生成；首 UInt32 随 Cue 变化，算法未知 |

逐字节结论：两条 Memory 记录不等于“来源 Hot PCP2 完整字节 + 修改 hotCueNumber”。除身份字段外，记录长度、`+0x1d`、RGB、`+0x34` 的未知定位值以及新增的 32 字节区域均发生变化。A/C 的变化种类一致，但两个未知定位值不同，无法从两个样本确定生成公式。

### EXT 列表

- Hot `PCO2`：offset 66040，`listType=1`，13 条；原 Hot PCP2 保持存在且未被 Memory 条目替换。
- Memory `PCO2`：offset 66788，`listType=0`，2 条，物理顺序为 A(245 ms) → C(76,435 ms)。
- EXT 另有空的 Memory `PCOB`：offset 66016，count=0，`memoryCount=0xffffffff`。
- PCO2 的 `count=2` 是由列表重建产生；列表头 unknown=0。

### DAT PCPT 和顺序链

DAT Hot PCOB 位于 offset 9568，包含 A、B、C 三条 Hot PCPT。DAT Memory PCOB 位于 offset 9760，包含两条 Memory PCPT。

两组普通 Cue 的 Hot → Memory PCPT 变化：

| 字段 | Hot A / C | Memory A / C | 结论 |
|---|---|---|---|
| `hotCueNumber` | 1 / 3 | 0 / 0 | Memory 身份，必须修改 |
| `status` | 0 | 0 | 相同；Active Loop 未验证 |
| unknown1 | 0 | `0x00010000` | Memory PCPT 必须生成 |
| `cueType` | 1 | 1 | 普通 Cue 可克隆 |
| unknown2 / unknown3 | 0 / 1000 | 0 / 1000 | 相同，语义未知 |
| startTime | 245 / 76,435 | 245 / 76,435 | 精确保留 |
| loopTime | `0xffffffff` | `0xffffffff` | 普通 Cue 相同 |
| 16 字节尾部 | 全 `ff` | 全 `00` | Memory PCPT 必须生成，不能克隆 Hot 尾部 |

Memory PCOB 的物理条目顺序是 C → A，而不是 EXT Memory PCO2 的 A → C：

- C：`orderFirst=0xffff`, `orderLast=1`
- A：`orderFirst=0`, `orderLast=0xffff`

这形成索引链 C(index 0) → A(index 1)。样本只能确认该链与当前 DAT 的物理顺序一致；无法确认它代表创建顺序、界面顺序还是其他顺序，不能据此实现通用排序规则。

PCOB：`count=2`、`memoryCount=1`。先前另一个两 Cue 样本也是该组合，但仍不足以证明任意数量时 `memoryCount=count-1`；空 EXT Memory PCOB 的 `memoryCount=0xffffffff` 只能作为另一个观测值。

### 写入器结论

本轮不实现实验性普通 Cue 写入器，原因是用户要求“克隆完整未知字段和 trailing，只修改已确认字段”，而真实 A/C 样本证明 Memory PCP2/PCPT 的未知定位字段与尾部必须由 Rekordbox 重新生成，并非来源 Hot 数据的原样克隆。尤其是 PCP2 `+0x34` 和 trailing 首 UInt32 随 Cue 改变，但生成算法尚不明确；DAT 的 PCPT 顺序链与 `memoryCount` 通用规则也未由两条样本确认。

直接复制 Hot 未知字段会产生与两组真实 Memory Cue 都不一致的结构。为了不猜测，本阶段停止在无损解析、精确差分和回归样本测试，不产生任何实验输出副本。`exportLibrary.db.cue` 写入继续暂停。

## 2026-07-21：FLAC frame locator 假设验证

只读输入：

- 音频：`<local-test-audio>/Vanderkraft - Onirisme Nocturne.flac`
- 音频 SHA-256：`275a99c0360b63ba7613042c2d2cd69a4b77edd83125189f7de6bbf2221b61c5`
- 配对 DAT/EXT：上一节所列当前 U 盘只读文件。
- 补充报告：`Rekordbox Memory Cue Reverse Engineering Status.pdf`。

### FLAC 流结构

- 原生 FLAC，44,100 Hz、24-bit、双声道、总样本数 19,177,174。
- STREAMINFO 的 minimum/maximum block size 均为 1024。
- metadata blocks：STREAMINFO(34)、SEEKTABLE(7,830)、VORBIS_COMMENT(40)、PICTURE(3,341,530)、PADDING(80,970)。
- 包含 `fLaC` marker 和每个 metadata block 的 4 字节头后，首个音频 frame 的文件绝对偏移为 `3,430,428`。
- A/C 所在 frame 的 blocking strategy 均为 fixed-block；frame header 使用 frame number。解析器同时保留 variable-block 分支，此时 UTF-8 coded number 按首样本号解释。
- 两个目标 frame 的 header CRC-8（polynomial `0x07`）均校验通过：A 存储 CRC `0x2a`，C 存储 CRC `0xdd`。

### A：245 ms

- 目标样本：`floor(245 × 44,100 / 1,000) = 10,804`。
- 所在 frame number：10。
- frame 样本范围：`[10,240, 11,264)`。
- block size：1,024 samples。
- frame 文件绝对偏移：3,455,269。
- frame 相对首音频 frame 偏移：`3,455,269 - 3,430,428 = 24,841`。
- ANLZ PCP2 `+0x34`：10,240，吻合 frame 首样本。
- ANLZ PCP2 `+0x44`：24,841，吻合相对音频流偏移；不等于绝对文件偏移。
- ANLZ PCP2 `+0x50`：1,024，吻合 block size。

### C：76,435 ms

- 目标样本：`floor(76,435 × 44,100 / 1,000) = 3,370,783`。
- 所在 frame number：3,291。
- frame 样本范围：`[3,369,984, 3,371,008)`。
- block size：1,024 samples。
- frame 文件绝对偏移：17,228,210。
- frame 相对首音频 frame 偏移：`17,228,210 - 3,430,428 = 13,797,782`。
- ANLZ PCP2 `+0x34`：3,369,984，吻合 frame 首样本。
- ANLZ PCP2 `+0x44`：13,797,782，吻合相对音频流偏移。
- ANLZ PCP2 `+0x50`：1,024，吻合 block size。

### 字段命名结论

两条独立 Cue 的三个关键值全部逐项吻合，偏移基准也由 metadata 结束位置明确。因此对于这个实际 FLAC，可将字段命名为：

| PCP2 相对偏移 | Swift 字段 | 已验证含义 |
|---:|---|---|
| `+0x34` | `decodingStartFramePosition` | 包含 Cue 的 FLAC frame 首样本位置 |
| `+0x44` | `fileOffsetInBlock` | 目标 frame 相对首个音频 frame 的字节偏移 |
| `+0x50` | `numberOfSamplesInBlock` | 目标 FLAC frame 的 block sample count |

`+0x38…+0x43`、`+0x48…+0x4f`、`+0x54…+0x57` 在本样本仍为零，语义未知，继续原样保存。

### 工程抽象和写入边界

新增 `AudioCueLocating`、统一结果 `AudioCueLocation` 和独立实现 `FLACAudioCueLocator`。FLAC 实现：

- 解析 metadata 直到 last-metadata 标志，确认首音频 frame 绝对偏移；
- 读取 STREAMINFO 与可选 SEEKTABLE；
- 解析 fixed/variable blocking strategy、UTF-8 frame/sample number、block size 和显式 sample-rate 字段；
- 验证 frame header CRC-8；
- 同时返回绝对文件偏移和相对音频流偏移，避免混用基准。

没有为 MP3、WAV 或 AIFF 提供实现，它们必须使用各自独立且经过验证的 locator。

FLAC locator 三元组已经验证，但本轮仍未启用实验写入器。原因不是 FLAC locator，而是完整输出仍依赖尚未确认的 DAT PCPT 通用顺序链/`memoryCount` 规则，并且本轮明确不建立评论和颜色转换规则。为避免把未验证部分混入真实 ANLZ，继续只提供定位器和测试，不创建输出副本。数据库写入保持暂停。
