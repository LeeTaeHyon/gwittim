# 귀띔 수집 배치 실행기 (Windows 작업 스케줄러용, D-006 매일 09:00·18:00)
# - 시작·끝을 Windows 알림으로 띄운다: gemma4(GPU) 사용 여부와 분석 건수, 걸린 시간
# - 출력은 -LogFile 에 이어 쓴다 (UTF-8)
# 사용: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run_batch.ps1 -DataDir <data\local> [-ProjectId gwittim-dev]
# Windows 알림(WinRT)이 필요하므로 Windows PowerShell 5.1로 실행한다. 이 파일은 UTF-8 BOM으로 저장한다(5.1의 한글 처리).
param(
    [Parameter(Mandatory = $true)][string]$DataDir,
    [string]$ProjectId = "gwittim-dev",
    [string]$LogFile = (Join-Path $DataDir "batch.log"),
    [string]$Uv = "uv"
)

$ErrorActionPreference = "Continue"
$code = Split-Path $PSScriptRoot -Parent
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$text) {
    [System.IO.File]::AppendAllText($LogFile, $text + "`r`n", $utf8)
}

function Show-Toast([string]$title, [string]$body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [System.Security.SecurityElement]::Escape($title)
        $b = [System.Security.SecurityElement]::Escape($body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        Write-Log "  (알림 표시 실패: $($_.Exception.Message))"
    }
}

$started = Get-Date
Write-Log ("=== " + $started.ToString("s"))
Show-Toast "귀띔 수집 시작" ("공지를 확인합니다. 새 공고가 있으면 gemma4가 GPU를 잠시 씁니다. (" + $started.ToString("HH:mm") + ")")

$env:GWITTIM_FIREBASE_PROJECT_ID = $ProjectId
$env:PYTHONIOENCODING = "utf-8"
Push-Location $code
try {
    $lines = & $Uv run --frozen python -m backend.collectors.mjc_www --data-dir $DataDir 2>&1 | ForEach-Object { "$_" }
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
}
foreach ($line in $lines) { Write-Log $line }

$minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
$summaryLine = $lines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
if ($exit -eq 0 -and $summaryLine) {
    $s = $summaryLine | ConvertFrom-Json
    $o = $s.outcomes
    $gpu = if ($s.llm.used) { "gemma4 $($s.llm.analyzed)건 분석 후 GPU 해제" } else { "gemma4 사용 안 함 (바뀐 공고 없음)" }
    Show-Toast "귀띔 수집 완료 ($minutes분)" "새 $($o.new) · 변경 $($o.changed) · 그대로 $($o.unchanged) | $gpu"
} else {
    Show-Toast "귀띔 수집 실패" "batch.log를 확인해 주세요. (종료 코드 $exit)"
}
exit $exit
