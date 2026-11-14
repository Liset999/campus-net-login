@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title 校园网网络修复 - DHCP DNS 代理

set "INTERFACE=WLAN"
set "REG_PATH=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "STARTUP_FILE=%STARTUP_DIR%\fix_net.bat"
set "SELF=%~f0"
set "STARTUP_RUN=0"

if /I "%SELF%"=="%STARTUP_FILE%" set "STARTUP_RUN=1"

if /I "%~1"=="/remove-startup" goto RemoveStartup

fltmc >nul 2>&1
if errorlevel 1 if /I not "%~1"=="/elevated" (
    echo 正在请求管理员权限...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/elevated' -Verb RunAs"
    exit /b 0
)

fltmc >nul 2>&1
if errorlevel 1 (
    echo [失败] 未取得管理员权限，脚本未执行。
    pause
    exit /b 1
)

set "RESULT=0"
echo.
echo ==========================================
echo   刷新校园网网络环境
echo   接口：%INTERFACE%
echo ==========================================
echo.

echo [1/6] 关闭 Windows 系统代理...
reg add "%REG_PATH%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
if errorlevel 1 (
    echo [失败] 无法关闭系统代理
    set "RESULT=1"
) else (
    echo [完成] 系统代理已关闭
)

echo [2/6] 清理代理地址和 PAC...
reg add "%REG_PATH%" /v ProxyServer /t REG_SZ /d "" /f >nul
reg delete "%REG_PATH%" /v AutoConfigURL /f >nul 2>&1
netsh winhttp reset proxy >nul 2>&1
echo [完成] 代理地址和 PAC 已清理

echo [3/6] 刷新 DNS 缓存...
ipconfig.exe /flushdns >nul
if errorlevel 1 (
    echo [失败] DNS 缓存刷新失败
    set "RESULT=1"
) else (
    echo [完成] DNS 缓存已刷新
)

echo [4/6] 清理 ARP 缓存...
netsh interface ip delete arpcache >nul 2>&1
if errorlevel 1 (
    echo [提示] ARP 缓存清理未完成
) else (
    echo [完成] ARP 缓存已清理
)

echo [5/6] 释放 %INTERFACE% 的 DHCP 租约...
ipconfig.exe /release "%INTERFACE%" >nul
if errorlevel 1 (
    echo [失败] DHCP 租约释放失败
    set "RESULT=1"
) else (
    echo [完成] DHCP 租约已释放
)

echo [6/6] 重新获取 %INTERFACE% 的 DHCP 租约...
ipconfig.exe /renew "%INTERFACE%"
if errorlevel 1 (
    echo [失败] DHCP 租约续租失败
    set "RESULT=1"
) else (
    echo [完成] DHCP 租约已续租
)

if "%STARTUP_RUN%"=="0" if not exist "%STARTUP_FILE%" (
    echo.
    choice /C YN /N /M "是否加入当前用户开机启动？[Y/N]："
    if errorlevel 2 goto Finish
    copy /Y "%SELF%" "%STARTUP_FILE%" >nul
    if errorlevel 1 (
        echo [失败] 加入开机启动失败
        set "RESULT=1"
    ) else (
        echo [完成] 已加入开机启动
    )
)

goto Finish

:RemoveStartup
if exist "%STARTUP_FILE%" (
    del /F /Q "%STARTUP_FILE%" >nul
    echo 已移除开机启动：%STARTUP_FILE%
) else (
    echo 未找到开机启动项。
)
goto End

:Finish
echo.
if "%RESULT%"=="0" (
    echo 网络刷新完成。
) else (
    echo 网络刷新完成，但有步骤失败，请查看上面的提示。
)
timeout /t 3 /nobreak >nul

:End
exit /b %RESULT%
