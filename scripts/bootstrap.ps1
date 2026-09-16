$ErrorActionPreference = 'Stop'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw '未找到 Flutter。请先安装 Flutter 稳定版并把 flutter\bin 加入 PATH。'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gitArguments = @('-c', "safe.directory=$($repositoryRoot.Replace('\', '/'))")

git @gitArguments rev-parse --verify HEAD *> $null
if ($LASTEXITCODE -ne 0) {
  throw '生成平台工程前请先提交当前业务骨架，确保生成器改动可审查。'
}

if (git @gitArguments status --porcelain) {
  throw '生成平台工程前请先提交或暂存当前改动，确保工作区干净。'
}

flutter create . --platforms=android,ios --org com.learningplanet
if ($LASTEXITCODE -ne 0) {
  throw 'Flutter 平台工程生成失败。'
}

git @gitArguments diff --stat
flutter pub get
if ($LASTEXITCODE -ne 0) {
  throw 'Flutter 依赖解析失败。'
}

dart format --output=none --set-exit-if-changed lib test
if ($LASTEXITCODE -ne 0) {
  throw 'Dart 格式检查失败。'
}

dart analyze
if ($LASTEXITCODE -ne 0) {
  throw 'Dart 静态分析失败。'
}

flutter test --no-test-assets
if ($LASTEXITCODE -ne 0) {
  throw 'Flutter 测试失败。'
}

Write-Host '学习星球项目初始化完成。'
