@echo off
chcp 65001 >nul
setlocal
set HERE=%~dp0

echo [1/1] 调用飞牛官方 fnpack 打包
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
