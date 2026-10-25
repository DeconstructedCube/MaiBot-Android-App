<div align="center">
  <h1>📱 MaiBot-Android-App <sub><small>(第三方非官方客户端)</small></sub></h1>
  
  <!-- Badges Row -->
  <p>
    <img src="https://img.shields.io/badge/Platform-Android-green" alt="Android">
    <img src="https://img.shields.io/badge/License-BSD--3--Clause-blue" alt="License">
    <img src="https://img.shields.io/badge/状态-衍生项目-orange" alt="Status">
    <a href="https://github.com/Mai-with-u/MaiBot"><img src="https://img.shields.io/badge/Powered_by-MaiBot-pink" alt="Powered by MaiBot"></a>
  </p>
</div>

> ⚠️ **特别声明**：  
> 本项目为基于[zz6zz666/AstrBot-Android-App](https://github.com/zz6zz666/AstrBot-Android-App) 二次开发的**第三方安卓端衍生项目**，旨在为手机用户提供便捷的运行环境。  
> 本项目**非** `Mai-with-u` 官方团队出品。原麦麦核心版权归属原作者所有。

---

# 📱 MaiBot 手机端：一键在 Android 设备部署 MaiBot 机器人

**MaiBot-Android-App** 是专为 Android 设备优化的 MaiBot 运行环境集成包。

通过将 Linux 容器环境（PRoot）、Python 运行环境与 NapCatQQ 协议适配器整体封装为手机应用，无需电脑或手动配置 Termux / Docker，即可在 Android 手机上本地部署并运行 MaiBot。

主要功能：
- **本地一键运行**：自动解压并配置 Ubuntu 容器与 Python 依赖环境，一键启动服务。
- **图形化控制面板**：内嵌 WebView 控制台，直接在手机端完成模型配置与参数调整。
- **消息协议集成**：内置 NapCatQQ 适配器，支持扫码登录与 OneBot v11 协议通信。
- **后台常驻运行**：配合 Android 前台服务、电池优化白名单及唤醒锁，保障后台稳定运行。

---

## 🌐 什么是 MaiBot？

MaiBot 是一个基于大语言模型的开源对话机器人项目，支持拟人化回复、自然语言交互规划与上下文学习。

- 💬 **拟人化交互**：采用自然语言风格构建提示词，支持贴近日常交流的拟人回复。
- ⚙️ **多模型接入**：支持主流 LLM API 接口（如 OpenAI、Claude、DeepSeek 及各类兼容接口）。
- 🧩 **插件扩展**：支持安装适配器与功能插件以扩展机器人的交互能力。

---

## ✅ 安卓 App 能做什么？不能做什么？

| 功能 | 是否支持 | 说明 |
|------|----------|------|
| 手机一键运行麦麦 | ✅ | 登录后即可自动收发消息，拥有拟人化回复 |
| 支持微信 / Telegram 等平台 | ❌ | 当前版本**仅支持 QQ 个人账号** |
| 复杂的外部插件环境 | ❌ | 受限于安卓容器环境，部分需要复杂依赖的底层插件可能受限 |
| 图形化配置界面 | ✅ | 内置 WebView，直接在手机上完成模型密钥设置 |
| 接入多种大模型 | ✅ | 支持 OpenAI、DeepSeek、国产平台 API 等 |
| 后台稳定运行 | ✅ | 息屏、切后台不中断，消息实时响应 |

📌 **重点强调**：  
本 App 已将 **NapCatQQ** 与运行环境深度集成，省去用户手动配置的麻烦。但也意味着：**它只能用于 QQ 平台**。这不是缺陷，而是为了简化体验所做的必要聚焦。

---

## 🛠️ 使用前必读：完整操作指南与注意事项

由于本 App 面向的是**完全零技术背景的用户群体**，为确保你能顺利完成初始化并稳定运行，请务必仔细阅读以下全部内容。

### 🌐 网络要求
 - `首次启动`必须在 **网络通畅的环境** 下进行  
 - 推荐使用 **家用 Wi-Fi 或手机 5G 流量**  
 - ❌ 避免使用校园网、公司内网、公共 Wi-Fi 等限速或受限网络，可能导致资源下载失败  

### 🔧 初始化注意事项（请逐条阅读，以避免初始化失败）

首次启动时，App 会自动下载并安装必要的运行环境（基于 Ubuntu 容器）。这是一个全自动过程，但仍需注意以下几点：

1. **应用启动后会联网下载依赖资源**  
 - 屏幕显示白色进度条，表示正在初始化。  
 - **点击屏幕任意位置**，可在“进度条页面”与“模拟终端日志”之间切换。

2. **强烈建议人工监视终端输出**  
 - 虽然过程自动化，但我们**强烈建议**你在首次启动时切入**终端日志**页面，持续观察安装进度，以便第一时间发现网络阻塞等问题。

3. **NapCat 安装可能耗时较长**  
 - 负责 QQ 协议通信的 `napcat` 组件安装时间较长，若发现卡住，可**直接关闭 App 再次启动**，系统会从中断处继续安装。

4. **极端情况处理方式**  
 - 若多次重启仍无法完成初始化（如终端提示 `dpkg was interrupted`），可能是系统包损坏。  
 - 此时需进入手机设置 → 应用管理 → 找到 MaiBot App → **清除应用数据** → 重新启动。

5. **关于前台与息屏运行的说明**  
 - ✅ **首次初始化期间**：强烈建议**保持屏幕常亮**。  
 - ✅ **初始化完成后**：麦麦可稳定在后台运行，只要保证通知栏**常驻通知**不被关闭即可。

### 🔄 登录与配置流程

完成初始化后，请按以下步骤操作：

1. **允许通知权限**：启动后 App 请求通知权限时，**必须点击“允许”**，否则麦麦无法在后台运行。
2. **扫码登录 QQ**：NapCatQQ 启动成功后会弹出二维码，使用手机 QQ 扫码登录即可。
3. **填写大模型 API 密钥**：在自动跳转的控制台页面中，填入你的模型服务商提供的 Token（API Key）。（配置完成后保存并重启服务即可体验）。

---

## 📌 特性对比

| 维度 | 传统命令行 / Docker 部署 | MaiBot-Android-App 方案 |
|---|---|---|
| **部署方式** | 需 Linux 服务器或手动配置 Termux | Android 应用一键安装初始化 |
| **环境配置** | 手动安装 Python、apt 依赖与适配器 | 全自动配置容器、DNS 与 Python 虚拟环境 |
| **使用门槛** | 需要基础命令行与 Linux 运维经验 | 手机图形化界面操作与管理 |

---

## 🙏 致谢

本项目站在巨人的肩膀上，没有以下优秀的开源项目，就没有本 App 的诞生：

- [**zz6zz666/AstrBot-Android-App**](https://github.com/zz6zz666/AstrBot-Android-App)：本项目的架构基础与参考来源。
- [**Mai-with-u/MaiBot**](https://github.com/Mai-with-u/MaiBot)：MaiBot 开源项目。
- [**Code LFA**](https://github.com/nightmare-space/code_lfa)：提供 Android 端 Ubuntu 容器底层环境。
- [**NapCatQQ**](https://napneko.github.io/guide/napcat)：QQ 协议适配器。

---

## 📜 许可证说明 (License)

本项目严格遵守 **BSD-3-Clause 许可证** 进行二次开发。
- 基础安卓外壳与容器调度代码基于 `AstrBot-Android-App` (Copyright (c) zz6zz666)。
- 内部运行的 MaiBot 核心代码遵循其原有的 **GPL-3.0** 协议。
- *声明：本 App 作为一个运行环境载体，尊重所有引用的开源协议，不将原始作者的名字用于本修改版本的商业促销或背书。*

---

## 💬 反馈交流

- 如果你在使用本安卓端应用时遇到部署或闪退问题，欢迎提交 Issues。
- 如需了解 MaiBot 核心功能、提示词配置与模型设置，请参考 MaiBot 官方文档。
