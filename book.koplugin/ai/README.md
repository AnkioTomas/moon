# KOReader AI Reading Companion

## AI 智能阅读助手设计方案 V3

> 定位：让 KOReader 从“电子书阅读器”变成真正理解用户阅读进度、阅读内容和阅读状态的 AI 阅读助手。
>
> 核心原则：**AI 在云端，本地负责阅读上下文、状态、缓存和隐私边界。**
>
> AI X-Ray 已经完成，因此本方案将 AI X-Ray 作为现有基础能力，而不是未来功能。

---

# 一、产品目标

传统电子书阅读器主要解决：

* 看书
* 翻页
* 标注
* 查词
* 查资料

AI 阅读助手应该进一步解决：

* 我现在读到哪里了？
* 前面发生了什么？
* 这个人是谁？
* 这句话是什么意思？
* 为什么他这么做？
* 我刚才读了什么？
* 今天读了什么？
* 上次读到这里时发生了什么？
* 这本书目前讲到什么程度了？
* 这个人物之前出现过吗？
* 我是不是漏掉了什么？
* 如果我继续读，应该关注什么？

最终目标：

> **AI 不应该只是一个“问答框”，而应该成为一个真正理解阅读过程的助手。**

---

# 二、总体架构

```text
                    ┌─────────────────────┐
                    │      KOReader       │
                    │                     │
                    │   阅读 / 翻页 / 选中   │
                    └──────────┬──────────┘
                               │
                               ▼
                 ┌──────────────────────────┐
                 │    Reading Context       │
                 │                          │
                 │ 当前页 / 当前段 / 章节     │
                 │ 阅读位置 / 阅读边界        │
                 │ 选中文本 / 附近上下文       │
                 └────────────┬─────────────┘
                              │
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
      ┌────────────┐   ┌────────────┐   ┌────────────┐
      │  AI X-Ray  │   │ Reading    │   │ Reading    │
      │            │   │ Memory     │   │ State      │
      │ 人物/事件/关系 │   │ 阅读历史/摘要 │   │ 当前阅读状态 │
      └────────────┘   └────────────┘   └────────────┘
             │                │                │
             └────────────────┼────────────────┘
                              ▼
                   ┌─────────────────────┐
                   │ Context Builder     │
                   │                     │
                   │ 上下文选择           │
                   │ 防剧透               │
                   │ Prompt 构建          │
                   └──────────┬──────────┘
                              │
                              ▼
                   ┌─────────────────────┐
                   │    Remote AI        │
                   │                     │
                   │ Fast / Main / Deep  │
                   └──────────┬──────────┘
                              │
                              ▼
                   ┌─────────────────────┐
                   │ AI Result / Cache   │
                   └─────────────────────┘
```

**没有本地 LLM。**

KOReader 本地只负责：

* 获取阅读内容
* 记录阅读位置
* 构建上下文
* 保存阅读状态
* 保存 AI X-Ray
* 防剧透
* 缓存 AI 结果
* 调用远程 AI

真正的语言理解和生成全部交给远程 AI。

---

# 三、AI X-Ray：现有基础能力

AI X-Ray 已经完成。

它负责建立书籍的结构化知识：

```text
Book
 ├── Characters
 ├── Locations
 ├── Organizations
 ├── Events
 ├── Relationships
 ├── Concepts
 └── Timeline
```

例如：

```text
John
 ├── 出现章节：1, 3, 5, 8
 ├── 身份：...
 ├── 关系：
 │    ├── Mary
 │    └── Tom
 └── 重要事件：
      ├── Event A
      └── Event B
```

AI X-Ray 不应该只是一个独立的“人物介绍”功能。

它应该成为后续 AI 阅读功能的**知识基础设施**。

---

# 四、核心新增能力：Reading State

这是整个 V3 最重要的部分。

AI 不仅知道：

> “这本书是什么？”

还应该知道：

> **“用户现在读到了什么程度？”**

建立：

```text
ReadingState
```

例如：

```text
ReadingState {

    book

    currentChapter

    currentPosition

    readingBoundary

    currentCharacters

    currentEvents

    currentConflict

    currentTopic

    unresolvedQuestions

    recentSummary

    chapterSummary

    readingHistory
}
```

它代表：

> **用户此刻所知道的故事状态。**

---

# 五、AI 根据阅读进度自动总结

答案是：**非常适合做，而且应该做成核心功能。**

可以把总结分成三个层级。

## 5.1 当前阅读总结

用户读完一段后，后台自动生成：

> **刚才发生了什么？**

例如：

```text
用户阅读：

John entered the room...
...
Mary refused to speak to him.
```

AI 自动总结：

```text
刚才的内容：

John 找到了 Mary，并试图和她交谈。
但 Mary 明显对 John 抱有敌意，并拒绝与他沟通。
目前两人的关系似乎存在明显矛盾。
```

这个总结不需要用户主动点击。

---

# 六、章节级 Summary

当用户完成一个章节时：

```text
Chapter 12
       │
       ▼
Remote AI
       │
       ▼
Chapter Summary
```

生成：

```text
Chapter 12 Summary

发生了什么：
- John 找到了 Mary
- 两人发生冲突
- Mary 拒绝透露信息

人物变化：
- John 开始怀疑 Mary
- Mary 与 John 的关系进一步恶化

重要线索：
- Mary 提到了一个之前没有出现过的名字

未解决问题：
- Mary 为什么隐瞒这件事？
- 这个名字是谁？
```

---

# 七、阅读进度总结

这比普通的“章节摘要”更重要。

假设用户已经读了：

```text
Chapter 1
Chapter 2
Chapter 3
Chapter 4
```

系统可以生成：

> **目前为止发生了什么？**

例如：

```text
目前剧情

John 来到 London 后发现自己的父亲留下了一笔神秘遗产。

Chapter 2 中，他发现遗产背后可能隐藏着一桩旧案。

Chapter 3 中，Mary 出现，并暗示她知道这件事情。

Chapter 4 中，John 开始怀疑自己的父亲并非意外死亡。

目前主要矛盾：

John 正在调查父亲死亡的真相。

主要人物：

John
Mary
Tom

未解决的问题：

- John 的父亲究竟发生了什么？
- Mary 为什么知道这件事情？
- Tom 是否与此有关？
```

这实际上就是一个：

# AI Reading Progress Summary

---

# 八、“我上次读到哪里了？”

这是非常适合电子书的功能。

用户隔了几天重新打开书。

系统知道：

```text
Last Position
Chapter 8
Position 73%
```

自动生成：

> **Welcome Back**

例如：

```text
你上次读到 Chapter 8。

在你上次停止阅读之前：

- John 刚刚发现 Mary 隐瞒了一个重要事实。
- Tom 开始调查 John 的行动。
- 两人的关系开始出现明显冲突。

目前最重要的问题是：

Mary 为什么一直拒绝解释这件事情？
```

然后：

**继续阅读**

---

# 九、Catch Me Up

可以把“上次读到哪里”进一步做成：

> **Catch Me Up**

用户点击后：

```text
你已经有 5 天没有阅读这本书了。

以下是你之前读到的内容：

[人物]
John —— 主角
Mary —— 与 John 存在冲突
Tom —— 正在调查 John

[最近发生]
1. John 找到了一份旧文件
2. Mary 试图阻止他继续调查
3. Tom 开始怀疑 John

[当前状态]
John 正准备调查文件中的地点。

[未解决]
为什么 Mary 要阻止 John？
```

这个体验会非常接近真正的 AI 阅读伙伴。

---

# 十、动态阅读总结

阅读总结不应该只有：

```text
章节总结
```

还可以随着阅读不断变化。

例如：

```text
                  阅读进度

Chapter 1 ────────┐
                  │
Chapter 2 ────────┤
                  │
Chapter 3 ────────┤──→ Reading Memory
                  │
Chapter 4 ────────┤
                  │
Chapter 5 ────────┘
                         │
                         ▼
                    AI Summary
                         │
                         ▼
                    Reading State
```

每读完一部分：

```text
新的内容
   ↓
生成/更新局部 Summary
   ↓
更新 Reading Memory
   ↓
更新 Reading State
   ↓
更新当前剧情/知识状态
```

---

# 十一、不要每翻一页都调用 AI

这一点非常重要。

否则：

```text
翻页
 ↓
AI
 ↓
翻页
 ↓
AI
 ↓
翻页
 ↓
AI
```

成本和延迟都会非常高。

应该采用：

## Event Driven

触发条件：

```text
阅读了一定数量的新内容
        OR
章节发生变化
        OR
用户停止阅读
        OR
用户主动请求总结
        OR
用户重新打开书
```

例如：

```text
阅读 3~5 页
     ↓
判断是否值得更新
     ↓
是
     ↓
后台请求 AI
```

AI 请求应该放到后台 Worker。

用户继续阅读，不应该被阻塞。

---

# 十二、Reading Memory

Reading Memory 不等于把整本书全部发送给 AI。

它应该保存：

```text
ReadingMemory

├── 已读章节
├── Chapter Summary
├── Recent Summary
├── Important Characters
├── Important Events
├── Current Conflict
├── Unresolved Questions
└── Reading Position
```

例如：

```text
Chapter 1
Summary: ...

Chapter 2
Summary: ...

Chapter 3
Summary: ...

Current State:
John 正在调查父亲死亡事件。

Unresolved:
Mary 为什么知道真相？
```

这样后面的 AI 请求只需要发送：

```text
当前文本
+
附近上下文
+
相关章节 Summary
+
Reading State
+
相关 X-Ray
```

而不是整本书。

---

# 十三、Reading Context

AI 每次请求都应该根据任务动态构建 Context。

建议：

```text
L1 当前句子
L2 当前段落
L3 当前页面
L4 附近内容
L5 当前章节
L6 当前章节 Summary
L7 已读章节 Summary
L8 Reading State
L9 AI X-Ray
```

不同问题使用不同层级。

例如：

### 翻译

```text
L1 + L2
```

### “他是谁？”

```text
L1 + L2 + X-Ray
```

### “为什么？”

```text
L1 + L3 + Reading State + X-Ray
```

### “前面发生了什么？”

```text
L6 + L7 + Reading State
```

### Catch Me Up

```text
Reading Memory + Reading State
```

这样可以大幅降低 Token 消耗。

---

# 十四、猜你想问

这是另一个核心功能。

用户选中：

> He refused to answer.

界面可以出现：

```text
猜你想问

• 这里的 He 指谁？
• 他为什么拒绝回答？
• 前面发生了什么？
```

用户不需要输入问题。

---

# 十五、Context-aware Ask

用户选中：

> Mary refused to speak to John.

点击：

**为什么？**

AI 自动理解：

```text
问题：
为什么？

Context：
Mary refused to speak to John.

Reading State：
John 正在调查父亲死亡事件。

X-Ray：
Mary 与 John 存在历史关系。
```

然后回答：

> Mary 拒绝与 John 交谈，很可能与他正在调查的事情有关……

这才是 AI 阅读区别于普通 ChatGPT 的地方。

---

# 十六、“他是谁？”

用户选中：

> John looked at him.

点击：

> 他是谁？

系统：

```text
当前文本
+
附近上下文
+
X-Ray
+
Reading State
```

AI 自动判断指代。

如果不确定：

> 这里的 “him” 很可能指 Tom。前两段中 Tom 刚刚离开房间。

---

# 十七、“为什么？”

这是阅读中最自然的 AI 操作。

用户：

> 为什么？

AI 根据当前上下文理解：

```text
为什么这个人这么做？
```

而不是要求用户完整输入问题。

---

# 十八、防剧透

这是 AI 阅读最重要的系统能力之一。

定义：

```text
Reading Boundary
```

例如：

```text
User has read:

Chapter 1
Chapter 2
Chapter 3
```

AI 只能使用：

```text
Chapter 1
Chapter 2
Chapter 3
```

不能使用：

```text
Chapter 4+
```

即使 AI X-Ray 已经知道后面的内容，也必须进行过滤。

---

# 十九、Summary 也必须防剧透

例如用户读到 Chapter 3。

不能生成：

```text
整本书总结
```

因为其中可能包含：

> Chapter 15 最终 John 死了。

因此 Summary 本身也必须有：

```text
summary.reading_boundary
```

例如：

```text
Summary {

    chapter = 3

    max_position = 3

    content = ...

}
```

---

# 二十、Source Locator

AI 回答：

> Mary 之前曾经提到过这个名字。

用户可以点击：

**查看原文**

直接跳转到对应位置。

AI 输出：

```text
answer
source[]
```

例如：

```text
source:
  chapter: 2
  position: 43
```

这样 AI 不再是一个“黑盒”。

---

# 二十一、AI Reading State

这是整个系统最终可以形成的核心数据：

```text
AI Reading State

当前章节：
Chapter 8

当前事件：
John 正在调查父亲死亡事件。

当前人物：
John
Mary
Tom

当前冲突：
John 与 Mary 的关系恶化。

重要线索：
一份旧文件。

未解决问题：
Mary 为什么知道这件事情？

最近总结：
......

阅读进度：
38%
```

它实际上就是：

> **AI 对用户当前阅读状态的理解。**

---

# 二十二、AI 自动总结的最终形态

用户不需要主动点“总结”。

系统可以在后台逐渐形成：

```text
                用户阅读
                   │
                   ▼
             Reading Context
                   │
                   ▼
              Remote AI
                   │
          ┌────────┴────────┐
          ▼                 ▼
      Local Summary     Reading State
          │                 │
          └────────┬────────┘
                   ▼
              Reading Memory
                   │
                   ▼
             下一次 AI 请求
```

最终形成一个循环：

> **阅读 → 理解 → 总结 → 记录 → 再理解**

这才是真正的 AI Reading Companion。

---

# 二十三、AI 功能优先级

## S 级：核心体验

### 1. AI X-Ray

已完成。

### 2. Reading Context

让 AI 理解：

> 用户现在正在看什么。

### 3. Reading Memory

让 AI 知道：

> 用户之前已经读过什么。

### 4. AI Reading State

让 AI 知道：

> 当前阅读到什么状态。

### 5. 自动阅读总结

让 AI 自动总结：

> 用户刚刚读了什么。

### 6. 猜你想问

让 AI 主动预测：

> 用户可能想问什么。

### 7. Context-aware Ask

让用户只需要：

> 为什么？

> 他是谁？

> 什么意思？

### 8. 防剧透

整个 AI 系统的基础安全边界。

---

# 二十四、A 级功能

* Catch Me Up
* 上次阅读总结
* 章节总结
* 阅读进度总结
* 人物总结
* 事件总结
* 原文定位
* AI Notes
* 阅读状态面板
* 重要线索
* 未解决问题

---

# 二十五、B 级功能

* AI Tutor
* 阅读理解训练
* 单词学习
* 个性化阅读建议
* 长期阅读统计
* 跨书籍知识关联
* 用户阅读习惯分析

---

# 二十六、Remote AI Provider

不设计本地模型。

统一接口：

```lua
Provider:chat()
Provider:stream()
Provider:cancel()
```

可以支持：

```text
OpenAI-compatible
Gemini
Qwen
DeepSeek
OneAPI
自建 API
```

Provider 只负责：

```text
请求
 ↓
Remote AI
 ↓
返回
```

其他逻辑不应该放进 Provider。

---

# 二十七、AI Model Tier

可以使用不同远程模型。

### Fast

适合：

* 猜你想问
* 翻译
* 简单解释
* 意图判断

### Main

适合：

* Context Q&A
* 人物分析
* 为什么
* 章节总结
* Catch Me Up

### Deep

适合：

* 长文本分析
* 复杂人物关系
* 复杂剧情
* 全书分析

这样可以控制：

```text
成本
延迟
Token
```

---

# 二十八、缓存

AI 结果应该尽可能缓存。

例如：

```text
Cache

├── X-Ray
├── Chapter Summary
├── Reading Summary
├── Reading State
├── Suggested Questions
├── Translation
└── Q&A
```

相同上下文不要重复请求。

尤其是：

```text
Chapter Summary
```

一旦生成，可以长期复用。

---

# 二十九、KOReader 本地数据结构

建议保持简单。

```lua
AI = {
    provider = {},
    cache = {},
    context = {},
    memory = {},
    state = {},
    xray = {},
}
```

Reading State：

```lua
state = {
    chapter = 8,
    position = 0.38,
    characters = {},
    events = {},
    conflict = nil,
    unresolved = {},
    summary = nil,
}
```

不要为了这个系统引入大量复杂架构。

---

# 三十、后台 Worker

所有 AI 请求都不应该阻塞阅读。

例如：

```text
用户翻页
   ↓
KOReader继续运行
   ↓
后台 Worker
   ↓
检查是否需要更新 Summary
   ↓
Remote AI
   ↓
保存结果
```

如果用户继续翻页：

```text
旧请求
   ↓
可以取消 / 忽略
```

避免大量无意义请求。

---

# 三十一、一个完整使用场景

用户打开一本小说。

### 第一天

阅读 Chapter 1～3。

系统后台生成：

```text
Chapter 1 Summary
Chapter 2 Summary
Chapter 3 Summary
```

并形成：

```text
Reading State
```

---

### 第二天

用户打开书。

KOReader 检测：

```text
Last Read:
Chapter 3
```

显示：

> **继续阅读**

下面：

> 上次你读到这里时，John 刚刚发现一份与父亲有关的文件。

用户点击：

**Catch Me Up**

AI 给出：

```text
过去阅读内容：

John 正在调查父亲死亡的真相。

最近：
- John 找到了一份旧文件
- Mary 试图阻止他继续调查
- Tom 开始关注 John

目前最大的疑问：

Mary 为什么知道这件事情？
```

---

### 第三天

用户阅读：

> Mary refused to speak to him.

系统出现：

```text
猜你想问：

• Mary 为什么拒绝他？
• 这里的 him 指谁？
• Mary 和 John 之前发生过什么？
```

用户点击：

**为什么？**

AI 根据：

```text
当前文本
+
附近文本
+
Chapter Summary
+
Reading State
+
X-Ray
```

直接回答。

---

### 第四天

用户读完 Chapter 5。

后台自动：

```text
Chapter 5 Summary
        ↓
Reading Memory
        ↓
Reading State Update
```

于是整个系统越来越了解：

> **这本书目前讲到了什么。**

---

# 三十二、最终产品形态

最终 KOReader AI 不应该长得像：

```text
┌──────────────────┐
│  Ask AI           │
│                  │
│  输入问题...      │
│                  │
│       Send       │
└──────────────────┘
```

而应该更像：

```text
                 阅读
                   │
                   ▼
          ┌─────────────────┐
          │  AI understands │
          │   your reading  │
          └────────┬────────┘
                   │
       ┌───────────┼───────────┐
       ▼           ▼           ▼
    总结         猜你想问      理解上下文
       │           │           │
       ▼           ▼           ▼
   阅读状态      快速提问      深度问答
       │           │           │
       └───────────┼───────────┘
                   ▼
              Reading Memory
```

最终形成：

> **一个会随着你阅读而不断“成长”的 AI 阅读助手。**

而不是简单地把 ChatGPT 塞进 KOReader。

---

# 三十三、V1 推荐实现顺序

如果现在开始真正开发，我建议严格按照这个顺序：

### Phase 1

**Reading Context**

先解决：

> AI 当前到底看到了什么？

---

### Phase 2

**Reading Memory**

保存：

* 阅读位置
* 已读章节
* Chapter Summary
* 最近阅读内容

---

### Phase 3

**自动章节总结**

先实现：

```text
Chapter → Summary
```

---

### Phase 4

**Reading State**

从：

```text
Summary + X-Ray + Current Context
```

生成：

```text
Current Reading State
```

---

### Phase 5

**Catch Me Up**

利用 Reading Memory：

```text
上次读到哪里
+
之前发生了什么
```

---

### Phase 6

**猜你想问**

利用当前 Context：

```text
Current Text
+
Reading State
+
X-Ray
```

生成 3～5 个候选问题。

---

### Phase 7

**Context-aware Ask**

实现：

```text
为什么？
他是谁？
什么意思？
前面发生了什么？
```

---

### Phase 8

**Source Locator + Spoiler Guard**

让 AI：

> 既聪明，又不会剧透，而且回答可以追溯到原文。

---

# 三十四、最终核心能力

整个系统最终可以浓缩成五个东西：

```text
AI X-Ray
    ↓
这本书是什么？

Reading Context
    ↓
我现在正在读什么？

Reading Memory
    ↓
我之前读了什么？

Reading State
    ↓
我现在读到什么状态？

Remote AI
    ↓
我能帮你理解什么？
```

最终：

> **AI X-Ray 负责理解“书”。**
>
> **Reading Context 负责理解“当前页面”。**
>
> **Reading Memory 负责理解“过去的阅读”。**
>
> **Reading State 负责理解“现在的阅读状态”。**
>
> **Remote AI 负责完成真正的理解、总结和推理。**
>
> 五者结合，才构成完整的 KOReader AI Reading Companion。
