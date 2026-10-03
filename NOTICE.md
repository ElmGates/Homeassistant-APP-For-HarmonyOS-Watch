# 第三方声明 / Third-party notices

腕上智家是独立开发的第三方应用，与 Home Assistant 官方无关。
Home Assistant 是 Open Home Foundation 的商标。

本项目以 GNU Affero General Public License v3.0（AGPL-3.0）发布，全文见 [LICENSE](LICENSE)。
应用内「关于」页的「开源代码参考」与本文件保持一致。

## 参考的开源项目

### Home-Assistant-HarmonyOS-Next

- 作者：gentslava
- 地址：https://github.com/gentslava/Home-Assistant-HarmonyOS-Next
- 许可：项目 README 声明为 MIT License（仓库中未见独立的 LICENSE 文件，以原项目声明为准）
- 使用情况：参考了最初的手表端工程结构（ArkTS / ArkUI 目录划分）和部分界面组件（标题栏、列表卡片、圆形图标徽章）的写法。原项目通过手机端 P2P 中转连接 Home Assistant，本项目已改为手表直连，数据层、状态管理、页面和图标均已重写；原项目的手机中转、模拟数据等代码已全部移除。

MIT License 要求在软件副本中保留原版权声明和许可声明。原项目未提供完整的版权声明文本，如原作者提供，将在此处补充。

## 参考的文档（未包含其代码）

- Home Assistant 开发者文档：REST API、WebSocket API、认证（Auth）接口说明
  https://developers.home-assistant.io/

## 自行绘制的资源

- `entry/src/main/resources/base/media/ic_*.svg`：应用内线条图标，为本项目自行绘制。
- 应用图标与 Logo：由 SuperJia 设计。

## 开发与测试依赖（不随应用分发）

- `@ohos/hypium`：OpenHarmony 单元测试框架，仅用于开发期测试，Apache License 2.0。
