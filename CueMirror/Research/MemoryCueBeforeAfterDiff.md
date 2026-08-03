# Memory Cue Before / After 差分研究

研究时间：2026-07-21  
Before：`<local-before-directory>`  
After：`<OneLibrary-USB>`

## 安全边界

- 对 Before 和 After 只进行了目录枚举、大小读取、SHA-256、二进制读取和只读复制。
- 没有修改、重命名、删除或格式化任何来源文件。
- `exportLibrary.db` 先复制到 `/tmp/cuemirror-memory-diff/{before,after}`，再以 SQLCipher `mode=ro` 分析。
- 两侧都没有 `exportLibrary.db-wal` 或 `exportLibrary.db-shm`。
- 未运行 CueMirror 写入功能。

## 1. 完整目录树差分

Before 有 6 个文件，After 有 124 个文件。以相对路径对齐后，共有 118 个 After 新增文件，0 个删除文件，3 个同路径但内容哈希变化的文件。

### 内容变化的业务文件

| 相对路径 | Before 大小 | After 大小 | Before SHA-256 | After SHA-256 |
|---|---:|---:|---|---|
| `PIONEER/rekordbox/exportLibrary.db` | 131072 | 131072 | `1c3478832ba9e63869d1f999a890bf7e7094e265c98fc707a029617534a30c27` | `b3c7349d8f074ad82bddb439312896d2a78aa35ed795cff3b306d543f9d03003` |
| `PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.DAT` | 9784 | 9896 | `8ddee3dbfe7ddcdad1242b440fa6caf9e05e54a9197c87fa50fb548600015305` | `5b7d4befffb51e92d7f97afd91949eb34d9874643f38e8b0ce3bc74dbe7d19c3` |
| `PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.EXT` | 204524 | 204744 | `020ad3bab67307b6c82b7c135087db624fa87de8ae527fe09c3064f6ba58cac4` | `7fff566fd6c310b03b947a0d8a586b2d6e6d1bdd79e29fdda3479282f4c9bf79` |

### 相同且未变的 Before 业务文件

- `ANLZ0000.2EX`：大小 199508，两侧 SHA-256 均为 `e9cb36eb69abf50d92122e982706fc812793f0077761abdfac583eb5b367aa1c`。
- FLAC 音频和 `Artwork/00001/b1.jpg` 的路径、大小和内容相同。

### After 新增文件

118 个新增项的分类如下：

- 91 个 `.Spotlight-V100/...` macOS Spotlight 索引文件。
- 1 个 `.fseventsd/fseventsd-uuid`。
- 2 个 `System Volume Information` 文件。
- 16 个 `._*` AppleDouble 资源叉文件。
- 8 个其他 Pioneer 业务/设置文件：
  - `PIONEER/DEVSETTING.DAT`
  - `PIONEER/DJMMYSETTING.DAT`
  - `PIONEER/MYSETTING.DAT`
  - `PIONEER/MYSETTING2.DAT`
  - `PIONEER/djprofile.nxs`
  - `PIONEER/extracted/gcred.dat`
  - `PIONEER/rekordbox/export.pdb`
  - `PIONEER/rekordbox/exportExt.pdb`

这些新增文件不能仅根据本次对比归因为“新增两个 Memory Cue”；Before 显然是一个只包含 6 个主要文件的精简副本，而 After 是完整挂载卷。

## 2. exportLibrary.db 差分

### 数据库格式

`exportLibrary.db` 是 SQLCipher 4 加密 SQLite，不是普通 SQLite。两个副本使用相同的 OneLibrary 只读解密方式成功查询。

### Schema

两侧 schema 相同，包含表：

`album`, `artist`, `category`, `color`, `content`, `cue`, `djay_content`, `djay_migrations`, `genre`, `history`, `history_content`, `hotCueBankList`, `hotCueBankList_cue`, `image`, `key`, `label`, `menuItem`, `myTag`, `myTag_content`, `playlist`, `playlist_content`, `property`, `recommendedLike`, `sort`。

本研究相关的完整 schema：

```sql
CREATE TABLE content (
  content_id integer PRIMARY KEY, title varchar, titleForSearch varchar,
  subtitle varchar, bpmx100 integer, length integer, trackNo integer,
  discNo integer, artist_id_artist integer, artist_id_remixer integer,
  artist_id_originalArtist integer, artist_id_composer integer,
  artist_id_lyricist integer, album_id integer, genre_id integer,
  label_id integer, key_id integer, color_id integer, image_id integer,
  djComment varchar, rating integer, releaseYear integer, releaseDate varchar,
  dateCreated varchar, dateAdded varchar, path varchar, fileName varchar,
  fileSize integer, fileType integer, bitrate integer, bitDepth integer,
  samplingRate integer, isrc varchar, djPlayCount integer,
  isHotCueAutoLoadOn integer, isKuvoDeliverStatusOn integer,
  kuvoDeliveryComment varchar, masterDbId integer, masterContentId integer,
  analysisDataFilePath varchar, analysedBits integer, contentLink integer,
  hasModified integer, cueUpdateCount integer,
  analysisDataUpdateCount integer, informationUpdateCount integer
);

CREATE TABLE cue (
  cue_id integer PRIMARY KEY, content_id integer, kind integer,
  colorTableIndex integer, cueComment varchar, isActiveLoop integer,
  beatLoopNumerator integer, beatLoopDenominator integer,
  inUsec integer, outUsec integer, in150FramePerSec integer,
  out150FramePerSec integer, inMpegFrameNumber integer,
  outMpegFrameNumber integer, inMpegAbs integer, outMpegAbs integer,
  inDecodingStartFramePosition integer, outDecodingStartFramePosition integer,
  inFileOffsetInBlock integer, OutFileOffsetInBlock integer,
  inNumberOfSampleInBlock integer, outNumberOfSampleInBlock integer
);
```

### cue 表

- Before：0 行。
- After：0 行。
- 新增、删除、修改的 `cue` 行：均为 0。
- 因此本次手工增加的两个 Memory Cue **没有写入 `exportLibrary.db.cue`**。
- 本样本无法提供 Memory Cue 的 `cue_id`, `kind`, `inUsec`, `outUsec`, `colorTableIndex`, `cueComment`, Loop 和 150 fps 字段的实例值。

### content 表变化与 ANLZ 映射

唯一曲目：

- `content_id = 1`
- title：`Vanderkraft - Onirisme Nocturne`
- path：`/Contents/Vanderkraft/Onirisme/Vanderkraft - Onirisme Nocturne.flac`
- `analysisDataFilePath = /PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.DAT`
- 因此明确映射到本次变化的 `ANLZ0000.DAT` 及同目录同基名 `ANLZ0000.EXT`。

`content_id=1` 只有两个字段变化：

| 字段 | Before | After |
|---|---:|---:|
| `masterDbId` | 0 | 3000546302 |
| `masterContentId` | 0 | 107700687 |

`cueUpdateCount`, `analysisDataUpdateCount`, `informationUpdateCount` 前后均为 `NULL`。

### 数据库其他变化

- `category`：21 → 22 行；有 4 行新增、3 行删除、6 行修改。变化为菜单项、顺序和可见性，不是 Cue 数据。
- `myTag`：0 → 28 行，新增的是 Genre / Components / Situation 等 My Tag 定义，不是 Cue 数据。
- `property`：原行 `deviceName="Perple 128", myTagMasterDBID=0` 被替换为 `deviceName="", myTagMasterDBID=2168740311`；其余值未变。
- 其他表的规范化行集合前后相同。

上述数据库变化与两个 Memory Cue 没有外键或行级对应，因此只能确认它们发生在同一 Before/After 区间，不能将其归因为 Cue 操作。

## 3. ANLZ0000.EXT 差分

### 区块结构

Before：

```text
PPTH, PWV3, PWV4, PWV5, PCOB(hot, 584), PCO2(hot, 748), PQT2
```

After：

```text
PPTH, PWV3, PCOB(hot, 584), PCOB(memory, 24),
PCO2(hot, 748), PCO2(memory, 196), PQT2, PWV5, PWV4
```

PMAI：

- headerLength：前后均为 28。
- totalLength：204524 → 204744，增加 220 字节。
- 原有 PPTH/PWV3/PWV4/PWV5/PCOB/Hot PCO2/PQT2 各区块自身 SHA-256 完全不变，但 After 重新排列了区块顺序。
- 新增的 220 字节精确由一个 24 字节的空 Memory PCOB 和一个 196 字节的 Memory PCO2 组成。

### 原 Hot Cue PCO2

- Before offset 203720；After offset 66040。
- `headerLength = 20`
- `totalLength = 748`
- `listType = 1`
- `cueCount = 13`
- 前后整个 748 字节区块 SHA-256 相同：`95fd56c7851e2ad28eed660b9c7fd08a8e9fea472be1150e997d3fd9ceb34085`。
- 结论：原 HC01–HC13 没有被修改。

### 新 Memory Cue PCO2

- After offset：66788 (`0x104E4`)
- 原始头：`50 43 4F 32 00 00 00 14 00 00 00 C4 00 00 00 00 00 02 00 00`
- `headerLength = 20`
- `totalLength = 196`
- `listType = 0`
- `cueCount = 2`
- 区块长度等式：`20 + 88 + 88 = 196`。

#### PCP2 #1

- offset：66808 (`0x104F8`)
- `headerLength = 16`
- `totalLength = 88`
- `hotCueNumber = 0`（Memory Cue）
- `cueType = 1`（普通 Cue）
- 开始时间：277866 ms = 277866000 µs = 4:37.866
- `loopTime = 0xFFFFFFFF`（非 Loop）
- `color_id = 0`
- Loop numerator / denominator：0 / 0
- 评论长度：0，评论为空
- color code / RGB：0 / `#000000`（本样本表示未指定颜色，不应视为用户选择了黑色）

#### PCP2 #2

- offset：66896 (`0x10550`)
- `headerLength = 16`
- `totalLength = 88`
- `hotCueNumber = 0`
- `cueType = 1`
- 开始时间：306914 ms = 306914000 µs = 5:06.914
- `loopTime = 0xFFFFFFFF`
- `color_id = 0`
- Loop numerator / denominator：0 / 0
- 评论长度：0，评论为空
- color code / RGB：0 / `#000000`（未指定颜色）

#### PCP2 未知尾部

两个 PCP2 在通用的 48 字节 Cue/评论/颜色区域后都有 40 字节尾部。已观察到：

| PCP2 相对偏移 | Cue #1 | Cue #2 | 状态 |
|---:|---:|---:|---|
| +48 | 0 | 0 | 未知 |
| +52 | `0x00BAF800` | `0x00CE8400` | 未知，值随时间变化 |
| +56, +60, +64 | 0 | 0 | 未知/保留 |
| +68 | `0x030C1079` | `0x035E554A` | 未知，值随时间变化 |
| +72, +76 | 0 | 0 | 未知/保留 |
| +80 | `0x00000400` | `0x00000400` | 未知常量 |
| +84 | 0 | 0 | 未知/保留 |

这些值很可能与音频定位/解码块有关，但本次只有两个非 Loop、无评论、无颜色样本，无法从差分单独确认字段语义，故全部标为“未知”。

## 4. ANLZ0000.DAT 差分

DAT 没有 PCO2，实际变化是旧式 Memory Cue `PCOB/PCPT`。

- PMAI `headerLength = 28`，前后不变。
- PMAI `totalLength`：9784 → 9896，增加 112 字节。
- 原有 PPTH/PVBR/PQTZ/PWAV/PWV2/第一个 Hot Cue PCOB 全部逐字节不变。
- offset 9760 处的 Memory PCOB：
  - `headerLength = 24`
  - `totalLength`：24 → 136
  - `cue_type = 0` (memory)
  - `count`：0 → 2
  - `memory_count`：0 → 1
  - 后面新增 2 个 56 字节 PCPT；`24 + 56 + 56 = 136`。

PCPT 顺序为 306914 ms、277866 ms，并通过 `order_first/order_last` 字段建立顺序链；它与 EXT Memory PCO2 的物理条目顺序不同。两条均为：

- `hot_cue = 0`
- `status = 0`
- 固定字段 `u1 = 0x00010000`
- `cueType = 1`
- 固定时间基值 `u2 = 1000`
- `loopTime = 0xFFFFFFFF`
- 尾部 16 字节为 0

这证明当前生成方式不只写 PCO2，还同时写了 DAT 的 PCOB 兼容数据。

## 5. 已确认的 Memory Cue 写入结构

1. 对本样本，Memory Cue 同时出现在：
   - DAT：`PCOB(list type memory) + 2 × PCPT`
   - EXT：空 Memory `PCOB` + `PCO2(listType=0) + 2 × PCP2`
2. EXT 的 Memory PCO2 头是 20 字节，cue count 是头内大端 UInt16。
3. 本样本的 Memory PCP2 每条 88 字节，hotCueNumber 固定为 0，开始和 Loop 时间为毫秒大端 UInt32。
4. 两个新 Cue 的时间精确为 277866 ms 和 306914 ms。
5. 原 Hot Cue PCO2 的内容哈希不变，证明新增 Memory Cue 不需要修改 Hot Cue 条目。
6. 写回后的 EXT 区块发生了规范化重排，不是简单把 PCO2 附加到文件末尾。
7. 本次没有在 OneLibrary `cue` 表中写入任何行。

## 6. 仍缺少的信息

- 有评论的 Memory PCP2，用于验证 UTF-16BE BOM、空终止和 `totalLength` 对齐。
- 有显式颜色的 Memory Cue，用于确认 `color_id`, color code 和 RGB 的写入惯例。
- Memory Loop 样本，用于确认 Loop 类型、结束时间、numerator/denominator 和 Active Loop。
- PCP2 +48…+87 的 40 字节定位/解码尾部的精确字段定义及生成方法。
- 一个确实将 Memory Cue 写入 `exportLibrary.db.cue` 的 Before/After 样本，用于确认 `cue_id`, `kind`, 微秒、150 fps、颜色、Loop 和计数更新的实际值。
- 更多曲目和已存在 Memory Cue 的样本，用于确认 EXT 区块规范化排序是固定规则而非本次设备的附带行为。

## 7. 是否足以开始真实写入器

**足以开始实现严格限定于该样本的 ANLZ 结构构建、回读验证和 fixture 测试，但不足以实现项目目标中的完整真实写入器。**

原因：

- 当前只验证了无评论、无颜色、非 Loop 的两个 Cue。
- 40 字节 PCP2 尾部尚未解析，不能随意置零或伪造。
- 本次数据库 `cue` 表无任何样本行，无法完成双写规则和数据库回读验证。
- 实际文件表明 PCOB 是该生成链路的一部分；是否必须写 PCOB 需纳入目标设备兼容性设计。
