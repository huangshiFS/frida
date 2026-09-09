#!/bin/zsh
# stealth-rename.sh — 消除 frida 运行时特征字符串（对抗加固检测）
#
# 在 frida-core / frida-gum 子模块工作区内执行：
#   1. 重命名含 frida-agent/frida-helper/frida-server/frida-gadget 前缀的文件
#   2. 全局替换运行时可见的特征字符串（agent 资源名、线程名、helper dex 路径、
#      zymbiote 加载器名、android-helper 包名 re.frida -> re.xda 等）
#   3. C 侧内部符号回退（vala 生成符号不可改，C glue 必须保持 frida_* 原名）
#   4. 特殊修复：Agent.main 加 cname 覆盖、agent/helper/gadget 输出名、
#      zymbiote JNI 符号与路径模板等长替换
#   5. 重建 android-helper dex（需 javac + d8 + android.jar）
#   6. 二进制补丁预编译 zymbiote.elf（等长替换）
#
# 设计约束：
#   - 幂等，可重复执行
#   - 不动 compat/（兼容旧版预编译产物的路径名必须保持原样）
#   - 不动 tests/、releng/、docs
#   - 所有二进制补丁严格等长（memmem 模板 / ELF 符号表长度敏感）
#
# 用法: tools/stealth-rename.sh [--with-dex]
#   --with-dex  同时重建 helper.dex（需要 javac/d8/android.jar 环境）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/subprojects/frida-core"
GUM="$ROOT/subprojects/frida-gum"

echo "==> [1/7] 重命名 frida-core 特征文件"
find "$CORE/src" "$CORE/lib" "$CORE/server" "$CORE/inject" -type f \
  \( -name 'frida-agent*' -o -name 'frida-helper*' -o -name 'frida-server*' -o -name 'frida-gadget*' \) \
  | while read -r f; do
      nf="$f"
      nf="${nf//frida-agent/xda-core}"
      nf="${nf//frida-helper/xda-helper}"
      nf="${nf//frida-server/xda-server}"
      nf="${nf//frida-gadget/xda-gadget}"
      if [[ "$f" != "$nf" && ! -e "$nf" ]]; then
        mv "$f" "$nf"
        echo "    ${f#$CORE/} -> ${nf#$CORE/}"
      fi
    done

if [[ -d "$CORE/src/android-helper/re/frida" && ! -d "$CORE/src/android-helper/re/xda" ]]; then
  mv "$CORE/src/android-helper/re/frida" "$CORE/src/android-helper/re/xda"
  echo "    src/android-helper/re/frida -> src/android-helper/re/xda"
fi

echo "==> [2/7] 替换 frida-core 特征字符串（vala/meson/py/资源文件）"
CORE_FILES=$(grep -rlI -E \
  'frida-eternal-agent|frida-android-helper|frida-agent-container|frida-agent-emulated|frida-agent|frida_agent|frida-helper|frida_helper|frida-server|frida_server|frida-gadget|frida_gadget|frida-zymbiote|frida-main-loop|re\.frida|re/frida' \
  "$CORE/src" "$CORE/lib" "$CORE/server" "$CORE/inject" 2>/dev/null || true)

for f in ${(f)CORE_FILES}; do
  perl -pi -e '
    s/frida-eternal-agent/xda-eternal-agent/g;
    s/frida-android-helper/xda-android-helper/g;
    s/frida-agent-container/xda-core-container/g;
    s/frida-agent-emulated/xda-core-emulated/g;
    s/frida-agent/xda-core/g;
    s/frida_agent/xda_core/g;
    s/frida-helper/xda-helper/g;
    s/frida_helper/xda_helper/g;
    s/frida-server/xda-server/g;
    s/frida_server/xda_server/g;
    s/frida-gadget/xda-gadget/g;
    s/frida_gadget/xda_gadget/g;
    s/frida-zymbiote/xda00-zymbiote/g;
    s/frida-main-loop/xda-main-loop/g;
    s/re\.frida/re.xda/g;
    s{re/frida}{re/xda}g;
  ' "$f"
done
echo "    已处理 $(echo "$CORE_FILES" | grep -c .) 个文件"

# frida-core 顶层 meson 的产物输出名（agent/helper/gadget 安装名会嵌入 dylib）
perl -pi -e \
  "s/helper_name = 'frida-helper'/helper_name = 'xda-helper'/; \
   s/agent_name = 'frida-agent'/agent_name = 'xda-core'/; \
   s/gadget_name = 'frida-gadget'/gadget_name = 'xda-gadget'/" \
  "$CORE/meson.build"

# inject CLI 默认注入名
perl -pi -e 's/options\.name = "frida"/options.name = "xdagent"/' "$CORE/inject/inject.vala"

echo "==> [3/7] C 侧内部符号回退（vala 生成符号必须保持 frida_* 原名）"
# vala 类/命名空间生成的 C 符号（frida_agent_main、frida_server_environment_init 等）
# 由 vala 标识符派生，不可通过字符串替换改名；C glue 引用处必须保持原名。
# 这些符号均为非导出内部符号，release strip 后不可见，无暴露面。
find "$CORE/src" "$CORE/lib" "$CORE/server" "$CORE/inject" -type f \
  \( -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.cpp' -o -name '*.cc' -o -name 'Kbuild' \) \
  -exec grep -l -E 'xda_core|xda_helper|xda_server|xda_gadget' {} + 2>/dev/null | while read -r f; do
    perl -pi -e 's/xda_core/frida_agent/g; s/xda_helper/frida_helper/g; s/xda_server/frida_server/g; s/xda_gadget/frida_gadget/g' "$f"
    echo "    reverted: ${f#$CORE/}"
  done

echo "==> [4/7] 特殊修复"
# 4.1 Agent.main 是唯一被注入器按名字查找的导出符号（dlsym "frida_agent_main"），
#     用 cname 覆盖使 vala 生成改名后的 xda_core_main
if ! grep -q 'cname = "xda_core_main"' "$CORE/lib/agent/agent.vala"; then
  perl -pi -e 's{(\tpublic void main \(string agent_parameters)}{\t[CCode (cname = "xda_core_main")]\n$1}' \
    "$CORE/lib/agent/agent.vala"
  echo "    agent.vala: 添加 xda_core_main cname 覆盖"
fi

# 4.2 zymbiote JNI 导出符号等长替换（frida_ -> xda00_，均为 5 字符）
perl -pi -e 's/frida_zymbiote_replacement_/xda00_zymbiote_replacement_/g' \
  "$CORE/src/linux/helpers/zymbiote.c" \
  "$CORE/src/linux/linux-host-session.vala"
echo "    zymbiote JNI 符号 -> xda00_zymbiote_replacement_*"

echo "==> [5/7] 替换 frida-gum 特征字符串"
perl -pi -e 's/gum-js-loop/xda-js-loop/g' "$GUM/bindings/gumjs/gumscriptscheduler.c"
perl -pi -e 's/g_set_prgname \("frida"\)/g_set_prgname ("xdagent")/' "$GUM/gum/gum.c"
perl -pi -e 's/frida-XXXXXX\.dylib/xda-XXXXXX.dylib/g' "$GUM/gum/backend-darwin/gumcodesegment-darwin.c"
perl -pi -e 's/frida_dylib_range/xda_dylib_range/g' "$GUM/gum/backend-darwin/gumdarwinmapper.c"

echo "==> [6/7] 二进制补丁预编译 zymbiote.elf（等长替换）"
/usr/bin/python3 - <<'PYEOF'
import pathlib

base = pathlib.Path("/Users/m1/code/github/frida/subprojects/frida-core/src/linux/helpers/artifacts/native")
repls = [
    (b"/frida-zymbiote-", b"/xda00-zymbiote-"),
    (b"frida_zymbiote_replacement_", b"xda00_zymbiote_replacement_"),
]
for elf in sorted(base.glob("*/zymbiote.elf")):
    data = elf.read_bytes()
    orig = data
    for old, new in repls:
        assert len(old) == len(new), (old, new)
        data = data.replace(old, new)
    if data != orig:
        elf.write_bytes(data)
        print(f"    patched {elf.parent.name}/zymbiote.elf")
PYEOF

if [[ "${1:-}" == "--with-dex" ]]; then
  echo "==> [7/7] 重建 android-helper dex"
  ANDROID_JAR="${ANDROID_JAR:-$HOME/Library/Android/sdk/platforms/android-37.0/android.jar}"
  cd "$CORE/src/android-helper"
  mkdir -p build/java
  javac -cp ".:$ANDROID_JAR" -bootclasspath "$ANDROID_JAR" \
    -source 1.8 -target 1.8 -Xlint:deprecation -Xlint:unchecked \
    re/xda/Helper.java re/xda/HelperBackend.java -d build/java/
  jar cfe build/xda-helper.jar re.xda.Helper -C build/java/ .
  d8 --classpath "$ANDROID_JAR" --output build/ build/xda-helper.jar
  cp build/classes.dex helper.dex
  echo "    helper.dex 重建完成"
else
  echo "==> [7/7] 跳过 dex 重建（--with-dex 启用）"
fi

echo "==> 残留检查"
LEFT=$(grep -rlI -E 'frida-agent|frida-helper|frida-server|frida-gadget|gum-js-loop|re\.frida|frida.zymbiote' \
  "$CORE/src" "$CORE/lib" "$CORE/server" "$CORE/inject" 2>/dev/null | grep -v -E 'README|\.md$|compat/|tests/' || true)
if [[ -n "$LEFT" ]]; then
  echo "!! 仍有残留:"
  echo "$LEFT"
  exit 1
fi
echo "==> 完成，无残留特征字符串"
