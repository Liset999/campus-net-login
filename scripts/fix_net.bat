@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title 校园网网络修复与登录地址检测

set "REG_PATH=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "STARTUP_FILE=%STARTUP_DIR%\fix_net.bat"
set "SELF=%~f0"
set "STARTUP_RUN=0"
set "MODE=auto"
set "ELEVATED=0"
set "RESET_DNS=0"
set "NO_STARTUP_PROMPT=0"

if /I "%SELF%"=="%STARTUP_FILE%" (
    set "STARTUP_RUN=1"
    set "MODE=fix"
    set "NO_STARTUP_PROMPT=1"
)

:ParseArgs
if "%~1"=="" goto ArgsDone
if /I "%~1"=="/remove-startup" goto RemoveStartup
if /I "%~1"=="--remove-startup" goto RemoveStartup
if /I "%~1"=="/elevated" set "ELEVATED=1"
if /I "%~1"=="/fix" set "MODE=fix"
if /I "%~1"=="--fix" set "MODE=fix"
if /I "%~1"=="/diagnose" set "MODE=diagnose"
if /I "%~1"=="--diagnose" set "MODE=diagnose"
if /I "%~1"=="/reset-dns" set "RESET_DNS=1"
if /I "%~1"=="--reset-dns" set "RESET_DNS=1"
if /I "%~1"=="/no-startup-prompt" set "NO_STARTUP_PROMPT=1"
if /I "%~1"=="--no-startup-prompt" set "NO_STARTUP_PROMPT=1"
shift
goto ParseArgs

:ArgsDone
call :DetectNetwork

if /I "%MODE%"=="diagnose" goto DiagnoseOnly
if /I "%MODE%"=="fix" goto EnsureElevatedAndFix
goto AutoFlow

:AutoFlow
echo.
echo ==========================================
echo   校园网登录检测与一键修复 (Windows)
echo ==========================================
echo 接口：%INTERFACE% ^| IP：%CUR_IP% ^| 网关：%CUR_GW%
if not "%TUN_LIST%"=="" call :PrintTunnelHint
if not "%MANUAL_DNS%"=="" echo [提示] 当前设置了手动 DNS（%MANUAL_DNS%），若认证页打不开可带 /reset-dns 重置为自动 DNS。

set "NEED_FIX=0"
set "FIX_REASON="
if "%PROXY_ON%"=="1" set "NEED_FIX=1" & set "FIX_REASON=系统代理仍开启"
if "%IF_UP%"=="0" set "NEED_FIX=1" & call :AppendReason "网卡未连接"
if "%CUR_IP%"=="无" set "NEED_FIX=1" & call :AppendReason "未获取有效IP"
if "%CUR_IP:~0,8%"=="169.254." set "NEED_FIX=1" & call :AppendReason "当前为保留地址169.254.x.x"

if "%NEED_FIX%"=="1" (
    echo.
    call :PrintPrefixed "[自动修复] 发现需要修复的问题：" FIX_REASON
    goto EnsureElevatedAndFix
)

call :ProbePortal
echo.
if /I "%PORTAL_STATE%"=="redirect" goto AutoShowPortal
if /I "%PORTAL_STATE%"=="js_redirect" goto AutoShowPortal
if /I "%PORTAL_STATE%"=="online" (
    echo [完成] 本机代理与 IP 正常，当前已可正常联网，无需认证登录。
    echo.
    choice /C FQ /N /M "按 [F] 仍执行完整网络修复，或按 [Q] 退出："
    if errorlevel 2 exit /b 0
    goto EnsureElevatedAndFix
)

call :PrintPrefixed "[提示] 本机代理已关、IP 正常，但探测认证页异常：" PORTAL_DETAIL
if not "%PORTAL_URL%"=="" call :PrintPrefixed "       捕获跳转地址：" PORTAL_URL
echo.
choice /C YN /N /M "是否执行 6 步网络修复并重探登录地址？[Y/N]："
if errorlevel 2 exit /b 0
goto EnsureElevatedAndFix

:AutoShowPortal
echo ==========================================
echo   检测到校园网登录地址：
call :PrintPrefixed "  " PORTAL_URL
echo ==========================================
echo.
choice /C OFQ /N /M "按 [O] 用默认浏览器打开 / [F] 仍执行完整网络修复 / [Q] 退出："
if errorlevel 3 exit /b 0
if errorlevel 2 goto EnsureElevatedAndFix
start "" "%PORTAL_URL%"
exit /b 0

:DiagnoseOnly
call :ProbePortal
echo.
echo ==========================================
echo   校园网断网只读检测 (Windows)
echo ==========================================
echo 接口：%INTERFACE%（在线：%IF_UP%）
echo IP：%CUR_IP% ^| 网关：%CUR_GW%
echo 系统代理开启：%PROXY_ON%
echo 手动 DNS：%MANUAL_DNS%
call :PrintPrefixed "虚拟网卡：" TUN_LIST
call :PrintPrefixed "认证探测：" PORTAL_STATE
call :PrintPrefixed "探测详情：" PORTAL_DETAIL
if not "%PORTAL_URL%"=="" call :PrintPrefixed "登录地址：" PORTAL_URL
echo.
pause
exit /b 0

:EnsureElevatedAndFix
fltmc >nul 2>&1
if errorlevel 1 if "%ELEVATED%"=="0" (
    echo 正在请求管理员权限...
    set "FIX_NET_SELF=%SELF%"
    set "FIX_NET_FLAGS=/elevated /fix"
    if "%RESET_DNS%"=="1" set "FIX_NET_FLAGS=%FIX_NET_FLAGS% /reset-dns"
    if "%NO_STARTUP_PROMPT%"=="1" set "FIX_NET_FLAGS=%FIX_NET_FLAGS% /no-startup-prompt"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:FIX_NET_SELF -ArgumentList $env:FIX_NET_FLAGS -Verb RunAs"
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
if not "%MANUAL_DNS%"=="" (
    if "%RESET_DNS%"=="1" (
        netsh interface ip set dns name="%INTERFACE%" dhcp >nul 2>&1
        if errorlevel 1 (
            echo [失败] 无法将 %INTERFACE% 的 DNS 恢复为自动获取
            set "RESULT=1"
        ) else (
            echo [完成] 已清除手动 DNS（%MANUAL_DNS%），恢复为 DHCP 自动获取
        )
    ) else (
        echo [提示] %INTERFACE% 当前设置了手动 DNS（%MANUAL_DNS%）；若认证页仍打不开，可加 /reset-dns 参数恢复自动 DNS
    )
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

if "%STARTUP_RUN%"=="0" (
    call :DetectNetwork
    call :ProbePortal
    echo.
    if /I "%PORTAL_STATE%"=="redirect" (
        echo ==========================================
        echo   检测到校园网登录地址：
        call :PrintPrefixed "  " PORTAL_URL
        echo ==========================================
    ) else if /I "%PORTAL_STATE%"=="js_redirect" (
        echo ==========================================
        echo   检测到校园网认证页（请用浏览器打开）：
        call :PrintPrefixed "  " PORTAL_URL
        echo ==========================================
    ) else if /I "%PORTAL_STATE%"=="online" (
        echo [完成] 当前网络已正常联网，无需认证登录。
    ) else (
        call :PrintPrefixed "[提示] 暂未探测到校园网跳转地址：" PORTAL_DETAIL
        if not "%PORTAL_URL%"=="" call :PrintPrefixed "       捕获跳转地址：" PORTAL_URL
    )
    if not "%TUN_LIST%"=="" call :PrintTunnelHint
    if not "%PORTAL_URL%"=="" (
        echo.
        choice /C YN /N /M "是否立即用默认浏览器打开登录地址？[Y/N]："
        if not errorlevel 2 start "" "%PORTAL_URL%"
    )
)

if "%STARTUP_RUN%"=="0" if "%NO_STARTUP_PROMPT%"=="0" if not exist "%STARTUP_FILE%" (
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

:AppendReason
if defined FIX_REASON (
    set "FIX_REASON=%FIX_REASON%、%~1"
) else (
    set "FIX_REASON=%~1"
)
exit /b 0

:PrintPrefixed
setlocal EnableDelayedExpansion
set "_P=%~1"
set "_V=!%~2!"
echo(!_P!!_V!
endlocal
exit /b 0

:PrintTunnelHint
setlocal EnableDelayedExpansion
echo [提示] 检测到活跃虚拟网卡（!TUN_LIST!），若仍弹不出登录页请先关闭代理 TUN 模式。
endlocal
exit /b 0

:DetectNetwork
set "INTERFACE=WLAN"
set "IF_UP=0"
set "CUR_IP=无"
set "CUR_GW=无"
set "PROXY_ON=0"
set "TUN_LIST="
set "MANUAL_DNS="
for /f "usebackq tokens=1,* delims==" %%A in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System; $nics=[System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces(); $tun=($nics|Where-Object{$_.OperationalStatus -eq 'Up' -and ($_.Name -match 'Clash|Mihomo|Meta|sing-box|Wintun|WireGuard|utun' -or $_.Description -match 'Clash|Mihomo|Meta|Wintun|sing-box')}|Select-Object -ExpandProperty Name) -join ', '; $w=$nics|Where-Object{$_.NetworkInterfaceType -eq 'Wireless80211' -and $_.OperationalStatus -eq 'Up'}|Select-Object -First 1; if(-not $w){$w=$nics|Where-Object{$_.NetworkInterfaceType -eq 'Wireless80211'}|Select-Object -First 1}; if(-not $w){$w=$nics|Where-Object{$_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and $_.Name -notmatch 'Clash|Mihomo|Meta|sing-box|Wintun|Hyper-V|vEthernet|VMware|VirtualBox|Loopback'}|Select-Object -First 1}; $if=if($w){$w.Name}else{'WLAN'}; $up=if($w -and $w.OperationalStatus -eq 'Up'){'1'}else{'0'}; $p=if($w){$w.GetIPProperties()}else{$null}; $ip=if($p){($p.UnicastAddresses|Where-Object{$_.Address.AddressFamily -eq 'InterNetwork'}|Select-Object -First 1).Address.IPAddressToString}else{''}; if(-not $ip){$ip='无'}; $gw=if($p){($p.GatewayAddresses|Where-Object{$_.Address.AddressFamily -eq 'InterNetwork'}|Select-Object -First 1).Address.IPAddressToString}else{''}; if(-not $gw){$gw='无'}; $reg=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue; $pon=if(($reg.ProxyEnable -eq 1) -or ($reg.AutoConfigURL)){'1'}else{'0'}; $md=''; if($w){$ir=Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'+$w.Id) -ErrorAction SilentlyContinue; if($ir -and $ir.NameServer){$md=$ir.NameServer}}; 'INTERFACE='+$if; 'IF_UP='+$up; 'CUR_IP='+$ip; 'CUR_GW='+$gw; 'PROXY_ON='+$pon; 'TUN_LIST='+$tun; 'MANUAL_DNS='+$md"`) do (
    set "%%A=%%B"
)
exit /b 0

:ProbePortal
set "PORTAL_STATE=error"
set "PORTAL_URL="
set "PORTAL_DETAIL=探测失败"
for /f "usebackq tokens=1,* delims==" %%A in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "function Probe($u,$redir){$r=[System.Net.HttpWebRequest]::Create($u);$r.Method='GET';$r.AllowAutoRedirect=$redir;$r.Proxy=$null;$r.Timeout=4500;$r.ReadWriteTimeout=4500;$r.UserAgent='CaptiveNetworkSupport/1.0 wispr';try{$resp=$r.GetResponse();$c=[int]$resp.StatusCode;$loc=$resp.Headers['Location'];$sr=New-Object System.IO.StreamReader($resp.GetResponseStream());$b=$sr.ReadToEnd();$sr.Close();$resp.Close();return @{Code=$c;Loc=$loc;Body=$b;Err=''}}catch [System.Net.WebException]{if($_.Exception.Response){$er=$_.Exception.Response;$c=[int]$er.StatusCode;$l=$er.Headers['Location'];$er.Close();return @{Code=$c;Loc=$l;Body='';Err=''}};return @{Code=0;Loc='';Body='';Err=(($_.Exception.Message -replace '[\r\n]+',' ') -replace [char]34,[char]39)}}}; $res=Probe 'http://www.msftconnecttest.com/connecttest.txt' $false; if($res.Code -eq 0){$res2=Probe 'http://captive.apple.com/hotspot-detect.html' $false; if($res2.Code -ne 0){$res=$res2}}; $st='error'; $url=''; $det=$res.Err; if($res.Code -eq 200 -and ($res.Body -match 'Microsoft Connect Test|Success')){$st='online';$det='200 OK'}elseif(301,302,303,307,308 -contains $res.Code){$url=([string]$res.Loc) -replace [char]34,''; if($url){$p2=Probe $url $true; if($p2.Code -eq 200 -or $p2.Code -eq 302){$st='redirect';$det='HTTP '+$p2.Code}else{$st='stalled';$det='认证服务器无响应 (HTTP '+$p2.Code+' '+$p2.Err+')'}}else{$st='redirect';$det='HTTP '+$res.Code}}elseif($res.Code -eq 200){$st='js_redirect'; $url='http://www.msftconnecttest.com/redirect'; if($res.Body -match '(https?://(?!www\.w3\.org)[^\s''<>\x22;]+)'){$url=$matches[1]}; $det='HTTP 200 劫持页'}; 'PORTAL_STATE='+$st; 'PORTAL_URL='+$url; 'PORTAL_DETAIL='+$det"`) do (
    set "%%A=%%B"
)
exit /b 0
