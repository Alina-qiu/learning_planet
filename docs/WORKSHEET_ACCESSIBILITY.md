# 组卷字号、安全区域与图片隐私提示

日期：2026-11-06，对应PRD ERR-07/ERR-08、第9节系统字体放大及第7.3节上传提示。

## 需求核对和修复

本轮重新提取工作区的`学习星球_产品需求文档_PRD.docx`，确认与此前读取的正文一致。原文件SHA256为`4add57b35086b4281ab9651d43203e0dae27e7df2cc61614aefc8796e1324320`。

360px宽度、双倍字号下，原组卷配置的固定横排选项出现42px及167px横向溢出；原PDF预览延伸到底部导航区域，横屏未避开左右安全区域。实际页面测试的失败证据见`tmp/worksheet-layout-reproduction.log`。

现在选项标签与下拉框纵向排列，下拉框占满可用宽度；页签可横向滚动，窄屏的生成/新建按钮分行。历史记录的长标题使用完整宽度，操作按钮换行排列；状态显示中文，保留时间明确标注本机时间，生成失败提供重试说明。刷新历史及移除选题按钮增加语义说明，删除/新建确认框内容可以滚动。组卷及PDF页面避开横屏侧边安全区域，预览底部避开系统导航区域。

图片录入页及多图草稿入口补齐拍照/选图前的姓名、学校、班级和人脸检查提示。上传同意旁明确说明原图会一起保存，裁剪或增强只改变处理图；含个人信息时应先遮挡后重拍或更换图片。本轮没有新增自动模糊、修改原图字节、改变上传同意规则或增加远端传输。

## 验证

新增`test/worksheet_layout_test.dart`六项实际Widget回归，分别在360×800与800×360双倍字号下验证：

- 横向A4、随机拼音、四线三格与独立答案页可选择，创建内容及题目顺序正确，回执丢失后重试保持同一请求。
- 长标题历史记录可进入预览、返回和取消删除。
- PDF预览位于系统安全区域内，下载、打印、分享仍交付同一字节对象。

连同已有组卷、OCR、图片导入及草稿回归，共64项通过，日志`tmp/worksheet-layout-related-pass.log`。原有测试保留了排序、无授权拒绝、删除确认及同ID重试、字节改变后拒绝导出和完整性检查。

完整800项Flutter测试通过（1分29秒），核心覆盖率6518/7167（90.94%，107文件），273个Dart文件格式无变化，完整分析40.0秒无问题。日志`tmp/worksheet-layout-full-tests.log`、`tmp/worksheet-layout-format.log`和`tmp/worksheet-layout-analyze.log`。SQL、原生及PDF生成器未改，未重跑数据库/JVM，沿用此前387项及34项结果。

首次历史操作测试缺少滚动后的绘制等待，修正后未改生产代码即通过（`tmp/worksheet-history-reproduction.log`），不将该测试适配问题当作产品故障。隐私说明增加高度后，一项既有OCR重试测试也在新位置尚未绘制时点击；增加绘制等待与可点击断言后通过，保留原失败日志`tmp/worksheet-layout-related-final.log`。

使用实际页面、应用主题、Noto中文字体和Material图标完成五张截图并逐张检查：`tmp/worksheet-config-1x.png`、`tmp/worksheet-config-2x.png`、`tmp/worksheet-history-1x.png`、`tmp/worksheet-history-2x.png`、`tmp/worksheet-preview-landscape-2x.png`。捕获脚本`tmp/capture_worksheet_layout_test.dart`及最终日志`tmp/worksheet-layout-capture-final.log`。预览区域使用明确标记的测试占位，验证的是页面布局，不作为本轮PDF内容、原生打印或生成服务验收；实际PDF证据仍见[PDF集成](PDF_INTEGRATION.md)。

测试使用仓库与系统导出替身；本轮没有新云端调用或手机安装。完整测试与安装包见[测试记录](TESTING.md)及[构建记录](ANDROID_BUILD.md)。华为鸿蒙4.2/iPhone、系统读屏、真实打印/分享、云端与iOS编译仍待对应环境验收。

普通及本机APK已重建并通过内容、签名和摘要检查。构建所用临时后端已正常退出，54321端口关闭；该空库没有开展新的业务联调。
