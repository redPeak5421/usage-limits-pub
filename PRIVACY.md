# 隐私政策 / Privacy Policy

生效日期 / Effective date: 2026-09-06

本页适用于 iOS App「Usage Limits」（以下简称「本 App」）。English version follows the Chinese text.

## 中文

### 一句话

本 App 没有自己的服务器，不收集、不上传任何数据。你在 App 里登录的账号、Cookie 和用量数字都只存在你自己的设备上。

### 本 App 在设备上保存什么

- **登录态**：你在 App 内置浏览器里登录各家官方站点后产生的 Cookie 和站内 token。它们保存在 iOS 系统的 WebKit 存储中，和 Safari 保存登录态的方式相同。
- **用量快照**：从官方站点读取到的用量数字、额度和重置时间。快照只含数字和时间，不含任何 Cookie 或 token。
- **自定义用量源的访问令牌**：如果你添加了自定义接口，填写的 token 单独存放在本机，不进入用量快照，也不同步到 Apple Watch。
- **偏好设置**：显示方式、提醒阈值、刷新间隔、外观等。

以上数据保存在本 App 的沙盒和 App Group 容器内，供 App、小组件和 Apple Watch 伴侣使用。Apple Watch 只收到数字和偏好，不收到任何凭据。

### 本 App 向哪里发请求

- 只向你已登录的各家**官方域名**发请求，在已登录的页面内读取该站点自己的用量接口。
- 自定义用量源只向你自己填写的 HTTPS 地址发请求。
- 没有开发者服务器，没有统计 SDK、广告 SDK 或崩溃上报 SDK。本 App 不知道你是谁，也不知道你用了什么。

### 提醒

用量提醒是本地通知，由本 App 在设备上根据已保存的快照计算，不经过任何推送服务器。

### 反馈邮件

设置 → 高级 → 反馈会打开系统邮件编辑器，收件人是 canonforge5421@gmail.com。发不发、发什么内容由你决定；我们只会收到你主动发出的邮件。

### 删除数据

- 在 App 内「退出登录」会清除该站点在本机的全部数据。
- 删除本 App 会连同沙盒、App Group 容器一起删除全部数据。

### 儿童

本 App 不面向 13 岁以下儿童。

### 变更

本页有变动时会在此更新并修改生效日期。本 App 的源代码公开在同一仓库，可以直接核对上述说明。

### 联系

canonforge5421@gmail.com

## English

### In one sentence

Usage Limits has no server of its own and collects nothing. The accounts you sign in to, their cookies, and the usage figures stay on your device only.

### What the app stores on your device

- **Sign-in state**: cookies and site tokens created when you sign in to each service's official website inside the app's built-in browser. They live in iOS WebKit storage, the same place Safari keeps its sign-ins.
- **Usage snapshots**: the usage figures, quotas and reset times read from the official sites. Snapshots contain numbers and timestamps only, never cookies or tokens.
- **Custom source tokens**: if you add a custom endpoint, its token is kept in a separate on-device key. It is never included in snapshots or sent to Apple Watch.
- **Preferences**: display options, alert thresholds, refresh interval, appearance.

All of this lives in the app's sandbox and App Group container, shared with the widgets and the Apple Watch companion. The Watch receives numbers and preferences only, never credentials.

### Where the app sends requests

- Only to the **official domains** of the services you signed in to, reading each site's own usage API from within your signed-in page.
- Custom sources are called only at the HTTPS address you entered yourself.
- There is no developer server and no analytics, advertising or crash-reporting SDK. The app does not know who you are or how you use it.

### Alerts

Usage alerts are local notifications computed on the device from stored snapshots. No push server is involved.

### Feedback email

Settings → Advanced → Feedback opens the system mail composer addressed to canonforge5421@gmail.com. Whether and what you send is up to you; we only receive mail you choose to send.

### Deleting your data

- "Sign out" inside the app removes everything that site stored on this device.
- Deleting the app removes all data, including the sandbox and the App Group container.

### Children

The app is not directed at children under 13.

### Changes

Changes will be posted on this page with a new effective date. The app's source code is public in this same repository, so the statements above can be checked directly.

### Contact

canonforge5421@gmail.com
