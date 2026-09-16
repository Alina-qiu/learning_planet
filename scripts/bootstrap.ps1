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
git @gitArguments diff --stat
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test

Write-Host '学习星球项目初始化完成。'
