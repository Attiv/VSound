# 网盘音乐

维音支持两条路径：直接连接 Google Drive / Dropbox，或添加桌面网盘客户端已同步的本地目录。直接连接会下载音乐后加入现有曲库，继续使用原生播放引擎、EQ、队列、歌词和快捷键。

## 使用已同步的文件夹

在“设置 → 网盘”或网盘窗口中点击“添加已同步的网盘文件夹…”，通过访达选择音乐目录。Google Drive、Dropbox、OneDrive、iCloud Drive 等客户端提供的本地目录均可使用这一入口，不需要配置维音的 OAuth 应用。

先在对应网盘客户端中将文件夹设为离线可用，等待下载完成。只在云端的占位文件能否读取由该客户端决定，维音不会主动管理这些客户端的下载或同步。

## 直接连接账号

1. 维护者按下文配置维音的 OAuth 应用。发行构建应预置公开的 Client ID / App key，最终用户无需注册开发者应用。
2. 打开“设置 → 网盘”，点击对应服务的“连接账号”，在系统浏览器的官方页面完成授权。
3. 回到“网盘音乐”，进入音乐文件夹，点击“导入当前文件夹”。包含子目录、受支持音频和同目录同名 LRC；搜索框仅筛选当前目录。
4. 下载和索引完成后，在曲库或侧栏的来源文件夹中播放。下次导入同一目录时，已完成且版本未变化的文件会复用。

每个服务同时连接一个账号。下载可停止；重新导入会复用完整文件，不续传未完成文件的字节。目录列表读取失败、授权失效或限流时会提示，稍后可重试。个别音频或 LRC 下载失败时会显示文件名，其余完整文件仍可加入曲库。

## 维护者配置：Google Drive

在维护者自己的 Google Cloud 项目中启用 Google Drive API，配置 Google Auth 平台的应用信息、受众与数据访问。创建类型为 **Desktop app** 的 OAuth 客户端，将 Client ID 配置到维音。不要使用 Web、iOS 或服务账号凭据。

应用请求 `https://www.googleapis.com/auth/drive.readonly`，用于浏览已有文件夹并下载音乐。该权限能够读取账号中的全部 Drive 文件，并不限于所选目录；维音只在选择导入后下载对应目录内的受支持音频及 LRC。Google 将此 scope 列为 restricted scope，公开发行前应按项目适用情形完成 Google 的应用验证要求，不能把测试模式视为正式发布。

External 应用测试时，在 Google Auth 平台的 Audience 中加入测试用户；组织内应用需满足组织和管理员策略。若使用 Cloud Console 提供的 Client Secret，可在“开发者应用配置”内输入；该可选值随成功连接的凭据存入本机钥匙串。原生客户端不能依赖 secret 的保密性，维音始终使用 PKCE S256。

回调采用本机 `http://127.0.0.1:53682/oauth/callback`。Desktop OAuth 客户端使用 loopback 回调，不需要部署公网回调服务器。浏览器授权和令牌换取使用同一地址。

参考：[Google 桌面 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)、[Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)、[Drive 环境配置](https://developers.google.com/workspace/drive/api/quickstart/python)。

## 维护者配置：Dropbox

在 Dropbox App Console 创建 Scoped access 应用。访问用户已有的音乐目录时选择 **Full Dropbox**；App Folder 只能访问应用专用目录。Full Dropbox 的目录范围与下面的只读 scopes 分别配置，不需要开启写权限。

在 Permissions 中启用 `files.metadata.read` 和 `files.content.read` 并保存。Settings 中允许 public clients / PKCE，将下列地址原样加入 Redirect URIs，路径和端口必须一致：

```text
http://127.0.0.1:53682/oauth/callback
```

将 App key 配置到维音。Dropbox 使用 PKCE S256，不需要把 App secret 放入应用。维音请求 offline access，以便短期访问令牌到期后刷新。面向更多用户发行时，维护者还需检查 Dropbox App Console 的开发状态、账号限制和生产审批要求。

参考：[Dropbox OAuth 和权限](https://docs.dropboxapi.com/dropbox-api/docs/oauth)、[Dropbox 授权参数](https://docs.dropboxapi.com/dropbox-api/docs/get-started/authorization)。

## 将公开应用 ID 放入构建

使用自己的有效应用 ID，执行：

```bash
VSOUND_GOOGLE_CLIENT_ID='your-desktop-client-id.apps.googleusercontent.com' \
VSOUND_DROPBOX_APP_KEY='your-dropbox-app-key' \
zsh scripts/build.sh
```

脚本将设置传给 Xcode，在 Info.plist 中生成 `VSoundGoogleClientID` 和 `VSoundDropboxAppKey`。Xcode 直接构建时也可配置对应的 `VSOUND_GOOGLE_CLIENT_ID`、`VSOUND_DROPBOX_APP_KEY` 用户定义 Build Settings。仓库不附带可用应用 ID，不提交个人令牌或下载的凭据文件。

开发时可在“设置 → 网盘 → 开发者应用配置”输入公开 ID；这些值保存在本机 UserDefaults，优先于构建内的 ID。Google 可选 secret 使用安全输入框，不保存到 UserDefaults。清除运行时 ID 只会禁用该服务的后续连接按钮，不会自动断开现有授权。

## 本机数据与边界

- 访问令牌、刷新令牌和可选 Google secret 存于 macOS 钥匙串。应用不保存网盘密码，也不把令牌写入曲库或日志。
- OAuth 使用系统浏览器和 PKCE S256，并验证随机 state、回调来源、路径和参数。HTTP 接收器只绑定 `127.0.0.1:53682`，授权结束或取消后关闭，三分钟未完成则超时；端口占用时需释放后重试。
- 下载存于应用数据目录 `CloudMusic/<provider>/<connection>/<folder>/<file>/`。每次重新连接分配独立缓存命名空间，避免不同账号的同名或同 ID 文件混用；断开后重连可能产生额外缓存。
- 下载先写临时文件，核对已知文件大小后替换缓存，使用远端版本和本地长度判断是否复用。远端改名时保留首次缓存的本地文件名，以免破坏已有队列。
- 断开连接只移除本机凭据，不向网盘撤销其他会话，不删除本地音乐。需要撤销服务端授权时，在 Google / Dropbox 的账号应用管理中操作。
- 缓存不自动清理，可能占用较大磁盘空间。从曲库移除文件夹只移除索引；确需释放空间时，先退出播放，再从设置中打开应用数据目录，手动删除对应缓存。
- 重新扫描曲库只索引已下载文件；更新远端内容需要再次进入网盘目录并导入。远端删除不会同步删除本地缓存。
- 当前不实现流式播放、自动同步、远端写入、多账号切换、Google 快捷方式解析、共享云端硬盘目录入口或 Dropbox 团队空间选择器。其他网盘通过本地同步目录使用。

## 验证状态

自动化测试使用模拟 HTTP、临时目录、合成 WAV/LRC 和真实本机回调连接，覆盖授权、分页、刷新、限流、下载、缓存和扫描链路。未使用真实 Google Drive / Dropbox 账号执行完整授权和下载；配置维护者应用 ID 后仍需做账号端到端验收。当前本机构建使用 ad-hoc 签名，正式发行还需稳定签名、公证和两家服务各自的应用发布配置。
