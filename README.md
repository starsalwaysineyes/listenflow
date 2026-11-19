<div align="center">

<img src="docs/images/icon.png" width="112" alt="听流图标">

# 听流 · ListenFlow

**把会议、网课和线下课堂的声音，在你自己的 Mac 上实时变成文字。**

截屏跟着时间存进记录，会后一键整理成稿，你的 agent 能直接读。默认用豆包云端流式识别，边说边出字；也可以切到本地模型，语音不出本机。

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](#安装)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20及以后-2f6f5e)](#安装)
[![Swift](https://img.shields.io/badge/SwiftUI-原生-F05138?logo=swift&logoColor=white)](outputs/ListenFlow/Sources)
[![ASR](https://img.shields.io/badge/识别-豆包流式%20·%20可切本地%20Qwen3--ASR-4b5bd6)](#它是怎么工作的)
[![Release](https://img.shields.io/github/v/release/starsalwaysineyes/listenflow?label=下载&color=2f6f5e)](https://github.com/starsalwaysineyes/listenflow/releases/latest)

[下载](https://github.com/starsalwaysineyes/listenflow/releases/latest) · [详细手册](outputs/ListenFlow/README.md) · [实测记录](outputs/ListenFlow/TESTING.md)

</div>

<br>

<p align="center">
  <img src="docs/images/main-window.png" alt="听流主窗口：左侧上面是分组、下面是最近的会话，右侧是转写正文，同一个人连着说的话合成一段，按来源标出电脑声音与麦克风，截屏出现在它发生的时间位置" width="100%">
</p>

<p align="center"><sub>截图中的会议内容为演示用虚构数据。</sub></p>

## 亮点

<table>
<tr>
<td width="50%" valign="top">

### 🎧 打开就录，也可以只听一个 App
默认「全局」：电脑上所有 App 的声音和麦克风一起录，线上会议里对方和你说的话都有，每句标出来源；外放时麦克风录到的回声会自动去掉。只想听腾讯会议或某个播放器时选「指定 App」，提示音、其他窗口的视频不会混进来。线下场景切到麦克风。

</td>
<td width="50%" valign="top">

### ☁️ 云端出字快，本地不出本机
默认用火山引擎豆包流式识别：说话不到 1 秒就出字，一句说完由服务端再识别一遍定稿。这时**音频会发送到火山引擎**。想让语音留在本机或没有网络时，在设置里切到本地 Qwen3-ASR 1.7B（MLX，Apple Silicon）。

</td>
</tr>
<tr>
<td valign="top">

### ✂️ 在停顿处切，而不是硬切
本地模型按滚动底噪判断讲话的间隙，只看 200 Hz 以上的能量，空调、风扇的低频嗡声不会让它误判。豆包引擎由服务端断句，同一套判断只用来决定什么时候有人说话：静音不上传、不计费。

</td>
<td valign="top">

### 🔁 先出字，再变准
豆包引擎自带二遍识别：灰色预览先出，句子结束后换成定稿。本地模型的高精度档先实时出短片段，再把约 20 秒的内容合起来重新识别、整行替换。会后点「精修全文」再过一遍整场：豆包引擎把保存的录音交给录音文件识别，本地模型按 30 秒一段在本机重识别。

</td>
</tr>
<tr>
<td valign="top">

### 📸 截屏跟着时间走，会后成稿
按 `⇧⌘J`（或点灵动岛上的按钮）截下整个屏幕，图片按时间插在转写中间：这页幻灯片是讲到哪一句时出现的，回看和让 agent 读的时候都一目了然。位置不对可以把图拖到别的段落前后，多截的可以单张删掉。整理稿把碎片化转写合成连贯段落，增量更新，已定稿的部分不会被改写。

</td>
<td valign="top">

### 🏝️ 刘海灵动岛
鼠标移到刘海，最近的转写从屏幕顶部展开；可以固定展开、拖动调高度、调宽度。**不会出现在屏幕共享和截图里**，共享屏幕时别人看不到你在转写什么。

</td>
</tr>
<tr>
<td valign="top">

### 🤖 让你的 agent 也听得到
`lstf` 命令让 Claude Code、Codex 这类 agent 读到正在录的这场会和所有历史会话：像读文件一样按行号翻页，截屏的图片路径按时间夹在句子中间，可以搜索，可以给会话改名，可以看分组、建分组、把会话归到分组，可以对还没精修的会话启动精修，还可以自己写一份整理稿存回这场会话；不能删除会话。说一句「`lstf --help` 查一下刚才会上定的截止时间」，它读完帮助就知道怎么取。不能替你开始或停止录制。

</td>
<td valign="top">

### 🔤 热词：人名和术语的正确写法
把容易被认成同音字的人名、产品名、术语加进热词表，识别时优先往这些词上靠。在设置里增删，或者让 agent 用 `lstf hotword add` 当场加上；录制中改了，从下一段讲话起生效。已经在火山引擎控制台建过热词表的，也可以填它的 ID。

</td>
</tr>
</table>

## 刘海灵动岛

<p align="center">
  <img src="docs/images/notch-island.png" alt="刘海灵动岛展开时的样子：计时、暂停、电平、固定按钮，下方是带时间戳和来源标签的最近转写" width="88%">
</p>

- 收起时什么都不显示，也不挡鼠标；可选「收起时常亮显示最新一句」。
- 最新一句最亮，越早越淡；虚线以下是还没合并重识别的实时片段。
- 展开后右上角有截屏按钮（下图是加这个按钮之前截的）。
- 宽度可在设置里调（480–1100 pt），14 寸、16 寸屏都合适；没有刘海的屏幕显示在顶部正中。

## 它是怎么工作的

```mermaid
flowchart LR
    A["全部 App 或指定 App 的声音<br/>ScreenCaptureKit"] --> C
    B["麦克风<br/>AVAudioEngine"] --> C
    C["16 kHz 单声道"] -->|"默认：有人说话时<br/>流式上传"| V[("豆包流式识别<br/>火山引擎")]
    V -->|"实时预览 + 定稿分句"| E["实时转写"]
    C -->|"可选：按停顿切段"| D["本地 Qwen3-ASR<br/>MLX · 常驻进程"]
    D --> E
    E -->|"本地：高精度档 / 事后精修"| F["合并 20–30 秒<br/>重新识别并替换"]
    F --> E
    C -.->|"豆包：讲话片段保存在本机"| R[("豆包录音文件识别")]
    R -.->|"会后精修全文"| E
    E --> G["灵动岛"]
    S["截屏 ⇧⌘J"] -->|"按时间插入"| E
    E --> H["lstf：agent 按行读取"]
    E --> I["整理稿 · Markdown 导出"]
    I -.->|"文字和选中的图片"| J[("你配置的 LLM API")]
```

### 实测

豆包引擎（30 秒讲课式语音经真实 app 流程回放）：开始说话后约 0.8 秒出现第一段预览，句子结束后约 0.5 秒定稿；暂停时正在说的半句不丢；连接中途断开会自动重连并补发未定稿的音频。

豆包引擎会后「精修全文」（269 秒带底噪语音，1322 字，单次测试）：实时结果错 27 个字，精修后 21 个；实时结果里被服务端每 20 秒强制切开的长句，精修后按语义重新断句。上传后约 29 秒返回。

本地模型：2224 字中文语音、带底噪，经真实 app 流程回放，统计错字数（越少越好）：

| 方案 | 有底噪 | 快语速、几乎无停顿 |
| --- | ---: | ---: |
| 早期版本：固定 4 秒硬切 | 121 | 127 |
| **省电**：在停顿处切，每段识别一次 | 72 | 90 |
| **高精度**：实时出字 + 约 20 秒合并重识别 | **58** | **59** |
| 省电录完 → **事后精修**（30 秒窗口） | 67 | 60 |

省电档约占 7.5% 的 GPU 时间，高精度约 13%。「自动」档接电源时用高精度，用电池或低电量模式时用省电。测试方法和更多数据见 [TESTING.md](outputs/ListenFlow/TESTING.md)。

## 安装

> 需要 Apple Silicon（M1 及以后）的 Mac，macOS 15 或更新。

1. （只在要用本地模型时需要）**准备识别环境**并下载模型（约 2 GB）：

   ```sh
   python3.12 -m venv ~/listenflow-venv
   ~/listenflow-venv/bin/pip install mlx-audio
   ~/listenflow-venv/bin/python -c "from mlx_audio.stt.utils import load_model; load_model('mlx-community/Qwen3-ASR-1.7B-8bit')"
   ```

2. 从 [Releases](https://github.com/starsalwaysineyes/listenflow/releases/latest) 下载 zip，解压后把「ListenFlow」拖进「应用程序」。
3. 这一版没有经过 Apple 公证，第一次打开前在终端执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/ListenFlow.app
   ```

4. 打开听流 →「设置」（`⌘,`），选识别引擎：
   - **豆包（云端，默认）**：填入火山引擎豆包语音的 API Key；资源 ID 默认是流式识别 2.0 小时版 `volc.seedasr.sauc.duration`，按送入的音频时长计费。会后「精修全文」用的是录音文件识别（`volc.seedasr.auc`，同一个 Key，另外计费），两项都要在控制台开通。
   - **本地模型**：把 Python 路径填成 `~/listenflow-venv/bin/python` 的完整路径，等左下角出现「本地模型已就绪」。
5. 第一次转写时按提示允许「屏幕与系统音频录制」和「麦克风」。
6. 想用整理稿，再填一个兼容 `chat/completions` 的 API（默认 DeepSeek）。只做转写可以不填。
7. （可选）想让 agent 读转写，把命令行工具链接到 PATH 里：`ln -s /Applications/ListenFlow.app/Contents/MacOS/lstf ~/.local/bin/lstf`，然后 `lstf --help`。

## 使用

| 场景 | 做法 |
| --- | --- |
| 腾讯会议、网课 | 用默认的「全局」，直接开始转写；只想听一个 App 时选「指定 App」 |
| 线下课堂、线下会议 | 来源选「我的麦克风」，`⌥⌘R` 开始 |
| 全局声音下暂时不录自己这边 | 点右上角圆形的麦克风按钮；开始前、录制中都可以关，再点一下恢复 |
| 想记下板书或 PPT | `⇧⌘J` 截下整个屏幕，图片按时间存进这场会话 |
| 人名、术语总是识别错 | 设置最上面的热词表里加上正确的写法 |
| 会后 | 「精修全文」重识别 →「整理稿」成稿 → 导出 Markdown |
| 把同一类的会放在一起 | 在会话上右键「移到分组」；分组显示在列表上方，会话同时还在「最近」里。也可以让 agent 用 `lstf group move 分组名` |
| 会话名太长看不全 | 左右拖动列表和正文中间的分隔线；双击回到默认宽度 |
| 给一场会起个好找的名字 | 点主窗口顶部的会话名直接改，或在列表里右键「改名…」；也可以让 agent 用 `lstf rename 新名字` |
| 删掉一场不要的会话 | 在列表里右键「删除…」；文件进废纸篓，它的录音直接删除 |
| 让 agent 来写整理稿 | 对它说「用 `lstf` 把这场会整理成稿存回去」；它读完转写，写好后用 `lstf draft write` 存进会话，「整理稿」页里就能看到 |
| 把某一场历史会话交给 agent | 在会话上右键「复制给 agent 的命令」，贴给它：剪贴板里是一行 `lstf info <会话 ID>` |
| 把别处的图放进会话 | 复制图片后在听流窗口里按 `⌘V`；之后可以拖到对应的段落旁边 |
| 让 agent 用会议内容 | 对它说「`lstf --help`，然后……」；常用的是 `lstf read --minutes 5`、`lstf list`、`lstf search 关键词` |

| 快捷键 | 作用 |
| --- | --- |
| `⌥⌘R` | 全局：开始 / 暂停转写 |
| `⇧⌘J` | 全局：截下鼠标所在的整个屏幕，存进当前会话 |
| `⌘N` / `⌘,` | 新会话 / 设置 |

关掉主窗口不会停止录音，菜单栏图标常驻，本身就是录制状态指示。

## 隐私

- **音频**：取决于识别引擎，界面左下角和底栏始终标明当前是哪一种。
  - 豆包（默认）：有人说话时，音频实时发送到火山引擎识别；静音不发送。「保存录音」开启时（默认），发出去的这部分音频同时保存在本机，会后点「精修全文」会再上传一次。关闭后不在本机保存音频。
  - 本地模型：只在本机识别，音频不离开这台 Mac。「保存录音」开启时会在本机保存 16 kHz 音频用于精修。
  - 录音都在 `~/.listenflow/audio/`，只有本人可读。**精修后不删除**，一直留到你删除那场会话，以后换了更好的模型还能重新识别；每一路声音每小时讲话约 115 MB，设置里能看到总占用。可以随时手动删除。
- **文字**：会话保存在 `~/Library/Application Support/ListenFlow/`；只有整理时才发送给你配置的 API。
- **截屏**：只保存在本机（同一目录下的 `Images/<会话 ID>/`，只有本人可读），截的是整个屏幕，听流自己的窗口不在其中。只有你把某张图选作整理稿的参考图片时，它才随整理发送给你配置的 API。
- **热词**：保存在 `~/.listenflow/hotwords.txt`。豆包引擎下随识别请求发送到火山引擎。
- **密钥**：保存在 `~/.listenflow/keys.json`，明文，只有本人可读（文件权限 0600）。不使用钥匙串；旧版存在钥匙串里的密钥会在第一次用到时移到这个文件。
- **灵动岛**：不进入屏幕共享和截图。

## 从源码构建

```sh
git clone https://github.com/starsalwaysineyes/listenflow.git
cd listenflow/outputs/ListenFlow
./build.sh
```

只依赖系统框架（SwiftUI、ScreenCaptureKit、AVFoundation、IOKit），无第三方 Swift 包。需要 Swift Command Line Tools。测试命令见[详细手册](outputs/ListenFlow/README.md#测试)。

<details>
<summary><b>项目结构</b></summary>

```
outputs/ListenFlow/
├── Sources/
│   ├── CaptureEngine.swift     全部 App / 指定 App 音频 + 麦克风采集，转 16 kHz 单声道
│   ├── AudioChunker.swift      滚动底噪 + 200 Hz 高通，在停顿处切段
│   ├── Recognition.swift       识别档位、录音的保存、精修窗口与替换
│   ├── VolcProtocol.swift      豆包流式识别的帧编解码、分句去重、补发缓存、说话检测
│   ├── VolcStream.swift        每个音频来源一条豆包连接：流式上传、重连、收尾
│   ├── VolcFile.swift          豆包录音文件识别：会后把保存的录音分段上传，替换实时结果
│   ├── ASRBridge.swift         与本地 Python 识别进程的 JSON lines 管道
│   ├── NotchIsland.swift       刘海灵动岛
│   ├── ScreenshotCapture.swift 截下整个屏幕（不含听流自己的窗口）
│   ├── ImageAttachments.swift  截屏和图片的存储
│   ├── LLMClient.swift         整理稿的模型请求
│   ├── Storage.swift           设置、密钥文件、热词表、会话、后台存盘、正文合段与导出
│   ├── AgentBridge.swift       app 与 lstf 之间的状态文件和请求文件
│   └── AppModel.swift / ContentView.swift / SettingsView.swift
├── CLI/                        lstf 命令：给 agent 读转写用（随 app 一起构建，装在 app 包里）
├── Backend/asr_worker.py       常驻 MLX 模型
├── Tests/                      核心逻辑、整理与识别进程测试
└── build.sh
work/asr-lab/                   切分与精修方案的对比实验脚本
```

</details>

## 已知限制

- 外放声音时开着麦克风，回声按文字去重（同一时段两路内容重合就只留 App 那句）；你和对方同时说话时，偶尔仍会混进对方的几个字，戴耳机最干净。
- 区分「App / 电脑声音」和「麦克风」两路来源，不区分会议里的不同讲话人。
- 「全局」会录下电脑上的一切声音，包括提示音和背景音乐；豆包引擎下这些也会上传并计费。
- 远场收音时讲话只比底噪高约 10 dB，错字仍多于近距离收音；麦克风靠近说话人最有效。
- 准确率数据来自合成语音加底噪；多人插话、背景音乐、口音等情况还需要更多实测。
- 豆包引擎需要网络和可用的账户额度；连续几小时的真实课堂、两路同时长时间识别还没有实测。豆包的「精修全文」最长只用 4.5 分钟的录音测过。
- 0.11.0 的新主窗口、截屏和热词刚做完：存储和 `lstf` 的部分有测试，真实截屏、多显示器、录制中途改热词的效果还没有实测，见[详细手册](outputs/ListenFlow/README.md#当前边界)。
- 目前只在 16 寸 M1 Max MacBook Pro 上实测过。

## 致谢

- [豆包流式语音识别](https://www.volcengine.com/docs/6561/1354869)与[录音文件识别](https://www.volcengine.com/docs/6561/1354868)（火山引擎）：默认的云端识别与会后精修
- [Qwen3-ASR](https://huggingface.co/Qwen) 与 [mlx-audio](https://github.com/Blaizzy/mlx-audio)：本地语音识别
- [Notchly](https://github.com/lglglglglg/Notchly)：刘海灵动岛的交互灵感
- [DeepSeek](https://api-docs.deepseek.com/)：默认的整理接口
