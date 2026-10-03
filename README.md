# 腕上智家（适用于 Home Assistant 的鸿蒙手表应用）

面向 HarmonyOS 6.1.0 / API 23、1.6 英寸 466×466 圆屏的 ArkTS + ArkUI 手表应用。当前已从单独的直连探针扩展为房间、设备和控制界面；仍在开发与验证中。

## 已实现

- 手表使用自身网络直连 Home Assistant；首次用 HA 内置账号的用户名和密码登录，换取短期访问凭证，并在到期时自动刷新。密码不写入本地存储。
- **首页「常用」**：在任意设备详情页点「☆ 加入常用」，即可在首页一键控制（开关、执行场景、按按钮、开合窗帘、播放/暂停），无需进入房间。
- 首页读取 HA 的区域、设备和实体注册表，按房间显示**物理设备**数量。房间内按 `device_id` 合并同一设备的多个实体；只有一个可控实体的设备在行内直接给出快捷按钮。
- **杂项实体过滤**：厂商集成常给一台设备挂几十个实体。手表端按以下规则收敛：
  - 不显示：禁用、隐藏、诊断（diagnostic）、配置（config）实体；不可用的下拉框；备份/天气/翻译等「服务型」设备；自动化等不支持的类型。
  - 主控实体按「空调 > 灯 > 窗帘 > 风扇 > … > 开关」选取，房间列表显示主控状态，快捷按钮也只作用于主控。
  - 设备页只直接显示主控和真正的家电功能；童锁、蜂鸣器、屏显亮度、重启按钮等折叠到「更多控制」，读数折叠到「附属状态」。所有控件同类型时（如三联开关）全部直接显示。
- 实体名称自动去掉重复的设备名前缀。
- 支持的设备类型与操作（白名单见 `HaDirectClient.ALLOWED_SERVICES`）：
  - 灯（开关、亮度）、开关、`input_boolean`、风扇（开关、风速）、加湿器
  - 窗帘（开/停/关、位置）、温控（模式、目标温度，按 HA 给出的步长）
  - `select` / `input_select`、`number` / `input_number`
  - 场景、脚本、`button` / `input_button`
  - 门锁（上锁一键；**解锁需 4 秒内连按两次确认**）
  - 媒体播放器（播放/暂停、上一首/下一首、音量、开关机）、扫地机（开始、暂停、回充）
  - 传感器、二元传感器只读，状态均已中文化（含单位、亮度/位置百分比）
- 操作后读回实体状态；超时或结果不明时不自动重发。离线缓存明确标记且禁用控制。
- 应用回到前台或返回首页/房间页时，若数据超过 30 秒自动重新同步。
- 可撤销的刷新凭证优先使用 HUKS AES-GCM 密钥加密后保存；若模拟器的安全存储不可用，连接仅在本次会话有效。房间、状态快照和常用列表作为非敏感数据保存；更换服务器时一并清除。
- 圆屏原生 `ArcScrollBar` + 表冠滚动；在模拟器中检查了居中布局。

## 代码结构

```
entry/src/main/ets
├─ entryability/EntryAbility.ets   启动恢复登录、前台自动刷新
├─ data/direct/                    HA 认证、REST、注册表 WebSocket、实体→设备分组
├─ data/security/CredentialStore   HUKS 加密保存刷新凭证
├─ data/cache/                     状态快照缓存、常用设备列表
├─ presentation/store/DirectStore  全局状态与所有操作
├─ presentation/ui/                主题色、设备类型文案/图标/快捷操作、通用组件
└─ pages/                          首页、房间、设备、实体详情、设置
```

## 测试数据（HA 端）

`tools/ha_test_fixture.py` 在 HA 里一键创建逼真的测试家居，测完一键删除：

- 房间 客厅 / 卧室 / 玄关；虚拟设备 客厅主灯（亮度）、客厅窗帘（位置）、卧室台灯、卧室风扇（风速）、入户门锁；脚本 回家模式 / 离家模式。虚拟设备的状态存放在隐藏的辅助元素里（顺带验证隐藏实体被过滤）。
- 往一台指定的真实设备（环境变量 `HA_NOISY_DEVICE`）上挂 31 个模拟杂项实体（开关、下拉、数值、按钮、二元传感器、读数），用于验证过滤效果。

```sh
set HA_URL=http://<你的 HA 地址>:8123
set HA_TOKEN=<HA 个人资料 → 安全 → 长期访问令牌>
set HA_NOISY_DEVICE=<一台真实设备的名称>
python tools/ha_test_fixture.py setup      # 基础测试家居 + 指定设备上的杂项实体
python tools/ha_test_fixture.py extend     # 补齐 10 个房间、各类设备、离线设备、场景
python tools/ha_app_calls_test.py          # 按应用实际发送的指令逐项验证（只操作虚拟设备）
python tools/ha_test_fixture.py cleanup    # 全部删除
```

创建记录保存在 `tools/.ha_fixture_state.json`（本机测试数据，不要对外分享）；不要把地址、令牌写进任何文件。

## 构建

用 DevEco Studio 6.1 打开本目录，配置 WATCH 5 调试签名并运行。命令行构建：

```sh
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default
```

未签名构建产物位于 `entry/build/default/outputs/default/entry-default-unsigned.hap`。本机模拟器接受该产物，真机安装需配置签名。

## 首次连接与模拟器输入

输入 HA 地址、内置账号用户名和密码。建议使用可信 HTTPS 地址。本地 `http://192.168.x.x:8123` 等私有地址只在明确点击界面中的确认按钮后允许登录；HTTP 会明文传输密码，不能用于公网。登录成功后清空界面中的密码。单一验证码方式的双重验证可在第二屏输入验证码；多个双重验证模块等复杂登录流程仍需适配。

应用通过 HA `/auth/login_flow`、`/auth/token` 完成授权及刷新，不再要求手动创建长期访问令牌。更换服务器或清除数据时会清除本地刷新凭证，并尽力向 HA 撤销；如果当时离线，请在 HA 个人资料中撤销该会话。

## 验证状态与限制

- 已在 HUAWEI WATCH 5（HarmonyOS 6.1）真机上，分别通过 Wi‑Fi 和蓝牙（经手机网络）连接 Home Assistant 完成控制。
- 手表经蓝牙使用手机网络时，如果 HA 经海外 CDN 访问，TLS 握手可能很慢。可在应用的「设置 → 网络诊断」中逐项查看耗时，并参考 `docs/site/security.html` 选择更快的远程访问方式。
- 「用手机填写」需要手表连接 Wi‑Fi 且与手机处于同一局域网，模拟器无法使用。
- 尚未支持：多个双重验证模块的复杂登录流程、实时状态推送（目前在打开应用或页面时按需同步）。

## 开源参考

本工程原始 Watch ArkTS 结构参考 [Home-Assistant-HarmonyOS-Next](https://github.com/gentslava/Home-Assistant-HarmonyOS-Next)；其运行架构依赖手机 P2P，本项目已改为手表直连。上游 README 写有 MIT，但仓库当前未提供可识别的 LICENSE 文件，正式分发前仍需核实授权。完整的第三方声明见 [NOTICE.md](NOTICE.md)，应用「关于」页同步显示。HA API 依据：[Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/) 和 [WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)。

## 许可证

Copyright (C) 2026 SuperJia

本项目以 [GNU Affero General Public License v3.0](LICENSE) 发布：可以自由使用、修改和分发，但分发修改后的版本、或将其作为网络服务提供时，必须以相同许可证公开完整源代码。

参考的第三方项目及其许可见 [NOTICE.md](NOTICE.md)。Home Assistant 是 Open Home Foundation 的商标，本项目为独立开发的第三方应用。
