# PC 카카오톡에서 학교 채널 대화를 자동으로 내보낸다 (D-041). 정기 배치(run_batch.ps1)가 알림톡 단계 앞에서 부른다.
# 폰 알림은 본문이 200자에서 잘리므로(D-040) 전문은 PC 내보내기로 채운다.
#
# 하는 일 (방마다): 채팅 목록 검색칸에 방 이름 → 방 열기 → Ctrl+S(대화 내용 저장) → 저장 창에 경로 → 저장 → 방 닫기
#   저장한 뒤 같은 방의 예전 자동 내보내기 파일은 지운다(방마다 가장 새 파일 하나).
#
# 안전
#   - 메시지 입력칸에는 아무것도 보내지 않는다. 키 입력은 방 창이 맨 앞일 때 Ctrl+S 한 번뿐이다.
#   - 사람이 PC를 쓰는 중이면(최근 입력이 MinIdleSeconds 안) WaitIdleMinutes까지 기다리고, 그래도 쓰는 중이면 건너뛴다.
#     도중에 키보드·마우스 입력이 생기면 멈춘다. 끝난 뒤 메시지 입력칸 글자가 바뀌었으면 멈추고 방 창을 열어 둔다.
#   - 화면이 잠겼거나 방 창을 맨 앞으로 가져오지 못하면 그 회차는 건너뛴다(키를 보내지 않음).
#   - 사람이 미리 열어 둔 방 창은 닫지 않는다.
#   - 카톡이 꺼져 있으면 Windows 시작 때와 같은 방식으로 켠다(-NoLaunch로 끔). 로그인 화면에서 멈추면 건너뛴다.
#
# 출력: 마지막 줄에 JSON 한 줄 {"kakao_export": {...}}. 종료 코드 0(저장함 또는 건너뜀), 1(오류)
# 사용: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\export_kakao.ps1 -OutDir <폴더>
# Windows PowerShell 5.1과 PowerShell 7 모두에서 돈다. 이 파일은 UTF-8 BOM으로 저장한다(5.1의 한글 처리).
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string[]]$Rooms = @(
        '명지전문대학 교수학습지원', '명지전문대학 공지사항', '명지전문대학 원격교육지원센터',
        '명지전문대학 상담센터', '명지전문대학 스마트케어', '명지전문대학 글로벌교육센터'
    ),
    [int]$MinIdleSeconds = 120,
    [int]$WaitIdleMinutes = 0,  # PC 사용 중이면 이 시간까지 쉬는 틈을 기다린다
    [string]$KakaoExe = (Join-Path $env:ProgramFiles 'Kakao\KakaoTalk\KakaoTalk.exe'),
    [int]$LaunchWaitSeconds = 90,
    [switch]$NoLaunch           # 카톡이 꺼져 있어도 켜지 않는다
)
$ErrorActionPreference = 'Stop'

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class KakaoUi {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] static extern IntPtr SendMessageSB(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  // 다른 프로그램이 맨 앞이면 Windows가 SetForegroundWindow를 막는다. 맨 앞 창의 입력 스레드에 잠시 붙어서 가져온다
  public static bool BringToFront(IntPtr h) {
    for (int i = 0; i < 3; i++) {
      if (GetForegroundWindow() == h) return true;
      uint dummy; IntPtr fg = GetForegroundWindow();
      uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out dummy);
      uint me = GetCurrentThreadId();
      bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
      ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
      if (attached) AttachThreadInput(me, fgThread, false);
      System.Threading.Thread.Sleep(250);
    }
    return GetForegroundWindow() == h;
  }
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
  [DllImport("kernel32.dll")] static extern uint GetTickCount();
  public static uint LastInputTick() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); GetLastInputInfo(ref i); return i.dwTime; }
  public static uint Now() { return GetTickCount(); }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static string Text(IntPtr h) { var s = new StringBuilder(1024); SendMessageSB(h, 0x000D, (IntPtr)1024, s); return s.ToString(); }
  public static List<IntPtr> Kids(IntPtr p) { var r = new List<IntPtr>(); EnumChildWindows(p, (h, l) => { r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static List<IntPtr> Tops(uint pid, bool visibleOnly) {
    var r = new List<IntPtr>();
    EnumWindows((h, l) => { uint q; GetWindowThreadProcessId(h, out q); if (q == pid && (!visibleOnly || IsWindowVisible(h))) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
  // Ctrl+S
  public static void CtrlS() {
    keybd_event(0x11, 0, 0, UIntPtr.Zero); keybd_event(0x53, 0, 0, UIntPtr.Zero);
    keybd_event(0x53, 0, 2, UIntPtr.Zero); keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }
}
"@

$WM_SETTEXT = 0x000C; $WM_KEYDOWN = 0x0100; $WM_KEYUP = 0x0101; $WM_CLOSE = 0x0010; $BM_CLICK = 0x00F5; $VK_RETURN = 0x0D
$started = Get-Date
$result = [ordered]@{ status = 'ok'; reason = $null; launched = $false; rooms = [ordered]@{}; seconds = 0 }

function Finish([string]$status, [string]$reason, [int]$code) {
    $result.status = $status
    $result.reason = $reason
    $result.seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    [pscustomobject]@{ kakao_export = $result } | ConvertTo-Json -Compress -Depth 4
    exit $code
}

function Wait-For([scriptblock]$probe, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        $v = & $probe
        if ($v) { return $v }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $null
}

# 사람이 PC를 쓰는 중이면 카톡을 띄우지도 않는다
$waitUntil = (Get-Date).AddMinutes($WaitIdleMinutes)
while ($true) {
    $idle = ([KakaoUi]::Now() - [KakaoUi]::LastInputTick()) / 1000
    if ($idle -ge $MinIdleSeconds) { break }
    if ((Get-Date) -ge $waitUntil) { Finish 'skipped' ("PC 사용 중 (마지막 입력 {0:N0}초 전)" -f $idle) 0 }
    Start-Sleep -Seconds 15
}

# 카톡이 꺼져 있으면 Windows 시작 때와 같은 방식(-bystartup, 트레이로 시작)으로 켠다.
# 자동 로그인이 켜져 있으면 채팅 목록이 생길 때까지 기다리고, 로그인 화면에서 멈추면 건너뛴다
function Find-ChatSearch([uint32]$procId) {
    $m = [KakaoUi]::Tops($procId, $false) | Where-Object { [KakaoUi]::Title($_) -eq '카카오톡' } | Select-Object -First 1
    if (-not $m) { return $null }
    $l = [KakaoUi]::Kids($m) | Where-Object { [KakaoUi]::Title($_) -like 'ChatRoomListView*' } | Select-Object -First 1
    if (-not $l) { return $null }
    return [KakaoUi]::Kids($l) | Where-Object { [KakaoUi]::Cls($_) -eq 'Edit' } | Select-Object -First 1
}
$proc = Get-Process KakaoTalk -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) {
    if ($NoLaunch) { Finish 'skipped' '카카오톡이 실행 중이 아님' 0 }
    if (-not (Test-Path -LiteralPath $KakaoExe)) { Finish 'skipped' "카카오톡 실행 파일 없음: $KakaoExe" 0 }
    Start-Process -FilePath $KakaoExe -ArgumentList '-bystartup' | Out-Null
    $result.launched = $true
    $proc = Wait-For { Get-Process KakaoTalk -ErrorAction SilentlyContinue | Select-Object -First 1 } 20000
    if (-not $proc) { Finish 'skipped' '카카오톡을 켰지만 실행되지 않음' 0 }
    $search = Wait-For { Find-ChatSearch ([uint32]$proc.Id) } ($LaunchWaitSeconds * 1000)
    if (-not $search) { Finish 'skipped' "카카오톡을 켰지만 $LaunchWaitSeconds초 안에 채팅 목록이 없음 (로그인 필요일 수 있음)" 0 }
    Start-Sleep -Seconds 5   # 시작 직후 받은 메시지·창 정리를 기다린다
    # 켜는 사이 사람이 PC를 만졌으면 그만둔다
    if ((([KakaoUi]::Now() - [KakaoUi]::LastInputTick()) / 1000) -lt 5) { Finish 'skipped' 'PC 사용 중 (카톡을 켜는 사이 입력)' 0 }
}
$kpid = [uint32]$proc.Id
$search = Find-ChatSearch $kpid
if (-not $search) { Finish 'skipped' '채팅 목록 검색칸 없음 (로그인 전이거나 카톡 잠금 모드일 수 있음)' 0 }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# 우리가 보낸 키 입력 말고 다른 입력이 생겼는지 볼 기준 (사람이 PC를 만지면 멈춘다)
$ourInput = [KakaoUi]::LastInputTick()

foreach ($room in $Rooms) {
    if ([KakaoUi]::LastInputTick() -ne $ourInput) { $result.rooms[$room] = '건너뜀'; Finish 'partial' '도중에 PC 입력이 있어 멈춤' 0 }
    $opened = $false
    $chat = $null
    try {
        $chat = [KakaoUi]::Tops($kpid, $true) | Where-Object { [KakaoUi]::Title($_) -eq $room } | Select-Object -First 1
        if (-not $chat) {
            [void][KakaoUi]::SendMessage($search, $WM_SETTEXT, [IntPtr]::Zero, $room)
            Start-Sleep -Milliseconds 700
            [void][KakaoUi]::PostMessage($search, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero)
            [void][KakaoUi]::PostMessage($search, $WM_KEYUP, [IntPtr]$VK_RETURN, [IntPtr]::Zero)
            $chat = Wait-For { [KakaoUi]::Tops($kpid, $true) | Where-Object { [KakaoUi]::Title($_) -eq $room } | Select-Object -First 1 } 6000
            [void][KakaoUi]::SendMessage($search, $WM_SETTEXT, [IntPtr]::Zero, '')
            if (-not $chat) { throw '방 창이 열리지 않음' }
            $opened = $true
        }

        # 키를 보내기 전에 방 창이 맨 앞인지, 사람이 그사이 PC를 만지지 않았는지 확인
        if (-not [KakaoUi]::BringToFront($chat)) {
            $fg = [KakaoUi]::GetForegroundWindow()
            throw ("방 창을 맨 앞으로 가져오지 못함 (화면 잠김일 수 있음; 맨 앞: {0} '{1}')" -f [KakaoUi]::Cls($fg), [KakaoUi]::Title($fg))
        }
        Start-Sleep -Milliseconds 200
        if ([KakaoUi]::GetForegroundWindow() -ne $chat) { throw '방 창을 맨 앞으로 가져오지 못함 (화면 잠김일 수 있음)' }
        if ([KakaoUi]::LastInputTick() -ne $ourInput) { throw 'PC 입력이 있어 멈춤' }
        # 메시지 입력칸 글자(사람이 써 둔 글이 있을 수 있다). 끝나고 바뀌었으면 멈춘다
        $inputs = [KakaoUi]::Kids($chat) | Where-Object { [KakaoUi]::Cls($_) -in 'RICHEDIT50W', 'Edit' }
        $draft = ($inputs | ForEach-Object { [KakaoUi]::Text($_) }) -join "`n"
        $before = [KakaoUi]::Tops($kpid, $true)
        [KakaoUi]::CtrlS()
        Start-Sleep -Milliseconds 150
        $ourInput = [KakaoUi]::LastInputTick()

        $dlg = Wait-For { [KakaoUi]::Tops($kpid, $true) | Where-Object { [KakaoUi]::Cls($_) -eq '#32770' } | Select-Object -First 1 } 8000
        if (-not $dlg) { throw '저장 창이 뜨지 않음' }
        $kids = [KakaoUi]::Kids($dlg)
        $nameBox = $kids | Where-Object { [KakaoUi]::Cls($_) -eq 'Edit' -and [KakaoUi]::GetDlgCtrlID($_) -eq 1001 } | Select-Object -First 1
        $saveBtn = $kids | Where-Object { [KakaoUi]::Cls($_) -eq 'Button' -and [KakaoUi]::GetDlgCtrlID($_) -eq 1 } | Select-Object -First 1
        if (-not $nameBox -or -not $saveBtn) { [void][KakaoUi]::PostMessage($dlg, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero); throw '저장 창 모양이 예상과 다름' }
        $fileName = [KakaoUi]::Text($nameBox)
        if ($fileName -notlike "KakaoTalk_*$room.txt") { [void][KakaoUi]::PostMessage($dlg, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero); throw "기본 파일 이름이 예상과 다름: $fileName" }
        $target = Join-Path $OutDir $fileName
        [void][KakaoUi]::SendMessage($nameBox, $WM_SETTEXT, [IntPtr]::Zero, $target)
        [void][KakaoUi]::SendMessage($saveBtn, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
        $saved = Wait-For { if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) { $true } } 10000
        # 저장이 끝나면 카톡이 '대화 내보내기 100% 완료' 창을 띄운다. Ctrl+S 뒤에 새로 생긴 카톡 창은 모두 닫는다
        $isNew = { [KakaoUi]::Tops($kpid, $true) | Where-Object { $_ -ne $chat -and $before -notcontains $_ } }
        [void](Wait-For { @(& $isNew | Where-Object { [KakaoUi]::Cls($_) -ne '#32770' }).Count -gt 0 } 3000)
        Start-Sleep -Milliseconds 300
        & $isNew | ForEach-Object { [void][KakaoUi]::PostMessage($_, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
        Start-Sleep -Milliseconds 300
        if ((($inputs | ForEach-Object { [KakaoUi]::Text($_) }) -join "`n") -ne $draft) { $opened = $false; throw '메시지 입력칸이 바뀜 (방 창을 열어 둔 채 멈춤)' }
        if (-not $saved) { throw '파일이 저장되지 않음' }
        $head = Get-Content -LiteralPath $target -TotalCount 1 -Encoding UTF8
        if ($head -notlike "$room*") { throw '저장한 파일의 첫 줄이 방 이름과 다름' }
        # 같은 방의 예전 자동 내보내기는 지운다 (방마다 가장 새 파일 하나)
        Get-ChildItem -LiteralPath $OutDir -Filter "KakaoTalk_*$room.txt" | Where-Object { $_.Name -ne $fileName } | Remove-Item -Force
        $result.rooms[$room] = 'ok'
    } catch {
        $result.rooms[$room] = "$($_.Exception.Message)"
        $result.status = 'partial'
        if ("$($_.Exception.Message)" -match '맨 앞|입력이 있어|입력칸') {
            if ($opened -and $chat) { [void][KakaoUi]::PostMessage($chat, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
            Finish 'partial' "$($_.Exception.Message)" 0
        }
    } finally {
        if ($opened -and $chat) { [void][KakaoUi]::PostMessage($chat, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
        Start-Sleep -Milliseconds 400
    }
}

$okCount = @($result.rooms.Values | Where-Object { $_ -eq 'ok' }).Count
if ($okCount -eq $Rooms.Count) { Finish 'ok' $null 0 }
if ($okCount -gt 0) { Finish 'partial' "$okCount/$($Rooms.Count)개 방만 저장" 0 }
Finish 'error' '저장한 방 없음' 1
