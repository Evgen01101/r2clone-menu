#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Remote = 'ydisk',
    [string]$LocalRoot = '',
    [switch]$NoGui,
    [switch]$DryRun,
    [switch]$Version
)

Set-StrictMode -Version 2.0

$script:NoGuiMode = [bool]$NoGui
$script:DryRunMode = [bool]$DryRun

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch { Write-Verbose ('Не удалось переключить кодировку консоли: ' + $_.Exception.Message) }

$script:BaseDir = $PSScriptRoot
if (-not $script:BaseDir) { $script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigPath = Join-Path $script:BaseDir 'R2clone_menu.config.json'
$script:OverrideRoot = ''
if ($LocalRoot) { $script:OverrideRoot = $LocalRoot.TrimEnd('\') }
$script:Roots = @{}
$script:CurrentPath = ''
$script:Items = @()
$script:ItemsPath = $null
$script:RemoteType = ''
$script:AppVersion = '1.2.1'

if ($Version) {
    Write-Host ('R2clone menu ' + $script:AppVersion)
    Write-Host ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        Write-Host ('rclone   ' + (& rclone version 2>$null | Select-Object -First 1))
    } else {
        Write-Host 'rclone   не найден в PATH'
    }
    return
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return ('{0:N0} Б' -f $Bytes)
}

function Get-DefaultLocalRoot {
    param([string]$Name)
    return (Join-Path (Join-Path $script:BaseDir 'disks') $Name)
}

function Get-LocalRoot {
    if ($script:OverrideRoot) { return $script:OverrideRoot }
    if ($script:Roots.ContainsKey($Remote)) { return $script:Roots[$Remote] }
    return (Get-DefaultLocalRoot $Remote)
}

function Get-RootSource {
    if ($script:OverrideRoot) { return 'параметр -LocalRoot' }
    if ($script:Roots.ContainsKey($Remote)) { return 'файл настроек' }
    return ('по умолчанию: disks\' + $Remote)
}

function Get-LogFile {
    $root = Get-LocalRoot
    return (Join-Path (Split-Path -Parent $root) 'rclone-copy.log')
}

function Import-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return }
        $conf = $raw | ConvertFrom-Json
        if ($conf.roots) {
            foreach ($p in $conf.roots.PSObject.Properties) {
                if ($p.Value) { $script:Roots[$p.Name] = [string]$p.Value }
            }
        }
    } catch {
        Write-Host ('Настройки не прочитаны: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Save-Config {
    $roots = [ordered]@{}
    foreach ($k in ($script:Roots.Keys | Sort-Object)) { $roots[$k] = $script:Roots[$k] }
    $conf = [pscustomobject]@{ roots = $roots }
    $json = $conf | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding($true)))
}

function Ensure-LocalRoot {
    $root = Get-LocalRoot
    if (-not (Test-Path -LiteralPath $root)) {
        $answer = Read-Host ('Папки нет: ' + $root + '. Создать? (y/N)')
        if ($answer -ne 'y') { return $false }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $true
}

function Test-Rclone {
    if (Get-Command rclone -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'rclone не найден в PATH. Установка: winget install Rclone.Rclone' -ForegroundColor Red
    return $false
}

function Test-Remote {
    $list = & rclone listremotes 2>$null
    foreach ($r in @($list)) {
        if ($r -eq ($Remote + ':')) { return $true }
    }
    return $false
}

function Get-RemotePath {
    param([string]$Child)
    $p = $script:CurrentPath
    if ($Child) {
        if ($p) { $p = "$p/$Child" } else { $p = $Child }
    }
    if ($p) { return ($Remote + ':' + $p) }
    return ($Remote + ':')
}

function Get-LocalPath {
    param([string]$Child)
    $rel = $script:CurrentPath -replace '/', '\'
    if ($Child) {
        if ($rel) { $rel = Join-Path $rel $Child } else { $rel = $Child }
    }
    if ($rel) { return (Join-Path (Get-LocalRoot) $rel) }
    return (Get-LocalRoot)
}


function Get-RemoteType {
    if ($script:RemoteType) { return $script:RemoteType }
    $raw = & rclone config show $Remote 2>$null
    $type = ''
    foreach ($line in @($raw)) {
        if ($line -match '^\s*type\s*=\s*(\S+)') { $type = $Matches[1]; break }
    }
    $script:RemoteType = $type
    return $type
}
function Show-Header {
    $disp = if ($script:CurrentPath) { '/' + $script:CurrentPath } else { '/' }
    Write-Host ''
    Write-Host ('=== R2clone menu ' + $script:AppVersion + ' · ' + $Remote + ' ===') -ForegroundColor Cyan
    if ($script:DryRunMode) { Write-Host 'Режим: --dry-run — на Диск ничего не записывается' -ForegroundColor Yellow }
    if ((Get-RemoteType) -eq 'yandex') { Write-Host 'Доступ к Диску: официальный API Яндекса (yandex.ru/dev/disk-api)' -ForegroundColor DarkGray }
    Write-Host ('Диск    : ' + $disp)
    Write-Host ('Локально: ' + (Get-LocalRoot) + '  [' + (Get-RootSource) + ']')
    Write-Host ('Журнал  : ' + (Get-LogFile))
}

function Reset-Items {
    $script:Items = @()
    $script:ItemsPath = $null
}

function Get-Items {
    param([switch]$Force)
    if (-not $Force -and $script:ItemsPath -eq $script:CurrentPath) { return $script:Items }
    $raw = & rclone lsjson (Get-RemotePath) --max-depth 1 --no-mimetype 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Не удалось получить список. Проверьте доступ: пункт 14.' -ForegroundColor Red
        Reset-Items
        return @()
    }
    $items = @()
    if ($raw) {
        $text = (@($raw) -join "`n")
        if ($text.Trim()) { $items = $text | ConvertFrom-Json }
    }
    $script:Items = @($items | Sort-Object @{ Expression = { -not $_.IsDir } }, Name)
    $script:ItemsPath = $script:CurrentPath
    return $script:Items
}

function Show-Listing {
    $items = Get-Items
    if (-not $items -or $items.Count -eq 0) { Write-Host 'Папка пуста или недоступна.'; return }
    Write-Host ''
    Write-Host ('{0,3}  {1,-6}  {2,10}  {3,-16}  {4}' -f '#', 'Тип', 'Размер', 'Изменён', 'Имя')
    $i = 0
    foreach ($it in $items) {
        $i++
        $type = if ($it.IsDir) { 'папка' } else { 'файл' }
        $size = if ($it.IsDir) { '' } else { Format-Size $it.Size }
        $time = ''
        try { $time = ([datetime]$it.ModTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $time = '' }
        Write-Host ('{0,3}  {1,-6}  {2,10}  {3,-16}  {4}' -f $i, $type, $size, $time, $it.Name)
    }
}

function Read-Line {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim()
}

function Select-Number {
    param([int]$Max, [string]$Prompt)
    $answer = Read-Line -Prompt $Prompt
    if (-not $answer) { return 0 }
    $idx = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$idx)) { Write-Host 'Нужен номер из списка.' -ForegroundColor Yellow; return 0 }
    if ($idx -lt 1 -or $idx -gt $Max) { Write-Host 'Нет такого номера.' -ForegroundColor Yellow; return 0 }
    return $idx
}

function Enter-Folder {
    $items = Get-Items
    if (-not $items -or $items.Count -eq 0) { Write-Host 'Список пуст.'; return }
    Show-Listing
    $idx = Select-Number -Max $script:Items.Count -Prompt 'Номер папки (Enter — отмена)'
    if ($idx -eq 0) { return }
    $it = $script:Items[$idx - 1]
    if (-not $it.IsDir) { Write-Host 'Это файл — скачать его можно пунктом 7.' -ForegroundColor Yellow; return }
    if ($script:CurrentPath) { $script:CurrentPath = "$($script:CurrentPath)/$($it.Name)" } else { $script:CurrentPath = $it.Name }
    Reset-Items
    Show-Listing
}

function Go-Up {
    if (-not $script:CurrentPath) { Write-Host 'Уже корень Диска.'; return }
    $parts = $script:CurrentPath -split '/'
    if ($parts.Count -gt 1) { $script:CurrentPath = ($parts[0..($parts.Count - 2)] -join '/') } else { $script:CurrentPath = '' }
    Reset-Items
    Show-Listing
}

function Show-Size {
    $info = Get-RemoteSizeInfo
    if (-not $info) { Write-Host 'Размер получить не удалось.' -ForegroundColor Red; return }
    Write-Host ('Файлов: {0}, объём: {1}' -f $info.Count, (Format-Size $info.Bytes))
}

function Show-Quota {
    $raw = & rclone about ($Remote + ':') --json 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host 'Квота недоступна для этого remote.' -ForegroundColor Yellow; return }
    $obj = @($raw) -join "`n" | ConvertFrom-Json
    Write-Host ('Диск: всего {0}, занято {1}, свободно {2}' -f (Format-Size $obj.total), (Format-Size $obj.used), (Format-Size $obj.free))
}

function Show-DiskSpace {
    $root = Get-LocalRoot
    $qualifier = Split-Path -Qualifier $root
    if (-not $qualifier) { return }
    $letter = $qualifier.TrimEnd(':')
    $drive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($drive) { Write-Host ('Свободно на {0}: {1}' -f $letter, (Format-Size $drive.Free)) }
}

function Get-FreeSpaceBytes {
    $qualifier = Split-Path -Qualifier (Get-LocalRoot)
    if (-not $qualifier) { return 0 }
    $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $drive) { return 0 }
    return [double]$drive.Free
}

function Get-RemoteSizeInfo {
    $raw = & rclone size (Get-RemotePath) --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $obj = (@($raw) -join "`n") | ConvertFrom-Json
    $count = 0
    $bytes = 0
    if ($obj.PSObject.Properties['count']) { $count = [double]$obj.count }
    if ($obj.PSObject.Properties['bytes']) { $bytes = [double]$obj.bytes }
    return [pscustomobject]@{ Count = $count; Bytes = $bytes }
}

function Get-CopyFlags {
    $flags = @('--transfers', '4', '--checkers', '8', '--retries', '5', '--low-level-retries', '10', '--stats', '10s', '--stats-one-line', '-P', '--log-file', (Get-LogFile), '--log-level', 'INFO')
    if ($script:DryRunMode) { $flags += '--dry-run' }
    return $flags
}

function Test-LocalPathProblem {
    param([string]$Path)
    if (-not $Path) { return 'путь не задан' }
    $trimmed = $Path.Trim()
    if ($trimmed.Length -gt 240) { return 'путь длиннее 240 символов — Windows может не справиться с вложенностью' }
    if ($trimmed -match '[<>"|?*]') { return 'в пути есть недопустимые для Windows символы: < > " | ? *' }
    $qualifier = ''
    try { $qualifier = Split-Path -Qualifier $trimmed -ErrorAction Stop } catch { $qualifier = '' }
    if (-not $qualifier) { return 'нужен полный путь, например D:\Папка' }
    if (-not (Test-Path -LiteralPath ($qualifier + '\'))) { return ('диск ' + $qualifier + ' недоступен') }
    return ''
}

function Start-Copy {
    param([switch]$Verify)
    if (-not (Ensure-LocalRoot)) { return }
    $src = Get-RemotePath
    $dst = Get-LocalPath
    $problem = Test-LocalPathProblem -Path $dst
    if ($problem) { Write-Host ('Путь назначения: ' + $problem) -ForegroundColor Red; return }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Show-DiskSpace
    $info = Get-RemoteSizeInfo
    if ($info) {
        Write-Host ('Файлов: {0}, объём: {1}' -f $info.Count, (Format-Size $info.Bytes))
        $free = Get-FreeSpaceBytes
        if ($free -gt 0 -and $info.Bytes -gt $free) {
            Write-Host ('Не хватает места: нужно ' + (Format-Size $info.Bytes) + ', свободно ' + (Format-Size $free)) -ForegroundColor Yellow
            if ((Read-Host 'Всё равно продолжить? (y/N)') -ne 'y') { return }
        }
    }
    $cliArgs = @('copy', $src, $dst) + (Get-CopyFlags)
    & rclone @cliArgs
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        if ($script:DryRunMode) { Write-Host 'Проверка завершена, файлы не копировались (--dry-run).' -ForegroundColor Yellow }
        else { Write-Host 'Готово.' -ForegroundColor Green }
    } else {
        Write-Host ('Завершено с ошибками (код {0}). Пункт 15 покажет журнал.' -f $code) -ForegroundColor Yellow
    }
    if ($Verify -and -not $script:DryRunMode) { Invoke-Check }
}

function Get-FileFromFolder {
    $items = Get-Items
    if (-not $items -or $items.Count -eq 0) { Write-Host 'Список пуст.'; return }
    Show-Listing
    $idx = Select-Number -Max $script:Items.Count -Prompt 'Номер файла (Enter — отмена)'
    if ($idx -eq 0) { return }
    $it = $script:Items[$idx - 1]
    if ($it.IsDir) { Write-Host 'Это папка — войдите в неё пунктом 2.' -ForegroundColor Yellow; return }
    if (-not (Ensure-LocalRoot)) { return }
    $dstDir = Get-LocalPath
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    $dstFile = Join-Path $dstDir $it.Name
    $problem = Test-LocalPathProblem -Path $dstFile
    if ($problem) { Write-Host ('Путь: ' + $problem) -ForegroundColor Red; return }
    $cliArgs = @('copyto', (Get-RemotePath $it.Name), $dstFile) + (Get-CopyFlags)
    & rclone @cliArgs
    if ($LASTEXITCODE -eq 0) {
        if ($script:DryRunMode) { Write-Host 'Проверка завершена, файл не скачивался (--dry-run).' -ForegroundColor Yellow }
        else { Write-Host ('Сохранено: ' + $dstFile) -ForegroundColor Green }
    } else { Write-Host 'Скачать не удалось, см. пункт 15.' -ForegroundColor Yellow }
}

function Invoke-Check {
    $src = Get-RemotePath
    $dst = Get-LocalPath
    if (-not (Test-Path -LiteralPath $dst)) { Write-Host ('Локальной копии ещё нет: ' + $dst) -ForegroundColor Yellow; return }
    & rclone check $src $dst --one-way --log-file (Get-LogFile) --log-level INFO
    if ($LASTEXITCODE -eq 0) { Write-Host 'Расхождений нет.' -ForegroundColor Green } else { Write-Host 'Есть расхождения или ошибки чтения.' -ForegroundColor Yellow }
}

function Show-PickFolder {
    if ($script:NoGuiMode) { return '' }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Выберите папку'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return ''
    } catch { return '' }
}

function Show-PickFile {
    if ($script:NoGuiMode) { return '' }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Выберите файл для загрузки'
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return ''
    } catch { return '' }
}

function Send-Folder {
    Write-Host 'Загрузка папки на Диск' -ForegroundColor Cyan
    Write-Host ('Куда: ' + (Get-RemotePath))
    $local = Show-PickFolder
    if (-not $local) { $local = (Read-Line -Prompt 'Путь к локальной папке (Enter — отмена)').Trim('"', ' ') }
    if (-not $local) { return }
    if (-not (Test-Path -LiteralPath $local -PathType Container)) { Write-Host 'Папка не найдена.' -ForegroundColor Red; return }
    $problem = Test-LocalPathProblem -Path $local
    if ($problem) { Write-Host ('Путь: ' + $problem) -ForegroundColor Red; return }
    $name = Split-Path -Leaf $local
    if (-not $name) { Write-Host 'Не удалось определить имя папки.' -ForegroundColor Red; return }
    $dst = Get-RemotePath $name
    $files = @(Get-ChildItem -LiteralPath $local -Recurse -File -ErrorAction SilentlyContinue)
    $sum = 0
    if ($files.Count -gt 0) { $sum = ($files | Measure-Object Length -Sum).Sum }
    Write-Host ('Источник: ' + $local)
    Write-Host ('На Диске: ' + $dst)
    Write-Host ('Файлов: {0}, объём: {1}' -f $files.Count, (Format-Size $sum))
    $question = if ($script:DryRunMode) { 'Прогнать проверку без записи (--dry-run)? (y/N)' } else { 'Загрузить? (y/N)' }
    if ((Read-Host $question) -ne 'y') { Write-Host 'Отменено.'; return }
    $cliArgs = @('copy', $local, $dst) + (Get-CopyFlags)
    & rclone @cliArgs
    if ($LASTEXITCODE -eq 0) {
        if ($script:DryRunMode) { Write-Host 'Проверка завершена, файлы не загружались (--dry-run).' -ForegroundColor Yellow }
        else { Write-Host 'Загружено.' -ForegroundColor Green }
    } else { Write-Host 'Завершено с ошибками, см. пункт 15.' -ForegroundColor Yellow }
    Reset-Items
}

function Send-OneFile {
    Write-Host 'Загрузка файла на Диск' -ForegroundColor Cyan
    Write-Host ('Куда: ' + (Get-RemotePath))
    $file = Show-PickFile
    if (-not $file) { $file = (Read-Line -Prompt 'Путь к файлу (Enter — отмена)').Trim('"', ' ') }
    if (-not $file) { return }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Host 'Файл не найден.' -ForegroundColor Red; return }
    $problem = Test-LocalPathProblem -Path $file
    if ($problem) { Write-Host ('Путь: ' + $problem) -ForegroundColor Red; return }
    $name = Split-Path -Leaf $file
    $dst = Get-RemotePath $name
    $info = Get-Item -LiteralPath $file
    Write-Host ('Источник: ' + $info.FullName)
    Write-Host ('На Диске: ' + $dst)
    Write-Host ('Размер  : ' + (Format-Size $info.Length))
    $question = if ($script:DryRunMode) { 'Прогнать проверку без записи (--dry-run)? (y/N)' } else { 'Загрузить? (y/N)' }
    if ((Read-Host $question) -ne 'y') { Write-Host 'Отменено.'; return }
    $cliArgs = @('copyto', $file, $dst) + (Get-CopyFlags)
    & rclone @cliArgs
    if ($LASTEXITCODE -eq 0) {
        if ($script:DryRunMode) { Write-Host 'Проверка завершена, файл не загружался (--dry-run).' -ForegroundColor Yellow }
        else { Write-Host 'Загружено.' -ForegroundColor Green }
    } else { Write-Host 'Загрузить не удалось, см. пункт 15.' -ForegroundColor Yellow }
    Reset-Items
}

function Set-LocalFolder {
    $current = Get-LocalRoot
    Write-Host ''
    Write-Host ('Remote          : ' + $Remote)
    Write-Host ('Локальная папка : ' + $current)
    Write-Host ('Источник        : ' + (Get-RootSource))
    Write-Host ('Папка по умолчанию: ' + (Get-DefaultLocalRoot $Remote))
    Write-Host ''
    Write-Host ' 1. Выбрать через диалог'
    Write-Host ' 2. Ввести путь вручную'
    Write-Host ' 3. Вернуть папку по умолчанию (disks\<remote>)'
    Write-Host ' 0. Отмена'
    $choice = Read-Line -Prompt 'Выбор'
    if ($choice -eq '1' -or $choice -eq '2') {
        if ($choice -eq '1') { $path = Show-PickFolder } else { $path = (Read-Line -Prompt 'Путь').Trim('"', ' ') }
        if (-not $path) { Write-Host 'Путь не задан.'; return }
        $path = $path.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $path)) {
            if ((Read-Host ('Папки нет: ' + $path + '. Создать? (y/N)')) -ne 'y') { return }
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        $script:Roots[$Remote] = $path
        Save-Config
        Write-Host ('Сохранено: ' + $path) -ForegroundColor Green
        return
    }
    if ($choice -eq '3') {
        if ($script:Roots.ContainsKey($Remote)) { $script:Roots.Remove($Remote) }
        Save-Config
        Write-Host ('Используется папка по умолчанию: ' + (Get-DefaultLocalRoot $Remote)) -ForegroundColor Green
        return
    }
    Write-Host 'Отменено.'
}

function Test-Access {
    $raw = & rclone lsd ($Remote + ':') --max-depth 1 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ('Доступ есть, папок в корне: {0}' -f @($raw).Count) -ForegroundColor Green
    } else {
        Write-Host ('Ошибка доступа: ' + (@($raw) -join ' ')) -ForegroundColor Red
    }
}

function Show-LogErrors {
    $log = Get-LogFile
    if (-not (Test-Path -LiteralPath $log)) { Write-Host ('Журнала ещё нет: ' + $log); return }
    $all = @(Select-String -LiteralPath $log -Pattern ' ERROR ')
    if ($all.Count -eq 0) { Write-Host 'Ошибок в журнале нет.' -ForegroundColor Green; return }
    $all | Select-Object -Last 30 | ForEach-Object { Write-Host $_.Line }
    Write-Host ('Всего строк с ошибками: {0}' -f $all.Count) -ForegroundColor Yellow
}

function Open-Log {
    $log = Get-LogFile
    $dir = Split-Path -Parent $log
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $log)) { New-Item -ItemType File -Path $log -Force | Out-Null }
    Start-Process notepad.exe -ArgumentList ('"' + $log + '"')
}

function Open-LocalFolder {
    if (-not (Ensure-LocalRoot)) { return }
    $dst = Get-LocalPath
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"' + $dst + '"')
}

function Set-Credentials {
    Write-Host 'Нужны ClientID и Client secret вашего приложения (oauth.yandex.ru/client/new).' -ForegroundColor Cyan
    Write-Host 'Значения видны при вводе — не оставляйте их на экране при записи.' -ForegroundColor DarkGray
    $clientId = Read-Line -Prompt 'ClientID'
    $clientSecret = Read-Line -Prompt 'Client secret'
    if (-not $clientId -or -not $clientSecret) { Write-Host 'Нужны оба значения, изменений нет.' -ForegroundColor Yellow; return }
    $confirm = Read-Host ('Пересоздать remote "' + $Remote + '" и авторизоваться в браузере? (y/N)')
    if ($confirm -ne 'y') { Write-Host 'Отменено.'; return }
    & rclone config delete $Remote 2>$null
    & rclone config create $Remote yandex client_id $clientId client_secret $clientSecret config_is_local=true
    if ($LASTEXITCODE -ne 0) { Write-Host 'Создать remote не удалось.' -ForegroundColor Red; return }
    $script:RemoteType = ''
    Test-Access
    Reset-Items
}

function Show-Help {
    Write-Host ''
    Write-Host 'Шпаргалка rclone' -ForegroundColor Cyan
    Write-Host '  rclone lsd ydisk:                        — папки в корне'
    Write-Host '  rclone lsf ydisk: --max-depth 1          — содержимое одной папки'
    Write-Host '  rclone lsjson ydisk: --max-depth 1       — то же в JSON'
    Write-Host '  rclone size "ydisk:Папка" --json         — размер и число файлов'
    Write-Host '  rclone about ydisk: --json               — квота Диска'
    Write-Host '  rclone copy "ydisk:Папка" "<папка дисков>" -P   — скачать папку'
    Write-Host '  rclone copy "<папка дисков>\Папка" "ydisk:Куда" -P   — загрузить папку'
    Write-Host '  rclone copyto "<папка дисков>\файл" "ydisk:Куда\файл" — загрузить один файл'
    Write-Host '  rclone sync "ydisk:Папка" "<папка дисков>" -P   — зеркало, УДАЛЯЕТ лишнее локально'
    Write-Host '  rclone check "ydisk:Папка" "<папка дисков>" --one-way — сверка'
    Write-Host '  rclone listremotes                       — список remote'
    Write-Host '  rclone config show ydisk                 — настройки remote'
    Write-Host '  rclone config delete ydisk               — удалить remote'
    Write-Host '  rclone selfupdate                        — обновить rclone'
    Write-Host ''
    Write-Host 'Полезные флаги: --transfers N --checkers N --tpslimit N --dry-run --exclude "*.tmp" --max-age 7d'
}

function Show-Menu {
    $left = @(
        ' 1. Список: папки и файлы',
        ' 2. Войти в папку (по номеру)',
        ' 3. На уровень выше',
        ' 4. В корень Диска',
        ' 5. Размер текущей папки',
        ' 6. Скачать текущую папку',
        ' 7. Скачать один файл',
        ' 8. Скачать + проверить (copy+check)',
        ' 9. Проверить локальную копию (check)',
        '10. Загрузить папку на Диск'
    )
    $right = @(
        '11. Загрузить файл на Диск',
        '12. Локальная папка для Диска',
        '13. Место на диске и квота',
        '14. Диагностика доступа',
        '15. Ошибки из журнала',
        '16. Открыть журнал',
        '17. Открыть локальную папку',
        '18. ClientID и Client secret',
        '19. Шпаргалка по rclone',
        ' 0. Выход'
    )
    Write-Host ''
    for ($i = 0; $i -lt $left.Count; $i++) {
        Write-Host ($left[$i].PadRight(42) + $right[$i])
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not (Test-Rclone)) { return }

Import-Config
Set-Location -LiteralPath $script:BaseDir

if (-not (Test-Remote)) {
    Write-Host ('Remote "' + $Remote + '" не найден. Выполните пункт 18 меню.') -ForegroundColor Yellow
} else {
    Test-Access
}

while ($true) {
    Show-Header
    Show-Menu
    $choice = Read-Line -Prompt 'Выбор'
    switch ($choice) {
        '1' { Show-Listing }
        '2' { Enter-Folder }
        '3' { Go-Up }
        '4' { $script:CurrentPath = ''; Reset-Items; Show-Listing }
        '5' { Show-Size }
        '6' { Start-Copy }
        '7' { Get-FileFromFolder }
        '8' { Start-Copy -Verify }
        '9' { Invoke-Check }
        '10' { Send-Folder }
        '11' { Send-OneFile }
        '12' { Set-LocalFolder }
        '13' { Show-DiskSpace; Show-Quota }
        '14' { Test-Access }
        '15' { Show-LogErrors }
        '16' { Open-Log }
        '17' { Open-LocalFolder }
        '18' { Set-Credentials }
        '19' { Show-Help }
        '0' { return }
        'q' { return }
        default { Write-Host 'Нет такого пункта.' -ForegroundColor Yellow }
    }
}
