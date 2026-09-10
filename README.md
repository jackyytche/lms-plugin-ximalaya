# Ximalaya 插件（LMS / Daphile，非官方）

非官方的喜马拉雅（ximalaya.com）在线音频插件，面向 **Lyrion Music Server (LMS) 7.7+** 与 **Daphile**。

> **免责声明**：本插件为个人非官方作品，与喜马拉雅官方无关；需使用自己的账号 Cookie，仅限个人使用；
> 音频只流式播放、不缓存、不分发，不捆绑任何账号凭据。

English summary: unofficial Ximalaya music-service plugin for LMS/Daphile — category/rank browsing,
exact album pagination, multi-tier quality up to lossless, real-bitrate now-playing metadata, own-cookie auth.

## 功能

- **浏览**：分类列表、排行榜、「我的专辑」（粘贴专辑链接/ID 收藏，自动分页聚合）
- **播放**：VIP 与免费专辑；付费曲目走 PC 客户端通道（`device=win` + xm-sign），web/mobile 兜底
- **音质**：24 / 64 / 128 kbps 至无损（256，实验性，账号无无损权益时自动降档）
- **播放界面元数据**：实测码率（fileSize×8÷duration，不采信服务端虚标）、时长、专辑封面
- **错误语义化**：1001→Cookie 失效提示；927/3005→无权限（查 VIP）；risk→风控稍后再试

## 安装

1. LMS/Daphile → 设置 → 插件 → **第三方仓库**，填入：

   ```
   https://github.com/USER/REPO/releases/latest/download/repo.xml
   ```

2. 安装 Ximalaya，按提示重启服务器。
3. 插件设置里粘贴 Cookie（见下）。

## 配置

- **Cookie**（必需）：桌面浏览器登录 ximalaya.com → F12 → 网络 → 任一 `www.ximalaya.com`
  请求 → 复制完整 `Cookie` 请求头 → 粘贴进插件设置。Cookie 含登录凭据，仅存本机，勿外传。
- **音质档**：64（默认）/ 128 / 无损。VIP 曲目需有效订阅。
- **移动通道**：开启后付费专辑列表带精确总集数。

## 已知限制

- **搜索不可用**：喜马拉雅搜索后端拒绝一切非官方客户端——已用与 PC 客户端完全同构的
  签名与参数验证（请求合法但仍返回空结果，绑定真实设备画像，非技术形态问题）。
  替代方案：官方 App/PC 客户端里搜索 → 复制专辑链接 → 粘贴进「我的专辑」。

## 开发

- 纯 Perl，无 LMS 核心之外的 CPAN 依赖；密码学为纯 Perl 实现（AES-128-ECB，加载期 FIPS-197 自检）。
- `t/` 下为离线桩测套件（160+ 断言）：`perl t\ximacrypt_test.pl` 等，任意 perl 5.14+ 可跑。
- 关键 LMS 钩子：`Slim::Music::Info::setRemoteMetadata`（播放元数据/封面）、
  handler 级 `getMetadataFor`（接管 remoteMeta，码率上屏）、`Slim::Player::Protocols::HTTP`。

## License

GPL-2.0 — 见 [LICENSE](LICENSE)。
