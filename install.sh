#!/usr/bin/env bash
#
# One-click installer for pond-doubao-asr (Pond / niri / Wayland).
#
# Installs the doubao-dictate binary, its config, the systemd user service and
# the niri hotkey bindings. Everything is user-scoped (no sudo) and the script
# is safe to re-run: an existing .env is never overwritten and the hotkey block
# is added only once.
#
#   ./install.sh                 # build from this checkout (needs Go >= 1.23)
#   ./install.sh --no-hotkeys    # skip the niri keybinding step
#
# After installing, put your Doubao API key in ~/.config/doubao-dictate/.env.

set -euo pipefail

# Prebuilt binaries are only used when Go is unavailable. The default points at
# the repo that publishes the release assets; override it for a fork, either
# directly or through the environment:
#
#   RELEASE_REPO="owner/pond-doubao-asr"
#   DOUBAO_RELEASE_REPO="owner/pond-doubao-asr" ./install.sh
RELEASE_REPO="${DOUBAO_RELEASE_REPO:-chenximengyi/pond-doubao-asr}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/doubao-dictate"
CONF_DIR="$HOME/.config/doubao-dictate"
ENV_FILE="$CONF_DIR/.env"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/doubao-dictate.service"
NIRI_DIR="$HOME/.config/niri"
NIRI_BINDS="$NIRI_DIR/cfg/keybinds.kdl"

DO_HOTKEYS=1
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      cat <<'USAGE'
pond-doubao-asr 安装脚本 (Pond / niri)

用法:
  install.sh                 安装或升级(优先本地编译,可重复执行)
  install.sh --no-hotkeys    跳过写入 niri 热键
  install.sh --help          显示本帮助

会安装:doubao-dictate 二进制、systemd 用户服务、niri 热键(F9 / Mod+CTRL+X)。
装完会提示你粘贴豆包 API Key(也可以直接回车跳过,之后再填)。
全程用户级操作,不需要 sudo。

环境变量:
  DOUBAO_RELEASE_REPO   机器上没有 Go 时,从哪个仓库(owner/name)取预编译二进制

API Key 获取:https://console.volcengine.com/speech/
USAGE
      exit 0
      ;;
    --no-hotkeys) DO_HOTKEYS=0 ;;
    *) printf '错误: 未知参数 %s\n' "$arg" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf '错误: %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) fail "不支持的架构: $(uname -m)(只支持 linux amd64/arm64)" ;;
esac

mkdir -p "$BIN_DIR"

# ---- 1. the binary ------------------------------------------------------
if [ -f "$SCRIPT_DIR/go.mod" ] && command -v go >/dev/null 2>&1; then
  say "从源码编译…"
  ( cd "$SCRIPT_DIR" && go build -trimpath -ldflags="-s -w" -o "$BIN" . ) || {
    # proxy.golang.org is unreachable from most networks here; retry via mirror.
    say "直连模块代理失败,改用 goproxy.cn 重试…"
    ( cd "$SCRIPT_DIR" && GOPROXY=https://goproxy.cn,direct go build -trimpath -ldflags="-s -w" -o "$BIN" . ) ||
      fail "编译失败,请检查 Go 环境或手动 go build"
  }
  chmod 755 "$BIN"
else
  [ -n "$RELEASE_REPO" ] || fail "没找到 Go(需要 1.23+),且没指定预编译二进制的来源。三选一:
  1. 装好 Go 后重跑:./install.sh
  2. 指定发布 Release 的仓库:DOUBAO_RELEASE_REPO=owner/pond-doubao-asr ./install.sh
  3. 从 Releases 页手动下载 doubao-dictate-linux-$ARCH,放到 $BIN_DIR/"
  command -v curl >/dev/null 2>&1 || fail "需要 curl,请先安装后再运行"
  asset="doubao-dictate-linux-$ARCH"
  base="https://github.com/$RELEASE_REPO/releases/latest/download"
  tmp="$(mktemp)"
  sha="$(mktemp)"
  trap 'rm -f "$tmp" "$sha"' EXIT
  say "正在从 $RELEASE_REPO 下载 $asset…"
  if [ -t 2 ]; then progress="--progress-bar"; else progress="-sS"; fi
  curl -fL $progress --retry 2 --connect-timeout 15 "$base/$asset" -o "$tmp" ||
    fail "下载失败:$RELEASE_REPO 下没有 $asset,请改用本地编译"
  if curl -fsL --retry 3 --connect-timeout 15 "$base/$asset.sha256" -o "$sha" 2>/dev/null; then
    expected="$(awk '{print $1}' "$sha")"
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || fail "SHA256 校验失败(期望 $expected,实际 $actual)"
    say "SHA256 校验通过"
  fi
  install -m 755 "$tmp" "$BIN"
fi
say "已安装 $BIN"

# ---- 2. config (leave an existing file alone) ---------------------------
if [ -f "$ENV_FILE" ]; then
  say "保留已有配置 $ENV_FILE"
else
  mkdir -p "$CONF_DIR"
  cat > "$ENV_FILE" <<'EOF'
# Doubao dictation configuration. Fill in DOUBAO_API_KEY below.
DOUBAO_API_KEY=
DOUBAO_URL=wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream
DOUBAO_RESOURCE_ID=volc.seedasr.sauc.duration
DOUBAO_DEVICE=default
DOUBAO_SAMPLE_RATE=16000
DOUBAO_SEGMENT_MS=200
DOUBAO_MAX_DURATION_SECS=120
DOUBAO_MODE=type
DOUBAO_TYPE_DELAY_MS=10
DOUBAO_NOTIFY=true
EOF
  chmod 600 "$ENV_FILE"
  say "已创建 $ENV_FILE(稍后填入 API Key)"
fi

# ---- 3. systemd user service -------------------------------------------
mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<'EOF'
[Unit]
Description=Doubao dictation daemon
PartOf=graphical-session.target
After=graphical-session.target pipewire-pulse.service

[Service]
ExecStart=%h/.local/bin/doubao-dictate daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
say "已写入服务单元 $UNIT"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || fail "systemctl --user daemon-reload 执行失败"
  systemctl --user enable doubao-dictate >/dev/null 2>&1 || true
  systemctl --user restart doubao-dictate || say "警告:服务启动失败,请查看 systemctl --user status doubao-dictate"
  sock_dir="$(printenv XDG_RUNTIME_DIR 2>/dev/null || true)"
  [ -n "$sock_dir" ] || sock_dir="/run/user/$(id -u)"
  for _ in $(seq 1 20); do
    [ -S "$sock_dir/doubao-dictate.sock" ] && break
    sleep 0.1
  done
  state="$(systemctl --user is-active doubao-dictate 2>/dev/null || echo unknown)"
  case "$state" in
    active) state="运行中" ;;
    inactive) state="未运行" ;;
    failed) state="启动失败" ;;
    *) state="未知" ;;
  esac
  say "服务 doubao-dictate: $state"
else
  say "警告:未找到 systemctl,请手动启动:doubao-dictate daemon"
fi

# ---- 4. niri hotkeys (inside the existing binds block, once) ------------
add_niri_bindings() {
  file="$1"
  # Marker must match the comment written below; a mismatch would duplicate the
  # block, and niri rejects duplicate bindings for the same key.
  if grep -q "Doubao dictation (managed by install.sh)" "$file"; then
    say "热键绑定已存在,跳过"
    return 0
  fi
  cp -a "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  if ! awk -v bin="$BIN" '
    { line[NR] = $0 }
    END {
      last = 0
      for (i = NR; i >= 1; i--) if (line[i] ~ /^[[:space:]]*}[[:space:]]*$/) { last = i; break }
      if (last == 0) exit 2
      for (i = 1; i <= NR; i++) {
        if (i == last) {
          print ""
          print "    // ─── Doubao dictation (managed by install.sh) ───"
          print "    F9                           repeat=false hotkey-overlay-title=\"Doubao dictation (start/stop)\" { spawn \"" bin "\" \"toggle\"; }"
          print "    Mod+CTRL+X                   repeat=false hotkey-overlay-title=\"Doubao dictation (start/stop)\" { spawn \"" bin "\" \"toggle\"; }"
          print "    Mod+CTRL+ESCAPE              repeat=false hotkey-overlay-title=\"Doubao dictation (cancel)\" { spawn \"" bin "\" \"cancel\"; }"
        }
        print line[i]
      }
    }' "$file" > "$tmp"; then
    rm -f "$tmp"
    say "警告:$file 里没找到 binds 块的结尾,请按 deploy/niri-bindings.kdl 手动添加"
    return 1
  fi
  install -m 644 "$tmp" "$file"
  rm -f "$tmp"
  say "已把热键写入 $file(备份为 $file.bak.*)"
}

reload_niri() {
  if ! command -v niri >/dev/null 2>&1; then
    say "未找到 niri 命令,热键会在下次登录后生效"
    return 0
  fi
  if niri validate >/dev/null 2>&1; then
    if niri msg action load-config-file >/dev/null 2>&1; then
      say "已重载 niri 配置"
    else
      say "请手动重载:niri msg action load-config-file"
    fi
  else
    say "警告:niri 配置校验未通过(niri validate),热键可能不会生效"
  fi
}

if [ "$DO_HOTKEYS" -eq 1 ]; then
  if [ -f "$NIRI_BINDS" ]; then
    add_niri_bindings "$NIRI_BINDS" && reload_niri
  elif [ -f "$NIRI_DIR/config.kdl" ]; then
    add_niri_bindings "$NIRI_DIR/config.kdl" && reload_niri
  else
    say "警告:没找到 niri 配置目录 $NIRI_DIR,未添加热键"
    say "手动方式见 deploy/niri-bindings.kdl"
  fi
else
  say "已跳过热键安装"
fi

# ---- 5. API key ---------------------------------------------------------
key_ready=0
if grep -qE '^[[:space:]]*DOUBAO_API_KEY=.+' "$ENV_FILE" 2>/dev/null; then
  say "已配置 API Key,跳过设置"
  key_ready=1
else
  have_tty=0
  if { exec 3<>/dev/tty; } 2>/dev/null; then have_tty=1; fi

  key=""
  if [ "$have_tty" -eq 1 ]; then
    say ""
    say "获取 API Key:"
    say "  1. 打开 https://console.volcengine.com/speech/"
    say "  2. 开通「流式语音识别(2.0)」,在「API Key」页新建一个 Key"
    if command -v xdg-open >/dev/null 2>&1 &&
      { printenv WAYLAND_DISPLAY >/dev/null || printenv DISPLAY >/dev/null; }; then
      (xdg-open "https://console.volcengine.com/speech/" >/dev/null 2>&1 &) || true
      say "  (已在浏览器中打开该页面)"
    fi
    printf '粘贴你的豆包 API Key(直接回车跳过): ' >&3
    IFS= read -r -s key <&3 || key=""
    printf '\n' >&3
  else
    say ""
    say "当前没有终端,无法交互输入(无人值守安装)。"
    say "API Key 获取地址:https://console.volcengine.com/speech/"
  fi
  exec 3<&- 3>&- 2>/dev/null || true

  key="$(printf '%s' "$key" | tr -d '[:space:]' | tr -cd 'A-Za-z0-9._-')"
  if [ -n "$key" ]; then
    tmp_env="$(mktemp)"
    awk -v k="$key" '
      /^[[:space:]]*DOUBAO_API_KEY=/ { print "DOUBAO_API_KEY=" k; found = 1; next }
      { print }
      END { if (!found) print "DOUBAO_API_KEY=" k }
    ' "$ENV_FILE" > "$tmp_env"
    install -m 600 "$tmp_env" "$ENV_FILE"
    rm -f "$tmp_env"
    say "已保存 API Key 到 $ENV_FILE"
    systemctl --user restart doubao-dictate >/dev/null 2>&1 || true
    say "已重启 doubao-dictate"
    key_ready=1
  elif [ "$have_tty" -eq 1 ]; then
    say "已跳过 — 之后可以手动添加:$EDITOR $ENV_FILE"
  fi
fi

say ""
if [ "$key_ready" -eq 1 ]; then
  say "完成。按 F9 开始/停止听写。"
else
  say "已安装,但还没有 API Key。填好后重启服务:"
  say "  \$EDITOR $ENV_FILE"
  say "  systemctl --user restart doubao-dictate"
fi
