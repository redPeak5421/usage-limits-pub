# 隐私政策 / Privacy Policy

生效日期 / Effective date: 2026-09-10

本页适用于 iOS App「Usage Limits」（以下简称「本 App」）。English version follows the Chinese text.

## 中文

### 一句话

本 App 没有开发者运营的用量服务器或统计 SDK，不向开发者自动发送账号凭据或用量。登录和刷新需要与用户选择的服务通信；本地保存、手表同步、分享和反馈的范围如下。

### 本 App 在设备上保存什么

- **登录态**：你在 App 内置浏览器里登录各家官方站点后产生的 Cookie 和站内 token。它们由本 App 的 WebKit 网站数据存储管理，用于对应站点及其认证流程，不与 Safari 的登录态自动共享。
- **用量快照**：从官方站点读取到的用量数字、额度、重置时间及必要的显示标签、套餐和状态信息。不包含 Cookie、访问令牌或可兑换的重置凭证编号。
- **自定义用量源的访问令牌**：如果你添加了自定义接口，填写的 token 单独存放在本机，不进入用量快照，也不同步到 Apple Watch。
- **账号配置与偏好**：服务商选择、账号显示名称、本地身份指纹、自定义接口地址和字段映射，以及显示方式、提醒阈值、刷新间隔、外观等。身份指纹用于防止混淆账号，不保存生成指纹所用的原始身份值。
- **本地诊断**：用于排查刷新和解析错误的状态、时间及经过脱敏的诊断信息。诊断不会自动上传。

本 App 与小组件使用设备上的沙盒和 App Group 容器。配对的 Apple Watch 通过系统 WatchConnectivity 接收用量、显示名称、标签和显示偏好，并在手表本地缓存；不会收到 Cookie、自定义接口令牌或认证请求头。

### 本 App 向哪里发请求

- 登录和刷新在你选择的服务商网页及其认证流程内进行，使用该服务的 Cookie 或站内令牌。网页加载的资源由服务商控制，适用相应服务商的隐私政策。
- 自定义用量源向你填写的 HTTPS 地址发送请求，并按配置附带访问令牌；跨域重定向不转发 Bearer 令牌。请只配置你信任的接口。
- 接收网络请求的服务会获知请求所需的认证信息、IP 地址等常规网络信息。这些请求不经过开发者的服务器。
- 本 App 不包含统计、广告或自动崩溃上报 SDK。

### 分享与照片

用量分享图在设备上生成。你可以选择包含哪些账号及明细；保存到照片或通过系统分享发送后，图片由你选择的系统服务、应用或接收者处理。添加自定义图标使用系统照片选择器，不要求读取整个照片库。

### 提醒

用量提醒是本地通知，由本 App 在设备上根据已保存的快照计算，不经过任何推送服务器。

### 反馈邮件

设置 → 高级 → 反馈会打开系统邮件编辑器，收件人是 canonforge5421@gmail.com；你可以选择是否附带本地诊断文本。发送前可检查、编辑或取消。只有主动发送后，开发者才会收到你的邮件地址、正文和保留的附件，用于处理反馈；可向同一地址申请删除反馈记录。

### 删除数据

- 在 App 内退出某账号会清理对应的本地登录数据和用量缓存；移除自定义账号会删除其本地令牌和快照。账号配置与一般显示偏好可能仍会保留。
- 本地清理不等于删除服务商账号，也不会撤销服务商或认证平台保留的记录。需要删除远端账号或撤销服务端会话时，请在相应服务中操作。
- 手表可能在下次与手机成功同步前保留旧缓存。已保存、发送的图片或邮件，以及系统备份中的副本，需要在对应设备或服务中分别管理。
- 删除 App 后，本地数据的清理由系统管理；备份恢复或仍安装的配套组件可能影响数据保留。本 App 不向开发者提供远程访问设备数据的接口。

### 儿童

本 App 不面向 13 岁以下儿童。

### 变更

本页有变动时会更新并修改生效日期。

### 联系

canonforge5421@gmail.com

## English

### In one sentence

Usage Limits has no developer-operated usage server or analytics SDK and does not automatically send account credentials or usage to the developer. Signing in and refreshing require communication with services you select. Local storage, Watch sync, sharing and feedback are described below.

### What the app stores on your device

- **Sign-in state**: cookies and site tokens created on official websites inside the app's browser. The app's WebKit website data stores manage them for the relevant service and its authentication flow; they are not automatically shared with Safari.
- **Usage snapshots**: usage figures, quotas, reset times and necessary display labels, plan and status information. These exclude cookies, access tokens and redeemable reset-credit identifiers.
- **Custom source tokens**: if you add a custom endpoint, its token is kept in a separate on-device key. It is never included in snapshots or sent to Apple Watch.
- **Account configuration and preferences**: selected services, display names, local identity fingerprints, custom endpoint addresses and field mappings, display options, alert thresholds, refresh intervals and appearance. Fingerprints help prevent account mix-ups; the original identity values used to generate them are not stored.
- **Local diagnostics**: status, timestamps and redacted information used to investigate refresh and parsing errors. Diagnostics are not automatically uploaded.

The app and widgets use the device's sandbox and App Group container. The paired Apple Watch receives usage, display names, labels and display preferences through WatchConnectivity and caches them locally. It does not receive cookies, custom endpoint tokens or authentication headers.

### Where the app sends requests

- Sign-in and refresh take place in the selected service's website and authentication flow, using that service's cookies or site tokens. Website resources are controlled by the service and subject to its privacy policy.
- Custom sources send requests to your configured HTTPS address with the configured access token. Cross-host redirects do not forward the Bearer token. Only configure endpoints you trust.
- Receiving services obtain authentication details needed for the request and ordinary network information such as IP addresses. These requests do not pass through a developer server.
- The app has no analytics, advertising or automatic crash-reporting SDK.

### Sharing and photos

Usage images are generated on the device. You choose the accounts and details to include. After saving to Photos or sending through the system share sheet, the selected service, app or recipient handles the image. Custom icons use the system photo picker without requiring access to the entire photo library.

### Alerts

Usage alerts are local notifications computed on the device from stored snapshots. No push server is involved.

### Feedback email

Settings → Advanced → Feedback opens the system mail composer addressed to canonforge5421@gmail.com; you can choose whether to include a local diagnostic text attachment. You can inspect, edit or cancel before sending. Only if you send it does the developer receive your email address, message and retained attachments to handle your feedback. You can request deletion of feedback records at the same address.

### Deleting your data

- Signing out clears the corresponding local sign-in data and usage cache. Removing a custom account deletes its local token and snapshot. Account configuration and general display preferences may remain.
- Local cleanup does not delete the service account or records retained by the service or identity provider. Use the relevant service to delete a remote account or revoke server-side sessions.
- A Watch may retain an older cache until its next successful sync. Saved or shared images, emails and system backup copies must be managed separately on the relevant device or service.
- The operating system manages local data removal after app deletion; restoring backups or keeping companion components installed can affect retention. The app provides no developer interface for remotely accessing device data.

### Children

The app is not directed at children under 13.

### Changes

Changes will be posted on this page with a new effective date.

### Contact

canonforge5421@gmail.com
