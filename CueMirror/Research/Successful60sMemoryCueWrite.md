# CueMirror：60 秒绿色 Memory Cue 成功写入复盘

日期：2026-07-21

## 1. 结果摘要

本次实验成功在 U 盘中 `Vanderkraft - Onirisme Nocturne.flac` 对应的 DAT/EXT 分析文件中增加了一条普通 Memory Cue：

- 时间：60,000 ms（01:00.000）
- 类型：普通 Cue，非 Loop
- Memory Cue 颜色：默认绿色
- 原有 Hot Cue：逐字节保持不变
- 原有两个 Memory Cue：保留
- 写入前 Memory Cue：245 ms、76,435 ms
- 写入后 Memory Cue：245 ms、60,000 ms、76,435 ms
- `exportLibrary.db.cue`：没有修改
- `ANLZ0000.2EX`：没有修改

U 盘目标文件：

- `<OneLibrary-USB>/PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.DAT`
- `<OneLibrary-USB>/PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.EXT`

## 2. 写入前的安全措施

没有直接在来源文件上进行边解析边修改。实际顺序是：

1. 只读加载 U 盘 DAT、EXT 和对应 FLAC。
2. 在内存中生成新 ANLZ 数据。
3. 将结果写到 `/tmp` 的独立工作目录。
4. 对工作副本重新解析并逐字段验证。
5. 将 U 盘原 DAT/EXT 复制到工程中的可恢复备份目录。
6. 比较备份与 U 盘原文件 SHA-256，确认备份完整。
7. 将工作副本先复制为 U 盘目录中的临时名称。
8. 对临时文件计算 SHA-256，确认传输无误。
9. 最后用已验证临时文件替换正式 DAT/EXT。
10. 从 U 盘重新读取正式文件，再次进行结构解析、Cue 数量和逐字节往返验证。

写入前备份：

- `Research/Backups/Before60sMemoryCue-20260721/ANLZ0000.DAT`
- `Research/Backups/Before60sMemoryCue-20260721/ANLZ0000.EXT`

备份 SHA-256：

- DAT：`1b644d645b17f614f7497808d32606957011610cacf96d2843c7df2d2df88d66`
- EXT：`318a6f1c077eccd924b210cf4fcd5d1115cc96ffc04f77b35166c9c1c4e0c6f5`

## 3. FLAC Cue 定位

音频参数：

- Sample rate：44,100 Hz
- FLAC block size：1,024 samples
- 首个音频 frame 的文件绝对偏移：3,430,428
- Blocking strategy：fixed-block

60,000 ms 对应目标样本：

```text
targetSample = floor(60,000 × 44,100 / 1,000)
             = 2,646,000
```

包含目标样本的 FLAC frame：

- Frame number：2,583
- Frame 首样本：2,644,992
- Frame 样本范围：`[2,644,992, 2,646,016)`
- Frame 绝对文件偏移：14,067,971
- Frame 相对首音频 frame 偏移：10,637,543
- Frame block sample count：1,024

写入 PCP2 的定位三元组：

| PCP2 相对偏移 | 值 | 含义 |
|---:|---:|---|
| `+0x34` | 2,644,992 (`0x00285c00`) | `decodingStartFramePosition` |
| `+0x44` | 10,637,543 (`0x00a250e7`) | `fileOffsetInBlock`，相对首个音频 frame |
| `+0x50` | 1,024 (`0x00000400`) | `numberOfSamplesInBlock` |

这些值由 `FLACAudioCueLocator` 读取真实 FLAC metadata、frame header 和 CRC-8 后产生，不是按观察值硬编码。

## 4. EXT 的修改

修改目标是 `listType=0` 的 Memory PCO2。原 Hot PCO2 没有修改。

### PCO2

- Cue count：2 → 3
- PCO2 `totalLength`：增加 88 字节
- PMAI `totalLength`：增加 88 字节
- 新 PCO2 物理时间顺序：245 → 60,000 → 76,435 ms

### 新 PCP2

- `headerLength = 16`
- `totalLength = 88`
- `hotCueNumber = 0`
- `cueType = 1`
- `timeMs = 60,000`
- `loopTimeMs = 0xffffffff`
- `colorID = 0`
- Memory 标志相关未知字节 `+0x1d = 1`
- Loop numerator / denominator：0 / 0
- Comment：空，长度字段为 0
- Hot Cue color index / RGB：`0 / #000000`
- FLAC 定位字段：使用上一节的三个实际值

`colorID=0` 对普通 Memory Cue 表示老款 CDJ 使用的默认绿色。PCP2 评论后的 RGB 字段属于 Hot Cue 颜色信息，因此没有用 `#00ff00` 伪装 Memory Cue 颜色。

生成后的 60 秒 PCP2 原始字节：

```text
50435032000000100000005800000000010003e80000ea60
ffffffff0001000000000000000000000000000000000000
000000000000285c0000000000000000000000000000a250
e700000000000000000000040000000000
```

## 5. DAT 的修改

修改目标是 `listType=0` 的 Memory PCOB。原 Hot PCOB/PCPT 没有修改。

### PCOB

- Cue count：2 → 3
- `memoryCount`：1 → 2
- PCOB `totalLength`：增加 56 字节
- PMAI `totalLength`：增加 56 字节

### 新 PCPT

- `headerLength = 28`
- `totalLength = 56`
- `hotCueNumber = 0`
- `status = 0`
- Memory PCPT unknown1：`0x00010000`
- `cueType = 1`
- `timeMs = 60,000`
- `loopTimeMs = 0xffffffff`
- 末尾 16 字节：全零

写入前的链：

```text
C(index 0) → A(index 1) → end
```

追加后的链：

```text
C(index 0) → A(index 1) → 60s(index 2) → end
```

对应字段：

- C：`orderFirst=0xffff`, `orderLast=1`
- A：`orderFirst=0`, `orderLast=2`
- 60s：`orderFirst=1`, `orderLast=0xffff`

生成后的 60 秒 PCPT 原始字节：

```text
504350540000001c00000038000000000000000000010000
0001ffff010003e80000ea60ffffffff0000000000000000
0000000000000000
```

## 6. 写入后验证

U 盘正式文件写入后：

- DAT 大小：9,952 字节
- EXT 大小：204,832 字节
- DAT SHA-256：`b0258791cabc4aa579e801eb953f3ab1be5808e77d4cbdc03d80c1dcdfec0606`
- EXT SHA-256：`5f4afeb1153a9b5785b7cd5ab244ad678ff5dc2d5a06173faaa751967724cbe1`

回读结果：

- DAT Memory PCOB：3 条 PCPT，包含 60,000 ms。
- EXT Memory PCO2：3 条 PCP2，包含 60,000 ms。
- 新 Cue 类型为普通 Cue。
- 新 Cue `colorID=0`。
- 三个 FLAC locator 值全部正确。
- DAT、EXT 都满足 parse → write 后逐字节一致。
- 原 Hot Cue PCOB、PCO2 逐字节不变。
- 工程构建成功。
- 21 项测试通过，0 项失败，0 项跳过。

## 7. 实现文件

- `AudioCueLocator.swift`
  - `AudioCueLocating`
  - `AudioCueLocation`
  - `FLACAudioCueLocator`
- `ExperimentalFLACMemoryCueWriter.swift`
  - 只接受普通 FLAC Cue。
  - 在内存中修改 DAT/EXT。
  - 输出目录不得与来源目录相同。
  - 写后重新解析并验证。
- `AnlzFormat.swift`
  - PMAI、PCOB/PCPT、PCO2/PCP2 无损读写。
- `CueMirrorTests/FLACAudioCueLocatorTests.swift`
  - 真实 FLAC A/C locator 验证。
  - 60 秒输出副本写入验证。
  - 来源文件不变验证。

## 8. 仍然属于实验性的部分

这次成功只证明当前文件结构和普通 FLAC Cue 路径可用，不应直接推广到所有曲目：

- DAT `memoryCount=count-1` 和 PCPT 追加链目前只在有限样本中得到支持。
- 尚未验证在任意插入/删除顺序下 Rekordbox 如何重排 DAT PCPT。
- 不支持重复时间 Memory Cue；当前写入器会拒绝重复。
- 不支持 Hot Loop → Memory Loop。
- 不支持 Active Loop。
- 没有建立非空评论复制规则。
- 没有建立自定义 Memory Cue 颜色表转换规则；本次只使用已确认的默认绿色 `colorID=0`。
- MP3、WAV、AIFF 不能复用 FLAC locator。
- `exportLibrary.db.cue` 写入仍然暂停。

## 9. 恢复方法

如果播放器或 Rekordbox 无法正确识别修改后的文件，应停止继续写入，将备份目录中的 DAT/EXT 恢复到原路径。恢复时必须同时恢复两者，不能只恢复其中一个；恢复后再次计算 SHA-256，确认与本节记录的写入前哈希一致。
