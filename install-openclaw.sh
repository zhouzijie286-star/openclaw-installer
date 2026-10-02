#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

info() { printf '\n[+] %s\n' "$*"; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
trap 'printf "\n执行失败，行号：%s。修复报错后可重新运行脚本。\n" "$LINENO" >&2' ERR

[[ "$(id -u)" == 0 ]] || die "请使用 root 运行"
[[ -t 0 ]] || die "需要交互终端：请先下载脚本再用 bash 执行（curl -o install-openclaw.sh 后 bash install-openclaw.sh），不要用 curl | bash 管道方式"
[[ -d /run/systemd/system ]] || die "需要运行 systemd 的系统"

source /etc/os-release
case "$ID" in
  debian)
    [[ "$VERSION_ID" =~ ^(11|12|13)$ ]] ||
      die "仅支持 Debian 11/12/13（当前: Debian $VERSION_ID）"
    ;;
  ubuntu)
    [[ "$VERSION_ID" == 22.04 ]] ||
      die "仅支持 Ubuntu 22.04（当前: Ubuntu $VERSION_ID）"
    ;;
  *)
    die "此脚本支持 Debian 11/12/13 与 Ubuntu 22.04（当前: $ID $VERSION_ID）"
    ;;
esac

info "安装系统依赖"
apt-get update
apt-get install -y ca-certificates curl gnupg git python3 build-essential

# ---------------- Swap ----------------
SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
if (( SWAP_MB < 1024 )); then
  read -r -p "当前 Swap 不足 1GB，额外创建 4GB Swap？[Y/n]: " ANSWER
  if [[ "${ANSWER,,}" != n ]]; then
    SWAP_PATH=/openclaw.swap
    [[ ! -e "$SWAP_PATH" ]] ||
      die "$SWAP_PATH 已存在，请先检查，脚本不会覆盖"

    AVAILABLE_KB=$(df --output=avail / | tail -n 1 | tr -d ' ')
    (( AVAILABLE_KB > 6 * 1024 * 1024 )) ||
      die "根分区可用空间不足 6GB，无法安全创建 4GB Swap"

    info "创建 Swap"
    dd if=/dev/zero of="$SWAP_PATH" bs=1M count=4096 status=progress
    chmod 600 "$SWAP_PATH"
    mkswap "$SWAP_PATH"
    if ! swapon "$SWAP_PATH"; then
      die "Swap 启用失败。请检查文件系统/虚拟化限制；未写入 fstab"
    fi

    if ! awk '$1 == "/openclaw.swap" {found=1} END {exit !found}' /etc/fstab; then
      printf '%s\n' '/openclaw.swap none swap sw 0 0' >> /etc/fstab
    fi
  fi
fi

# ---------------- Node ----------------
# 使用系统路径，避免 systemd 找不到 nvm 中的 Node。
if [[ -x /usr/bin/node && -x /usr/bin/npm ]] &&
   /usr/bin/node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)'; then
  info "使用现有 Node：$(/usr/bin/node -v)"
else
  info "安装 Node.js 24"
  SETUP_FILE=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://deb.nodesource.com/setup_24.x -o "$SETUP_FILE"
  bash "$SETUP_FILE"
  rm -f "$SETUP_FILE"
  apt-get install -y nodejs
fi

export PATH=/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/bin:/sbin

info "安装 OpenClaw"
# 固定安装位置，使服务和管理菜单使用同一个 CLI。
npm install --global --prefix /usr/local openclaw@latest --no-audit --no-fund
[[ -x /usr/local/bin/openclaw ]] || die "未找到 OpenClaw CLI"

/usr/local/bin/openclaw --version

install -d -m 700 /root/.openclaw

# ---------------- 交互式管理工具 ----------------
cat > /usr/local/bin/openclaw-manage <<'PY'
#!/usr/bin/env python3
import copy
import datetime
import getpass
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

PATH = pathlib.Path("/root/.openclaw/openclaw.json")
PROVIDER = "custom"
PREFIX = PROVIDER + "/"

def ask(label, default=None):
    suffix = f" [{default}]" if default is not None else ""
    while True:
        value = input(label + suffix + ": ").strip()
        if value:
            return value
        if default is not None:
            return str(default)
        print("不能为空。")

def number(label, default):
    while True:
        text = ask(label, default)
        if text.isdigit() and int(text) > 0:
            return int(text)
        print("请输入正整数。")

def secret(label, old=None):
    while True:
        suffix = "（回车保留原值）" if old else ""
        value = getpass.getpass(label + suffix + ": ").strip()
        if value:
            return value
        if old:
            return old
        print("不能为空。")

def load():
    if not PATH.exists():
        return {}
    try:
        with PATH.open() as f:
            return json.load(f)
    except json.JSONDecodeError:
        raise RuntimeError(
            "现有 openclaw.json 不是严格 JSON，可能使用了 JSON5。"
            "为避免破坏配置，本工具停止；请先转换成标准 JSON。"
        )

def provider(cfg):
    return cfg.setdefault("models", {}).setdefault("providers", {}).setdefault(
        PROVIDER, {}
    )

def defaults(cfg):
    return cfg.setdefault("agents", {}).setdefault("defaults", {})

def primary(cfg):
    value = defaults(cfg).get("model", {})
    return value if isinstance(value, str) else value.get("primary", "")

def set_primary(cfg, ref):
    d = defaults(cfg)
    if not isinstance(d.get("model"), dict):
        d["model"] = {}
    d["model"]["primary"] = ref

def configure_api(cfg):
    p = provider(cfg)
    print("\nAPI 协议：")
    print("  1) OpenAI Chat Completions（多数兼容接口）")
    print("  2) OpenAI Responses")
    print("  3) Anthropic Messages")
    protocols = {
        "1": "openai-completions",
        "2": "openai-responses",
        "3": "anthropic-messages",
    }
    old = p.get("api", "openai-completions")
    default = next((k for k, v in protocols.items() if v == old), "1")
    while True:
        choice = ask("选择", default)
        if choice in protocols:
            break
        print("请输入 1、2 或 3。")

    print("\n填写供应商文档中的 API 根地址，不要填具体请求路径。")
    print("示例：https://api.openai.com/v1")
    print("      https://api.deepseek.com")
    print("      https://openrouter.ai/api/v1")
    print("      https://api.anthropic.com")
    while True:
        url = ask("API Base URL", p.get("baseUrl")).rstrip("/")
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme == "https" and parsed.netloc and not parsed.query and not parsed.fragment:
            break
        print("请输入有效的 HTTPS 根地址，不带 query 或 fragment。")

    p["api"] = protocols[choice]
    p["baseUrl"] = url
    p["apiKey"] = secret("API Key", p.get("apiKey"))
    p.setdefault("models", [])
    cfg.setdefault("models", {}).setdefault("mode", "merge")

def add_model(cfg):
    p = provider(cfg)
    existing = {m["id"] for m in p.setdefault("models", [])}
    print("\n模型 ID 必须与供应商提供的 ID 完全一致。")
    print("OpenRouter 的 ID 可能包含 /，例如 anthropic/某模型ID。")
    while True:
        mid = ask("模型 ID")
        if any(c.isspace() for c in mid):
            print("模型 ID 不能含空白字符。")
        elif mid in existing:
            print("该模型已存在，可通过菜单编辑。")
        else:
            break

    model = {"id": mid}
    edit_fields(model)
    p["models"].append(model)

    # 若设置了模型允许列表，新注册的模型也必须进入该列表。
    defaults(cfg).setdefault("models", {}).setdefault(PREFIX + mid, {})
    if not primary(cfg):
        set_primary(cfg, PREFIX + mid)
    print("已注册：", PREFIX + mid)

def edit_fields(model):
    model["name"] = ask("显示名称", model.get("name", model["id"]))
    print("下面的默认数值仅为占位，请按供应商文档调整。")
    context = number("上下文窗口 token 数", model.get("contextWindow", 32768))
    while True:
        output = number("最大输出 token 数", model.get("maxTokens", min(4096, context)))
        if output <= context:
            break
        print("最大输出不能大于上下文窗口。")
    model["contextWindow"] = context
    model["maxTokens"] = output
    model["reasoning"] = ask(
        "是否为推理模型？y/n", "y" if model.get("reasoning") else "n"
    ).lower() == "y"
    image = ask(
        "是否支持图片输入？y/n",
        "y" if "image" in model.get("input", []) else "n"
    ).lower() == "y"
    model["input"] = ["text", "image"] if image else ["text"]

def choose_model(cfg):
    models = provider(cfg).get("models", [])
    if not models:
        raise RuntimeError("尚未注册模型，请先新增。")
    print()
    for i, m in enumerate(models, 1):
        flag = " [默认]" if primary(cfg) == PREFIX + m["id"] else ""
        print(f"  {i}) {m['id']}{flag}")
    while True:
        index = ask("选择模型序号")
        if index.isdigit() and 1 <= int(index) <= len(models):
            return models[int(index) - 1]
        print("序号无效。")

def telegram(cfg):
    tg = cfg.setdefault("channels", {}).setdefault("telegram", {})
    while True:
        token = secret("Telegram Bot Token", tg.get("botToken"))
        if not re.fullmatch(r"\d+:[A-Za-z0-9_-]+", token):
            print("Token 格式不正确。")
            continue
        try:
            url = f"https://api.telegram.org/bot{token}/getMe"
            with urllib.request.urlopen(url, timeout=20) as r:
                result = json.load(r)
            if not result.get("ok"):
                print("Telegram 未通过验证，请重试。")
                continue
            print("验证成功：@" + result["result"].get("username", ""))
            break
        except (urllib.error.URLError, TimeoutError, ValueError):
            # 不输出异常 URL，避免 Token 出现在终端/日志。
            print("验证失败，请检查 Token 和服务器到 Telegram 的网络。")

    old_ids = " ".join(str(x) for x in tg.get("allowFrom", []))
    print("填写允许私聊的 Telegram 用户数字 ID；不是群组 ID，也不是用户名。")
    while True:
        text = ask("用户 ID，多个用空格分隔", old_ids or None)
        ids = text.replace(",", " ").split()
        if ids and all(re.fullmatch(r"[1-9]\d*", x) for x in ids):
            break
        print("请输入正整数用户 ID。")

    tg.update({
        "enabled": True,
        "botToken": token,
        "dmPolicy": "allowlist",
        "allowFrom": list(dict.fromkeys(ids)),
        "groupPolicy": "disabled",
    })

def save(cfg):
    PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    previous = PATH.read_bytes() if PATH.exists() else None
    if previous is not None:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = PATH.with_name(PATH.name + ".bak." + stamp)
        shutil.copy2(PATH, backup)
        os.chmod(backup, 0o600)
        print("原配置备份：", backup)

    fd, temp = tempfile.mkstemp(prefix=".config-", dir=PATH.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(temp, 0o600)
        os.replace(temp, PATH)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

    # 使用所安装版本的配置校验器检查，不依赖脚本猜测成功。
    result = subprocess.run(["/usr/local/bin/openclaw", "config", "validate"])
    if result.returncode != 0:
        if previous is None:
            PATH.unlink(missing_ok=True)
        else:
            PATH.write_bytes(previous)
            os.chmod(PATH, 0o600)
        raise RuntimeError("配置校验失败，已恢复修改前的配置；服务未重启。")
    print("配置已保存并通过校验。")

def restart():
    result = subprocess.run(["systemctl", "restart", "openclaw.service"])
    if result.returncode:
        print("重启失败，请运行：journalctl -u openclaw -n 80 --no-pager")
    else:
        print("已请求重启。检查日志：journalctl -u openclaw -f")

def show(cfg):
    p = provider(cfg)
    print("\nAPI 地址：", p.get("baseUrl", "未配置"))
    print("API 协议：", p.get("api", "未配置"))
    print("默认模型：", primary(cfg) or "未配置")
    for m in p.get("models", []):
        print(
            f"  - {m['id']} | 上下文 {m.get('contextWindow', '?')}"
            f" | 输出 {m.get('maxTokens', '?')}"
        )

def setup():
    cfg = load()
    configure_api(cfg)
    if not provider(cfg).get("models"):
        add_model(cfg)
    while ask("继续新增模型？y/n", "n").lower() == "y":
        add_model(cfg)
    print("\n选择默认模型：")
    set_primary(cfg, PREFIX + choose_model(cfg)["id"])
    telegram(cfg)

    gateway = cfg.setdefault("gateway", {})
    gateway.update({"mode": "local", "bind": "loopback"})
    gateway["auth"] = {
        "mode": "token",
        "token": secrets.token_hex(32),
    }
    defaults(cfg)["maxConcurrent"] = 1
    defaults(cfg).setdefault("subagents", {})["maxConcurrent"] = 1
    save(cfg)

def menu():
    while True:
        print("""
========== OpenClaw 管理 ==========
1) 查看模型配置（不显示密钥）
2) 新增模型
3) 删除模型
4) 切换默认模型
5) 编辑模型参数
6) 修改 API 地址 / Key / 协议
7) 修改 Telegram Token / 用户白名单
8) 重启服务
9) 查看服务状态
0) 退出
""")
        choice = ask("选择", "0")
        if choice == "0":
            return
        try:
            cfg = load()
            if choice == "1":
                show(cfg)
                continue
            if choice == "8":
                restart()
                continue
            if choice == "9":
                subprocess.run(["systemctl", "status", "openclaw", "--no-pager"])
                continue

            changed = copy.deepcopy(cfg)
            if choice == "2":
                add_model(changed)
            elif choice == "3":
                p = provider(changed)
                if len(p.get("models", [])) <= 1:
                    print("至少保留一个模型。请先新增替代模型。")
                    continue
                m = choose_model(changed)
                ref = PREFIX + m["id"]

                # 避免删除被其他 agent/fallback 等引用的模型。
                references = copy.deepcopy(changed)
                d = defaults(references)
                d.get("models", {}).pop(ref, None)
                if primary(references) == ref:
                    set_primary(references, "")

                def used(value):
                    if isinstance(value, str):
                        return value == ref
                    if isinstance(value, list):
                        return any(used(x) for x in value)
                    if isinstance(value, dict):
                        return ref in value or any(used(x) for x in value.values())
                    return False

                if used(references):
                    print("该模型仍被其他配置引用，请先移除对应 agent/fallback 引用。")
                    continue

                if ask(f"确定删除 {ref}？y/n", "n").lower() != "y":
                    continue
                p["models"].remove(m)
                defaults(changed).get("models", {}).pop(ref, None)
                if primary(changed) == ref:
                    print("被删除的是默认模型，请选择新的默认模型：")
                    set_primary(changed, PREFIX + choose_model(changed)["id"])
            elif choice == "4":
                set_primary(changed, PREFIX + choose_model(changed)["id"])
            elif choice == "5":
                edit_fields(choose_model(changed))
            elif choice == "6":
                configure_api(changed)
            elif choice == "7":
                telegram(changed)
            else:
                print("无效选项。")
                continue
            save(changed)
            restart()
        except (RuntimeError, OSError) as e:
            print("操作失败：", e)

if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("请使用 sudo openclaw-manage")
    # 与 systemd 使用相同配置位置和系统 Node。
    os.environ["OPENCLAW_CONFIG_PATH"] = str(PATH)
    os.environ["PATH"] = "/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/bin:/sbin"
    try:
        if "--setup" in sys.argv:
            setup()
        else:
            menu()
    except (KeyboardInterrupt, EOFError):
        sys.exit("\n已取消；尚未保存的输入不会生效。")
    except (RuntimeError, OSError) as e:
        sys.exit(str(e))
PY

chmod 700 /usr/local/bin/openclaw-manage

info "交互配置模型及 Telegram"
/usr/local/bin/openclaw-manage --setup

# ---------------- systemd ----------------
SERVICE_FILE=/etc/systemd/system/openclaw.service
if [[ -f "$SERVICE_FILE" ]]; then
  cp -a "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%s)"
fi

cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=OpenClaw Gateway
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=PATH=/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/bin:/sbin
Environment=NODE_ENV=production
Environment=OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
UMask=0077
ExecStart=/usr/local/bin/openclaw gateway
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

info "启动服务"
systemctl daemon-reload
systemctl enable openclaw.service
systemctl restart openclaw.service

sleep 5
if ! systemctl is-active --quiet openclaw.service; then
  journalctl -u openclaw -n 60 --no-pager
  die "服务未运行，请根据日志排查"
fi

cat <<'TIP'

================ 安装步骤完成 ================

服务进程当前已运行；模型实际调用仍需在 Telegram 中测试。
请从白名单内的账号，私聊你的 Bot 发送“你好”。

后续配置管理：
  openclaw-manage

查看已注册模型：
  openclaw models list

查看模型配置与认证状态：
  openclaw models status

查看实时日志：
  journalctl -u openclaw -f

查看最近日志：
  journalctl -u openclaw -n 80 --no-pager

重启服务：
  systemctl restart openclaw

配置文件：
  /root/.openclaw/openclaw.json

当前设置：
  - Telegram 仅允许指定用户私聊，群聊关闭
  - Gateway 仅监听本机，无需开放公网管理端口
  - 主任务和子任务并发分别限制为 1
  - 密钥保存在权限为 600 的配置文件中
  - 修改配置前自动备份，校验成功后才重启

=============================================
TIP
