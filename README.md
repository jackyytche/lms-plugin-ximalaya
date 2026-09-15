# Ximalaya 插件（LMS / Daphile，非官方）

非官方的喜马拉雅（ximalaya.com）在线音频插件，面向 **Lyrion Music Server (LMS) 7.7+** 与 **Daphile**。

> **免责声明**：本插件为个人非官方作品，与喜马拉雅官方无关；需使用自己的账号 Cookie，仅限个人使用；
> 音频只流式播放、不缓存、不分发，不捆绑任何账号凭据。

English summary: unofficial Ximalaya music-service plugin for LMS/Daphile — in-app album search,
category/rank browsing, favourites-integrated album collection, progress-bar seek, multi-tier
quality up to lossless/HD-AAC, real-bitrate now-playing metadata, own-cookie auth.

## 功能

- **搜索**：插件菜单内直接搜索专辑（移动端通道 + 每请求动态签名），结果带封面/主播，翻页浏览，
  点击即走播放链
- **浏览**：分类列表、排行榜、专辑详情多级浏览，原生分页（页宽随界面设置）
- **收藏专辑**：任意专辑条目上用网页界面的收藏动作（⋮ → 添加到收藏夹）即可收藏；收藏的专辑
  在 LMS 收藏夹里**可点开浏览曲目**，并自动合并进插件的「我的专辑」列表；设置页也支持手工
  粘贴专辑 ID / 链接
- **播放**：VIP 与免费专辑；付费曲目走 PC 客户端通道（`device=win` + xm-sign），web/mobile 兜底；
  **进度条 seek**（转码器级，拖动不重播）
- **音质**：24 / 64 / 128 kbps 至无损/最高（256：免费曲目取原始上传，VIP 曲目按客户端档位，
  无权益自动降档）；编码按实际流判定（FLAC / AAC / MP3，含喜马拉雅 HD AAC 高码率档）
- **播放界面元数据**：实测码率（fileSize×8÷duration，不采信服务端虚标）、真实编码、时长、专辑封面
- **粘贴即播**：专辑/声音链接或纯数字 ID 直接解析播放
- **错误语义化**：1001→Cookie 失效提示；927/3005→无权限（查 VIP）；303→需登录；risk→风控稍后再试

## 安装

1. LMS/Daphile → 设置 → 插件 → **第三方仓库**，填入：

   ```
   https://github.com/jackyytche/lms-plugin-ximalaya/releases/latest/download/repo.xml
   ```

2. 安装 Ximalaya，按提示重启服务器。
3. 插件设置里粘贴 Cookie（见下）。

## 配置

- **Cookie**（必需）：桌面浏览器登录 ximalaya.com → F12 → 网络 → 任一 `www.ximalaya.com`
  请求 → 复制完整 `Cookie` 请求头 → 粘贴进插件设置。Cookie 含登录凭据，仅存本机，勿外传。
  搜索功能要求 Cookie 含 `1&_token=`（近年网页登录态均为此形态）。
- **音质档**：64（默认）/ 128 / 无损·最高（256）。VIP 曲目需有效订阅；无损需账号具备相应权益，
  否则自动降档。
- **移动通道**：开启后付费专辑列表带精确总集数与逐曲 VIP 标记。
- **后端通道**：PC + web（默认）以桌面客户端协议兜底 web 失败的专辑。

## 已知限制

- 风控限流：接口被平台风控暂时限流时，插件进入约 60 秒本地冷却并提示稍后再试（播放不受影响）。
- 收藏夹里的曲目条目按 LMS 标准方式播放；专辑条目由插件提供的 OPML feed 承载浏览。
- 平台接口随版本演进可能变动，遇到大面积失效请提交 issue 附日志。

## 开发

- 纯 Perl，无 LMS 核心之外的 CPAN 依赖；密码学为纯 Perl 实现（AES-128-ECB，加载期 FIPS-197 自检）。
- `t/` 下为离线桩测套件（**205 项断言**）：`perl t\ximacrypt_test.pl` 等，任意 perl 5.14+ 可跑。
- 关键 LMS 钩子：`Slim::Music::Info::setRemoteMetadata`（播放元数据/封面）、
  handler 级 `getMetadataFor`（接管 remoteMeta，码率/编码上屏）、`Slim::Web::Pages->addPageFunction`
  （收藏专辑的 OPML feed）、`Slim::Player::Protocols::HTTP`（转码器级 seek）。

## License

GPL-2.0 — 见 [LICENSE](LICENSE)。
