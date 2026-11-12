# pond-doubao-asr

在 **Pond(niri / Wayland)** 上用 **豆包(火山引擎)语音识别**做语音听写:按一下热键开始说话,
再按一下停止,识别结果通过内置的 Wayland 虚拟键盘**直接打进当前光标位置**(不依赖 wtype)。

核心程序只和 Wayland 协议打交道(内置 `zwp_virtual_keyboard_v1` 虚拟键盘),与合成器无关;
需要改的只有热键接线和安装脚本。常见做法与本仓库的对应关系:

| 常见做法(Hyprland 等) | 本仓库(Pond / niri) |
| --- | --- |
| `~/.config/hypr/bindings.lua` 里的 `o.bind` | `~/.config/niri/cfg/keybinds.kdl` 的 `binds` 块 |
| `hyprctl reload` | `niri msg action load-config-file` |
| 发行版自带的包 / 服务封装 | 标准 systemd 用户服务 + `parecord` |

## 安装

```bash
git clone https://github.com/chenximengyi/pond-doubao-asr.git
cd pond-doubao-asr
./install.sh
```

机器上没装 Go 也行:从 [Releases](https://github.com/chenximengyi/pond-doubao-asr/releases)
下载对应架构的 `doubao-dictate-linux-<arch>`,或者指定来源让脚本自己下(fork 之后用得上):

```bash
DOUBAO_RELEASE_REPO=chenximengyi/pond-doubao-asr ./install.sh
```

脚本会做这些事:

1. 用本地 Go 编译 `doubao-dictate` 到 `~/.local/bin/`(机器上没有 Go 时才下载预编译二进制);
2. 首次安装时创建配置 `~/.config/doubao-dictate/.env`(已存在则原样保留);
3. 安装并启动 systemd **用户服务** `doubao-dictate`(登录图形会话时自动运行);
4. 把热键追加到 `~/.config/niri/cfg/keybinds.kdl` 的 `binds` 块里(修改前会备份),然后
   `niri validate` + `niri msg action load-config-file`;
5. 打印取 Key 的页面(有图形会话时顺手用浏览器打开),在**终端里等你粘贴 API Key**,
   写进 `.env`(权限 0600)并自动重启服务。

`./install.sh --no-hotkeys` 只装程序和服务、不动 niri 配置。

装完后按 `F9` 说一句、再按一次,文字就出来了。

> 脚本可重复执行(幂等):`.env` 里已有 Key 时跳过第 5 步,热键已有标记时跳过第 4 步。
> 升级 = 重跑一次。

## 获取 API Key

1. 打开豆包语音 → [服务管理](https://console.volcengine.com/speech/new/setting/activate?ResourceID=volc.service_type.10074&projectName=default)
2. 开通「流式语音识别(2.0)」。
3. 进入左下角的「API key」新建一个 **API Key**。
4. 资源 ID 用默认的 `volc.seedasr.sauc.duration`。

> 用的是新版控制台的 **X-Api-Key** 鉴权,只要 API Key + Resource ID,
> 不需要老版的 App ID / Access Token。

手动填 Key:

```bash
$EDITOR ~/.config/doubao-dictate/.env     # DOUBAO_API_KEY=<你的 key>
systemctl --user restart doubao-dictate
```

## 热键

| 热键 | 行为 |
| --- | --- |
| `F9` | 按一下开始录音,再按一下停止并开始识别 |
| `Mod + CTRL + X` | 同上(等同 `F9`) |
| `Mod + CTRL + ESCAPE` | 取消本次听写(丢弃,不出字) |

`Mod` 在 Pond 里默认是 `Super`。录音中右上角弹 `🎤 Recording`,停止后弹 `Transcribing…`,
识别完自动打字。

> 是**按一下开 / 按一下关**,不是长按说话。即使忘了停,到
> `DOUBAO_MAX_DURATION_SECS`(默认 120 秒)也会自动停。

手动测试输入效果(不需要 daemon 的麦克风流程,只要 daemon 不用也行):

```bash
doubao-dictate type "测试文字"     # 打进当前焦点窗口
```

## 配置

`~/.config/doubao-dictate/.env`(`KEY=VALUE`),模板见 `.env.example`。
查找顺序:`$DOUBAO_DICTATE_ENV` → `~/.config/doubao-dictate/.env` → 当前目录 `.env`;
真实同名环境变量优先。

| 变量 | 说明 |
| --- | --- |
| `DOUBAO_API_KEY` | **必填**,豆包 API Key |
| `DOUBAO_RESOURCE_ID` | 资源 ID,默认 `volc.seedasr.sauc.duration` |
| `DOUBAO_URL` | 识别端点,默认非流式的 `…/bigmodel_nostream`(**别改成 `bigmodel`**) |
| `DOUBAO_DEVICE` | 输入设备,默认 `default`(跟随系统默认输入源),也可写具体 pulse 源名 |
| `DOUBAO_SAMPLE_RATE` / `DOUBAO_SEGMENT_MS` | 录音参数,一般不用动 |
| `DOUBAO_MAX_DURATION_SECS` | 单次录音上限,默认 120 |
| `DOUBAO_MODE` | `type`(默认,内置 Wayland 虚拟键盘)/ `clipboard`(wl-copy) |
| `DOUBAO_TYPE_DELAY_MS` | 每个字符之间间隔(毫秒),默认 `10`;个别应用丢字可调大 |
| `DOUBAO_NOTIFY` | 桌面通知开关,默认 `true` |

改完要重启服务:`systemctl --user restart doubao-dictate`。

## 从源码构建 / 手动安装

```bash
go build -o doubao-dictate .
install -m755 doubao-dictate ~/.local/bin/
go vet ./... && go test ./...
```

依赖:`parecord`(pipewire-pulse)、可选 `notify-send`(libnotify)、niri(systemd 用户会话)。
国内拉模块卡住:`GOPROXY=https://goproxy.cn,direct go build .`

> fork 之后把 `go.mod` 的 module 名和 `install.sh` 里的 `RELEASE_REPO` 换成你自己的账号路径,
> 否则 `go install` 装出来的仍是原仓库路径。

服务与热键模板在 `deploy/`:

```bash
mkdir -p ~/.config/systemd/user
cp deploy/doubao-dictate.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now doubao-dictate

# 热键:把 deploy/niri-bindings.kdl 里的三行粘进
# ~/.config/niri/cfg/keybinds.kdl 的 binds { … } 里面
niri validate && niri msg action load-config-file
```

## 卸载

```bash
systemctl --user disable --now doubao-dictate
rm -f ~/.local/bin/doubao-dictate ~/.config/systemd/user/doubao-dictate.service
rm -rf ~/.config/doubao-dictate
systemctl --user daemon-reload
# 再删掉 ~/.config/niri/cfg/keybinds.kdl 里那段
#   // ─── Doubao dictation (managed by install.sh) ───
# 开头的三行,然后:
niri msg action load-config-file
```

## 常见问题

- **按 F9 没反应 / 没有通知**:`systemctl --user is-active doubao-dictate`,
  再看 `journalctl --user -u doubao-dictate -f`。
- **报 `compositor does not support the virtual keyboard protocol`**:niri 26.x 是支持的,
  说明当前不是 Wayland 会话或 `WAYLAND_DISPLAY` 没进 daemon 环境
  (`systemctl --user show-environment | grep WAYLAND_DISPLAY`)。
- **没有输出**:`pactl list short sources` 确认有真实输入源(只有 `*.monitor` 就是没麦克风),
  必要时把默认源切过去或改 `DOUBAO_DEVICE`。
- **ASR 错误 401 / 403**:Key 不对,或控制台没开通「流式语音识别」。
- **热键没生效**:`niri validate` 看配置是否合法;改完要
  `niri msg action load-config-file`(niri 一般会自动重载,但改的是被 include 的文件时不一定)。
- **识别重复 / 句子被截断**:确认 `DOUBAO_URL` 是 `…/bigmodel_nostream`。
- **想看详细日志**:`DOUBAO_LOG_LEVEL=debug doubao-dictate daemon`。

## 工作原理

1. 收到 `toggle`:用 `parecord` 采 16kHz 单声道 PCM,按 200ms 一块缓存在内存,状态 `recording`;
2. 再次 `toggle`(或到时长上限):结束录音;
3. 用 WebSocket 连 `DOUBAO_URL`,带 `X-Api-Key` 鉴权头;先发一帧会话配置(JSON + gzip),
   再把整段 PCM 分块发出去,最后一帧用负序号标记结束;
4. 读服务器最终包,取 `result.text`,通过内置 Wayland 虚拟键盘(`zwp_virtual_keyboard_v1`)
   打进焦点窗口:文字只落在可打印键位,超过 48 个不同字符时按段自动重连
   (`DOUBAO_MODE=clipboard` 时改用 `wl-copy`);
5. 状态回到 `idle`。

daemon 只通过 `$XDG_RUNTIME_DIR/doubao-dictate.sock` 上的文本命令控制
(`start` / `stop` / `toggle` / `cancel` / `status`),niri 的热键就是拿
`doubao-dictate` 这个客户端去发命令。

| 位置 | 作用 |
| --- | --- |
| `~/.local/bin/doubao-dictate` | 主程序(单文件二进制) |
| `~/.config/doubao-dictate/.env` | 配置(含 API Key,权限 600) |
| `~/.config/systemd/user/doubao-dictate.service` | 常驻守护进程 |
| `~/.config/niri/cfg/keybinds.kdl` | 热键绑定(片段,由 install.sh 插入) |

## 许可

[MIT](LICENSE)。
