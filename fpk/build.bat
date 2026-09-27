@echo off
chcp 65001 >nul
setlocal
set HERE=%~dp0

echo [1/2] 检查行尾（CRLF 的脚本会让回调在 Linux 上静默失效）
powershell -NoProfile -ExecutionPolicy Bypass -Command "$bad = Get-ChildItem -Recurse -File '%HERE%basemetas-fileview' | Where-Object { $_.Extension -notin '.png','.PNG','.jpg','.jpeg','.ico','.exe' } | Where-Object { [IO.File]::ReadAllBytes($_.FullName) -contains 13 }; if ($bad) { Write-Host '以下文件含 CRLF，不能打包：'; $bad | ForEach-Object { Write-Host ('   ' + $_.FullName) }; exit 1 } else { Write-Host '   行尾检查通过（全部 LF）' }"
if errorlevel 1 (
  echo 行尾检查未通过，已中止打包。
  exit /b 1
)

echo [2/2] 调用飞牛官方 fnpack 打包
"%HERE%tools\fnpack.exe" build --directory "%HERE%basemetas-fileview"
if errorlevel 1 (
  echo 打包失败。
  exit /b 1
)

if not exist "%HERE%basemetas-fileview.fpk" (
  echo 未找到产出的 fpk，请检查 fnpack 输出。
  exit /b 1
)

if not exist "%HERE%..\basemetas-fileview.fpk" goto move
del /q "%HERE%..\basemetas-fileview.fpk"

:move
move /y "%HERE%basemetas-fileview.fpk" "%HERE%..\basemetas-fileview.fpk" >nul
echo.
echo 完成：%HERE%..\basemetas-fileview.fpk
echo 注意：不要对生成的 fpk 做任何后处理，manifest 里的 checksum 校验会被破坏。
exit /b 0
