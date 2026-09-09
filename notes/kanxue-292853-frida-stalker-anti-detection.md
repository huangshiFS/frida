# 看雪帖解读：Frida Stalker 指令级追踪绕过银行加固壳（梆梆）反调试检测

> 原文：[看雪论坛 thread-292853](https://bbs.kanxue.com/thread-292853.htm)《[原创]最强逆向大模型GLM-5.3无道德无限制驱动Frida Stalker绕过银行某梆检测》
> 解读日期：2026-09-09
> 说明：原文末尾「Frida 内存映射特征清单」部分有登录墙，本文档基于公开技术常识补全并明确标注。

---

## 一、文章概述

作者对某银行 APP（包名 `com.tzb.mobilehub`，采用"梆梆"系企业级加固壳）进行反调试对抗实战：

- **现象**：Frida attach 后进程**延迟数秒自动退出**（非立即退出）——说明检测逻辑跑在异步线程，而非 `JNI_OnLoad` 同步执行。
- **武器**：Frida **Stalker**（动态代码重写引擎）做指令级追踪，逐层回溯退出路径，最终定位检测函数并精准 patch。
- **特色**：全程用大模型（GLM-5.3-FLASH）生成 Frida 脚本，迭代十余轮。
- **结论**：加固壳通过扫描 `/proc/self/maps` 中的 Frida 内存映射特征（`memfd:` 等）发现注入，随后用「清零 sp/lr + 跳转未映射地址」**故意制造 SIGSEGV** 杀死进程（不走 `exit`/`abort`，普通 Hook 拦不到）。

文章有两条主线：

| 阶段 | 目标 | 手段 | 结果 |
|------|------|------|------|
| 阶段 1：盲绕 | 让 APP 不闪退 | 定位退出函数 `sub_4B2E0`，`onLeave` 中 `retval.replace(0)` | 程序正常运行，但不知检测原理 |
| 阶段 2：精准绕过 | 搞清检测链路，沉淀可复用方案 | 线程排除法定位元凶线程 `0x4b614` → Stalker 追踪 → 回溯至 `sub_50450`（maps 扫描函数） | 查明检测的是 Frida 内存映射特征 |

---

## 二、技术背景要点

### 2.1 为什么检测放在 JNI_OnLoad / 异步线程

- `dlopen` 加载 SO 后，Android 自动调用其导出的 `JNI_OnLoad`，**早于** `Application.onCreate`，Java 层未初始化，调试者难以介入。
- 银行级壳还会把部分检测放到异步线程**延迟执行**，错开启动瞬间，增加定位难度。

### 2.2 Stalker 的核心机制（本文深度依赖）

| 机制 | 说明 |
|------|------|
| transform 以基本块为单位 | 不是逐条指令回调，而是每个 basic block 首次执行时回调一次；块内用 `iterator.next()` 遍历、`iterator.keep()` 保留、`iterator.putCallout()` 插桩 |
| 影子内存 | 重写后的代码放在 Stalker 分配的可执行内存，原 SO 代码段只读不动——**即使壳做了代码段完整性校验，Stalker 依然能跟踪** |
| 跨模块过滤 | 必须用 `instruction.address` 与目标模块 [base, base+size) 比较过滤，否则被 ART/libc/linker 指令刷屏 |
| 性能优化 | 30ms 定时批量输出（数组缓冲 + join 一次打印）+ 指令去重（同地址只打首次）。`console.log` 走 IPC，逐条打印会卡死进程 |
| unfollow + flush | 结束必须 `Stalker.unfollow(tid)` + `Stalker.flush()`，否则尾部指令丢失——而「退出前最后几条指令」恰恰是定位关键 |

### 2.3 壳的反 Hook 退出手法

```
mov sp, #0
mov lr, #0
movk w11, #0xb6a2, lsl #16   ; 拼出未映射绝对地址
br   x11                      ; 跳转 → SIGSEGV
```

不调 `exit`/`abort`/`kill`，直接踩未映射地址段错误自杀。普通 `Interceptor.attach` 对 `exit` 族函数的 Hook 完全无效，**只有 Stalker 能抓到退出前最后的指令块**——这是本文用 Stalker 的根本原因。

---

## 三、完整操作流程复盘

| # | 现象/假设 | 动作 | 结果 |
|---|-----------|------|------|
| 1 | 进程延迟退出 → 检测在异步线程 | Hook `pthread_create`，`start_routine` 属于 `libDexHelper.so` 则打印并 return 0 假成功 | 仍退出 → 退出逻辑不全在线程 |
| 2 | 需确认 SO 加载时序 | Hook `android_dlopen_ext` 监控所有 SO 加载 | `libDexHelper.so` 之后无新 SO 加载就退出 → 嫌疑锁定其 `JNI_OnLoad` |
| 3 | 验证 JNI_OnLoad | 在 `android_dlopen_ext` 的 `onLeave` 中 Hook `JNI_OnLoad` 出入口 | 只打印「开始」无「结束」→ 确认退出发生在 JNI_OnLoad 内部 |
| 4 | 定位退出指令 | Stalker 跟踪 JNI_OnLoad，模块过滤+批量输出 | 抓到 `mov sp,#0; mov lr,#0; br x11` 自杀序列，算偏移 `0x10dc` |
| 5 | 找触发条件 | IDA 查 0x10dc 上下文 | `sub_4B2E0` 返回 1 时走退出路径 |
| 6 | 盲绕 | Hook 偏移 `0x4B2E0`，`onLeave` 中 `retval.replace(0)` | ✅ 程序不再退出 |
| 7 | 找元凶线程 | 分批 `ALLOW_OFFSETS` 排除 5 个线程（0x4e9d8/0x4b614/0x557c0/0x57668/0x5af74） | 锁定线程函数 `0x4b614` |
| 8 | 追踪元凶线程 | 盲绕 patch 保留 + 杀掉其余 4 线程 + Stalker 只追 `0x4b614` | 退出块在 `0x2dfa4` 附近，同样 sp/lr 清零模式 |
| 9 | 逐层回溯 | Hook `sub_2DFA4` 打印 3 个参数算跳转地址 → IDA 查 `0x97c`/`0x2DDA0`（纯退出函数，无分析价值）→ 上溯到 `0x4bbd4` | 发现 `sub_50450` 返回 1 → 跳退出 |
| 10 | 深挖检测函数 | Stalker 跟踪 `sub_50450` | 被调用两次：第一次正常返回，第二次返回 1 → 确认是**内存映射扫描函数** |
| 11 | 查明特征 | 结合 IDA + 动态追踪 | 扫描 `/proc/self/maps`，命中 3 个 Frida 特征之一即返回 1（原文此处有登录墙，见下节补全） |

---

## 四、检测特征补全（原文登录墙部分，基于公开常识）

Frida 16.x 注入后，`/proc/self/maps` 中会出现的典型特征映射：

| 特征 | 来源 |
|------|------|
| `memfd:jit-alloc` / `memfd:frida-*` | Frida 用 `memfd_create` 分配匿名可执行内存（Stalker 影子代码、Gum 代码段） |
| `gum-js-loop`、`gmain`、`pool-frida` 等线程名 | `/proc/self/task/*/comm` 中的 GLib/Gum 线程命名 |
| `frida-agent.so` / `frida-gadget` 路径 | 以文件方式注入时的库路径（memfd 注入可规避此项） |
| 默认端口 27042 | `frida-server` 监听端口，壳会扫 `/proc/net/tcp` 或直连探测 |
| D-Bus 握手 | 主动连接 27042 发送 D-Bus AUTH 验证是否为 frida-server |

**对应对抗思路**（文章未展开，实战常用）：
- frida-server 改名 + `-l 0.0.0.0:非默认端口`；
- `memfd` 名称 patch（对 frida 源码改 `jit-alloc` 等字符串重新编译，或运行时 hook `memfd_create` 改名）；
- 用 maps 隐藏：hook `openat`/`read`（`/proc/self/maps`）过滤含 frida 特征的行——注意壳常用 svc 内联系统调用绕过 libc hook，需在 svc 层对抗；
- 更彻底：改用自编译 frida / objection 之外的方案（如本文同款「patch 检测函数返回值」）。

---

## 五、操作可行性分析

### 5.1 前置条件评估

| 条件 | 要求 | 可行性 |
|------|------|--------|
| 设备 | Root（Magisk/KernelSU）+ frida-server 与手机架构匹配 | ✅ 你有多台 Root 设备（Pixel 6、OnePlus 9 Pro/Ace 2、RK3588），完全满足 |
| 工具 | frida 16.x、IDA Pro、目标 APK | ✅ 现有工具链覆盖 |
| 技能 | ARM64 汇编阅读、IDA 偏移计算、Frida JS API（Interceptor/Stalker） | ✅ 你有 LSPosed/unidbg 经验，门槛低 |
| 大模型辅助 | 非必需，但确实能加速脚本生成 | ⚠️ 见 5.4 节评价 |

### 5.2 流程可复制性

**整体可复制性高**。该流程本质是一套通用方法论，与具体 APP 解耦：

```
延迟退出 → pthread_create 拦截(排除法) → android_dlopen_ext 时序监控
→ JNI_OnLoad 出入口确认 → Stalker 抓退出前指令 → IDA 回溯条件分支
→ retval.replace(0) 盲绕 → 线程排除 → Stalker 逐层回溯 → 精准定位检测源
```

对任何「启动闪退型」加固壳（梆梆/爱加密/360/通付盾）都适用，区别只在偏移和检测特征不同。

### 5.3 风险与局限

| 风险 | 说明 | 缓解 |
|------|------|------|
| **版本迭代失效** | 盲绕 patch 的偏移（0x4B2E0 等）随壳版本变化，APP 升级即失效 | 阶段 2 的精准分析（特征级对抗）才可沉淀；或写偏移自动搜索（特征码匹配） |
| **完整性校验** | 部分壳校验自身代码段，`Interceptor.replace`/`attach` 写的 inline hook 可能被检测 | Stalker 影子内存天然免疫；inline hook 失败可改 Stalker callout |
| **svc 内联syscall** | 壳读 maps 常用 raw svc 绕过 libc hook | 需在内核层（KernelSU 模块/eBPF）或 patch 检测函数本身对抗 |
| **多维检测** | 银行壳通常同时检测：端口、D-Bus、线程名、ptrace 状态、`TracerPid`、调试器特征（`android.os.Debug.isDebuggerConnected`）等，绕一个可能触发另一个 | 文中「保留盲绕 patch + 逐线程排除」的渐进式打法正是为应对多维检测 |
| **Stalker 性能** | 高负载函数追全量指令会卡死进程 | 文中 30ms 批量输出 + 去重是标配；必要时只 follow 单线程单区间 |
| **法律/合规** | 银行 APP 属强监管目标，仅可用于授权安全测试 | 自有设备+研究目的，不触碰生产数据 |

### 5.4 关于「GLM-5.3 无道德无限制」宣传的评价

文章有明显**软广成分**（"最强逆向大模型、无道德审查、无限制、价格低廉"反复出现）。客观看待：

- **真实价值**：大模型生成 Frida 样板脚本（Interceptor/Stalker 骨架、批量输出优化）确实能省大量重复劳动，「描述需求→生成脚本→改参数迭代」模式可行；
- **水分**：核心突破（理解 SIGSEGV 退出模式、逐层回溯的决策链、`ALLOW_OFFSETS` 排除法设计）仍依赖人的逆向直觉，模型只是执行层加速器；
- 「无道德审查」在国内合规语境下是营销噱头，主流模型对授权安全研究场景的 Frida 脚本生成本来就很少拒答。

**结论：方法论可信、可复现；大模型部分是增益而非关键，不必依赖特定模型。**

---

## 六、对现有项目的借鉴意义

结合当前在做的红果/凤凰/抖音逆向与 cp9 抓包项目：

1. **红果/凤凰 APP 若遇启动闪退**：可直接套用本文流程——`android_dlopen_ext` 时序监控 → JNI_OnLoad 确认 → Stalker 抓退出块。你现有 HongGuoCapture 的 BoringSSL 符号 Hook 属于「协议降级」维度，本文补的是「反调试存活」维度，两者是抓包前置的互补环节。
2. **unidbg 场景**：unidbg 模拟执行不走真机 maps，天然免疫本文的 memfd/maps 检测——签名还原继续用 unidbg 是对抗检测的最省事路径；但 feed 流抓包必须在真机存活，仍需本文方法论。
3. **cp9 抓包 App**：目标 App 若有同类壳，cp9 需要内置「反反调试」模块，本文的 pthread_create 拦截 + retval patch 骨架可直接移植为 LSPosed/Frida Gadget 模块。
4. **脚本资产沉淀**：建议把以下三个可复用脚本骨架存入 hsapiserver 或 AutoBrowser 的 tools 目录：
   - `hook_dlopen_timeline.js`（SO 加载时序 + JNI_OnLoad 出入口）
   - `stalker_trace_module.js`（模块过滤 + 30ms 批量输出 + 去重 + flush）
   - `thread_exclude.js`（pthread_create 拦截 + ALLOW_OFFSETS 排除法）

### 关键脚本骨架（按文中描述还原）

```js
// 1. pthread_create 拦截：阻止目标模块线程
const pthread_create = Module.findExportByName("libc.so", "pthread_create");
Interceptor.replace(pthread_create, new NativeCallback((p, attr, start, arg) => {
  const mod = Process.findModuleByAddress(start);
  if (mod && mod.name === "libDexHelper.so") {
    console.log(`[block] ${mod.name} offset=${start.sub(mod.base)}`);
    return 0; // 假成功，实际不创建
  }
  return new NativeFunction(pthread_create, 'int',
    ['pointer','pointer','pointer','pointer'])(p, attr, start, arg);
}, 'int', ['pointer','pointer','pointer','pointer']));

// 2. Stalker 模块过滤 + 批量输出（要点）
Stalker.follow(tid, {
  transform(iterator) {
    let inst;
    while ((inst = iterator.next()) !== null) {
      const addr = inst.address;
      if (addr.compare(base) >= 0 && addr.compare(base.add(size)) < 0) {
        buf.push(`${addr.sub(base)}: ${inst.mnemonic} ${inst.opStr}`);
      }
      iterator.keep();
    }
  }
});
setInterval(() => { if (buf.length) { console.log(buf.join("\n")); buf.length = 0; } }, 30);
// 结束：Stalker.unfollow(tid); Stalker.flush();

// 3. 盲绕：patch 检测函数返回值
Interceptor.attach(mod.base.add(0x4B2E0), {
  onLeave(retval) { retval.replace(0); }
});
```

---

## 七、结论

| 维度 | 评价 |
|------|------|
| 技术真实性 | ⭐⭐⭐⭐⭐ 方法论扎实，SIGSEGV 退出识别 + Stalker 回溯是教科书级操作 |
| 可复制性 | ⭐⭐⭐⭐☆ 流程通用，但每个 APP 需重新定位偏移与特征 |
| 对你的适用性 | ⭐⭐⭐⭐⭐ 直接补齐红果/凤凰/抖音抓包的「反调试存活」环节 |
| 大模型宣传 | ⭐⭐☆☆☆ 软广成分重，是效率工具非核心竞争力 |

**行动建议**：将三个脚本骨架沉淀为可复用资产；下次遇到目标 APP 启动闪退时按第三节 11 步流程走一遍即可。
