# 귀띔 수집 배치 실행기 (Windows 작업 스케줄러용, D-006 매일 09:00·18:00)
# - 시작·끝을 Windows 알림으로 띄운다: gemma4(GPU) 사용 여부와 분석 건수, 걸린 시간
# - 출력은 -LogFile 에 이어 쓴다 (UTF-8)
# 사용: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run_batch.ps1 -DataDir <data\local> [-ProjectId gwittim-dev]
# - 게시판 다음에 알림톡도 돈다 (D-036): 카톡 내보내기 폴더(-KakaoDir, 기본 <Gwittim>\localModel\kakaoTalk_data)와
#   팀장 폰 수집기 받은편지함(Firestore kakao_inbox). 폴더가 없으면 알림톡은 건너뛴다
# - 알림톡 앞에서 PC 카톡의 학교 채널을 <KakaoDir>\auto 로 자동 내보낸다 (D-041, scripts\export_kakao.ps1).
#   폰 알림은 200자에서 잘리므로 전문은 내보내기로 채운다. 방마다 가장 새 파일만 읽는다. -NoKakaoExport 로 끈다
# - 게시판 다음, 알림톡 앞에 교외 공모전·대외활동(D-038, D-059: 위비티·콘테스트코리아·링커리어)을 차례로 돈다. 같은 data\local을 쓰므로 직렬로만.
#   robots·3초 간격·실행당 상한은 수집기가 지킨다. 실패해도 배치는 이어간다(종료 코드에 넣지 않음). -NoExternal 로 끈다
# - 명지 게시판 다음, 교외 앞에 숭의여대 공지(D-045, 학교 팩)를 돈다. 교외와 같은 규칙(실패해도 이어감). -NoSewu 로 끈다
# Windows 알림(WinRT)이 필요하므로 Windows PowerShell 5.1로 실행한다. 이 파일은 UTF-8 BOM으로 저장한다(5.1의 한글 처리).
param(
    [Parameter(Mandatory = $true)][string]$DataDir,
    [string]$ProjectId = "gwittim-dev",
    [string]$LogFile = (Join-Path $DataDir "batch.log"),
    [string]$Uv = "uv",
    [string]$KakaoDir = "",
    [switch]$NoKakaoExport,
    [switch]$NoExternal,
    [switch]$NoSewu
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

# 숭의여대 공지 (D-045): 명지 게시판 다음, 교외 앞. 실패해도 배치는 이어간다(종료 코드에 넣지 않음)
$sewuPublished = 0
$sewuNote = ""
if ($exit -eq 0 -and -not $NoSewu) {
    Push-Location $code
    try {
        $slines = & $Uv run --frozen python -m backend.collectors.sewu_www --data-dir $DataDir 2>&1 | ForEach-Object { "$_" }
        $sexit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    foreach ($line in $slines) { Write-Log $line }
    $sline = $slines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
    if ($sexit -eq 0 -and $sline) {
        $sw = $sline | ConvertFrom-Json
        $sewuPublished = [int]$sw.published
        if ($sw.stopped) { $sewuNote = " (멈춤)" }
    } else {
        $sewuNote = " (실패)"
    }
}

# 교외 공모전·대외활동 (D-038, D-059): 게시판 다음, 알림톡 앞. 출처마다 따로 돌리고 한 곳이 실패해도 다음으로 넘어간다
# 정기 배치 상한(D-059, 팀장 2026-11-26 '최대한 많이'): 출처·메뉴마다 목록 5페이지·새 공고 상세 50건. 사이트 합 30건 상한은 폐지했다.
# 외부 단계 전체 실행 시간은 30분이다. 넘으면 남은 출처는 건너뛰고(다음 배치에서 새 공고로 이어짐) 로그에 남긴다.
# 순서(새 공고가 많은 곳이 시간 상한에 밀리지 않게): 모수·새 공고량이 큰 순서. 2026-11-26 실측 링커리어 대외활동 약 1,400건·공모전 약 400건으로
# 가장 크고(첫 시험에서 두 메뉴 모두 상세 30건 상한까지 새 공고), 위비티 공모전·대외활동, 콘테스트코리아(첫 배치 21건)·씽굿(목록 JSON에 본문이 들어 있어 요청이 가장 적음)·올콘(목록 약 100건)이 그 뒤다.
# 출처당 상세 50건 x 3초 + 목록 5쪽 = 약 3분이라 6곳을 모두 돌아도 약 20분이므로 보통은 시간 상한에 걸리지 않는다.
$externalSources = @("linkareer_activity", "linkareer_contest", "wevity", "wevity_activity", "contestkorea", "thinkgood_contest", "allcon_contest")
$externalBudgetSeconds = 30 * 60
$externalClock = [System.Diagnostics.Stopwatch]::StartNew()
$externalPublished = 0
$externalNote = ""
if ($exit -eq 0 -and -not $NoExternal) {
    foreach ($src in $externalSources) {
        $remaining = [int]($externalBudgetSeconds - $externalClock.Elapsed.TotalSeconds)
        if ($remaining -lt 60) {
            Write-Log "교외 $src 건너뜀: 외부 단계 30분 상한 소진 (다음 배치로 넘김)"
            $externalNote += " ($src 시간상한으로 다음 배치)"
            continue
        }
        Push-Location $code
        try {
            $xlines = & $Uv run --frozen python -m "backend.collectors.$src" --data-dir $DataDir --pages 5 --max-items 50 --max-seconds $remaining 2>&1 | ForEach-Object { "$_" }
            $xexit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        foreach ($line in $xlines) { Write-Log $line }
        $xline = $xlines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
        if ($xexit -eq 0 -and $xline) {
            $x = $xline | ConvertFrom-Json
            $externalPublished += [int]$x.published
            if ($x.stopped) { $externalNote += " ($src 멈춤)" }
        } else {
            $externalNote += " ($src 실패)"
        }
    }
}

# 알림톡 (D-019, D-036): 게시판 공고와 짝을 찾으므로 게시판 다음에 돈다
if (-not $KakaoDir) {
    $KakaoDir = Join-Path (Split-Path (Split-Path $DataDir -Parent) -Parent) "localModel\kakaoTalk_data"
}
$kakaoLine = $null
$exportNote = ""
if ($exit -eq 0 -and (Test-Path $KakaoDir)) {
    $autoDir = Join-Path $KakaoDir "auto"
    if (-not $NoKakaoExport) {
        # 내보내기 스크립트는 exit로 끝나므로 따로 띄운다. 실패해도 배치는 이어간다(폰 미리보기·예전 파일로 게시)
        $exporter = Join-Path $PSScriptRoot "export_kakao.ps1"
        $elines = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $exporter -OutDir $autoDir -WaitIdleMinutes 10 2>&1 | ForEach-Object { "$_" }
        foreach ($line in $elines) { Write-Log $line }
        $exportLine = $elines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
        if ($exportLine) {
            $e = ($exportLine | ConvertFrom-Json).kakao_export
            if ($e.status -ne 'ok') { $exportNote = " (카톡 내보내기 $($e.status): $($e.reason))" }
        } else {
            $exportNote = " (카톡 내보내기 실패)"
        }
    }
    $exportDirs = @($KakaoDir)
    if (Test-Path $autoDir) { $exportDirs += $autoDir }
    Push-Location $code
    try {
        $klines = & $Uv run --frozen python -m backend.collectors.mjc_kakao --export-dir $exportDirs --data-dir $DataDir 2>&1 | ForEach-Object { "$_" }
        $kexit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    foreach ($line in $klines) { Write-Log $line }
    $kakaoLine = $klines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
    if ($kexit -ne 0) { $exit = $kexit }
}

$minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
$summaryLine = $lines | Where-Object { $_ -like '{*' } | Select-Object -Last 1
if ($exit -eq 0 -and $summaryLine) {
    $s = $summaryLine | ConvertFrom-Json
    $o = $s.outcomes
    $gpu = if ($s.llm.used) { "gemma4 $($s.llm.analyzed)건 분석 후 GPU 해제" } else { "gemma4 사용 안 함 (바뀐 공고 없음)" }
    $kakao = ""
    if ($kakaoLine) {
        $k = $kakaoLine | ConvertFrom-Json
        $kakao = " | 알림톡 게시 $($k.published) (폰 수집 $($k.inbox))$exportNote"
    }
    $sewu = ""
    if (-not $NoSewu) { $sewu = " | 숭의 게시 $sewuPublished$sewuNote" }
    $external = ""
    if (-not $NoExternal) { $external = " | 교외 게시 $externalPublished$externalNote" }
    Show-Toast "귀띔 수집 완료 ($minutes분)" "새 $($o.new) · 변경 $($o.changed) · 그대로 $($o.unchanged) | $gpu$sewu$external$kakao"
} else {
    Show-Toast "귀띔 수집 실패" "batch.log를 확인해 주세요. (종료 코드 $exit)"
}
exit $exit
