# PDF 字体

NotoSansSC-Regular.ttf为Google Fonts官方Noto Sans SC可变TrueType字体固定wght=400的实例。使用fonttools4.60.1生成，不在运行时下载字体或发送用户数据。

来源：https://github.com/google/fonts/blob/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf

许可：同目录OFL.txt（SIL OFL1.1，保留原许可；Reserved Font Name为Source，本字体不使用该名称）。

生成：fonttools varLib.instancer NotoSansSC-variable.ttf wght=400 --output=NotoSansSC-Regular.ttf

SHA256：b6a3861ad594afe88f30c0eff922728198d51ac59323c922a29afc4322a7bead

PDF渲染器、Node回归与Edge静态资产使用同一文件。字体升级需改变renderer_version并重新检查确定性与中文/拼音字形，不能用新字体覆盖历史快照的已生成文件。
