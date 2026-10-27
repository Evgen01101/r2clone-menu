#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Remote = 'ydisk',
    [string]$LocalRoot = '',
    [string]$Type = '',
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
$script:Config = @{
    schemaVersion = 2
    paths         = @{ dataRoot = 'portable' }
    default       = ''
    remotes       = @{}
}
$script:CurrentPath = ''
$script:Items = @()
$script:ItemsPath = $null
$script:RemoteType = ''
$script:ProviderOverrides = @{}
$script:DangerousFlags = @(
    '--config'
    '--password-command'
    '--rc'
    '--rc-addr'
    '--rc-no-auth'
    '--daemon'
    '--backup-dir'
    '--copy-dest'
    '--compare-dest'
    '--files-from'
    '--log-file'
)
$script:AppVersion = '1.3.0'

$script:Providers = @{
    yandex = @{
        type              = 'yandex'
        label             = 'Яндекс.Диск'
        requiresApp       = $true
        optionalApp       = $false
        authHint          = 'https://oauth.yandex.ru/client/new/'
        docsUrl           = 'https://yandex.ru/dev/disk-api/'
        fields            = @(
            @{ name = 'client_id'; label = 'ClientID'; secret = $false; required = $true; hint = 'Из настроек OAuth-приложения' }
            @{ name = 'client_secret'; label = 'Client secret'; secret = $true; required = $true; hint = 'Секрет клиента или пароль приложения' }
        )
        supportsAbout     = $true
        hasHashes         = $true
        attribution       = 'Доступ к Диску: официальный API Яндекса'
        notes             = @('Своё OAuth-приложение обязательно: встроенное приложение rclone блокируется (410)')
        allowedConfigKeys = @()
        allowedFlags      = @('--tpslimit', '--exclude', '--include', '--max-age', '--size-only')
        experimental      = $false
        interactiveOnly   = $false
    }
    drive = @{
        type              = 'drive'
        label             = 'Google Drive'
        requiresApp       = $false
        optionalApp       = $true
        authHint          = 'https://rclone.org/drive/'
        docsUrl           = 'https://rclone.org/drive/'
        fields            = @(
            @{ name = 'client_id'; label = 'ClientID (необязательно)'; secret = $false; required = $false; hint = 'Свой клиент — для интенсивного использования' }
            @{ name = 'client_secret'; label = 'Client secret (необязательно)'; secret = $true; required = $false }
        )
        supportsAbout     = $true
        hasHashes         = $true
        attribution       = $null
        notes             = @('Google Docs/Sheets/Slides экспортируются в docx/xlsx/pptx', 'Общие диски: флаги --drive-*', 'Свой client_id нужен при интенсивном использовании')
        allowedConfigKeys = @('team_drive', 'root_folder_id', 'chunk_size')
        allowedFlags      = @('--drive-*', '--tpslimit', '--exclude', '--include', '--max-age')
        experimental      = $false
        interactiveOnly   = $false
    }
    onedrive = @{
        type              = 'onedrive'
        label             = 'OneDrive'
        requiresApp       = $false
        optionalApp       = $true
        authHint          = 'https://rclone.org/onedrive/'
        docsUrl           = 'https://rclone.org/onedrive/'
        fields            = @(
            @{ name = 'client_id'; label = 'ClientID (необязательно)'; secret = $false; required = $false }
            @{ name = 'client_secret'; label = 'Client secret (необязательно)'; secret = $true; required = $false }
        )
        supportsAbout     = $true
        hasHashes         = $true
        attribution       = $null
        notes             = @('Корпоративные аккаунты могут блокировать сторонние приложения политикой тенанта')
        allowedConfigKeys = @('drive_id', 'drive_type')
        allowedFlags      = @('--onedrive-*', '--tpslimit', '--exclude', '--include', '--max-age')
        experimental      = $false
        interactiveOnly   = $false
    }
    s3 = @{
        type              = 's3'
        label             = 'S3-совместимое'
        requiresApp       = $false
        optionalApp       = $false
        authHint          = 'https://rclone.org/s3/'
        docsUrl           = 'https://rclone.org/s3/'
        fields            = @(
            @{ name = 'provider'; label = 'Провайдер'; secret = $false; required = $true; choices = @('AWS', 'Minio', 'Other') }
            @{ name = 'access_key_id'; label = 'Access key ID'; secret = $false; required = $true }
            @{ name = 'secret_access_key'; label = 'Secret access key'; secret = $true; required = $true }
            @{ name = 'region'; label = 'Регион'; secret = $false; required = $false }
            @{ name = 'endpoint'; label = 'Endpoint'; secret = $false; required = $false; hint = 'Для MinIO и совместимых хранилищ' }
        )
        supportsAbout     = $false
        hasHashes         = $false
        attribution       = $null
        notes             = @('Сверка возможна только по размеру: у S3 нет хэшей', 'Bucket входит в путь: remote:bucket/папка')
        allowedConfigKeys = @('endpoint', 'region', 'chunk_size')
        allowedFlags      = @('--s3-*', '--tpslimit', '--exclude', '--include', '--max-age')
        experimental      = $true
        interactiveOnly   = $false
    }
    dropbox = @{
        type              = 'dropbox'
        label             = 'Dropbox'
        requiresApp       = $false
        optionalApp       = $true
        authHint          = 'https://rclone.org/dropbox/'
        docsUrl           = 'https://rclone.org/dropbox/'
        fields            = @(
            @{ name = 'client_id'; label = 'ClientID (необязательно)'; secret = $false; required = $false }
            @{ name = 'client_secret'; label = 'Client secret (необязательно)'; secret = $true; required = $false }
        )
        supportsAbout     = $true
        hasHashes         = $true
        attribution       = $null
        notes             = @('Лимиты запросов строже, чем у Яндекса: держите --tpslimit')
        allowedConfigKeys = @()
        allowedFlags      = @('--tpslimit', '--exclude', '--include', '--max-age')
        experimental      = $true
        interactiveOnly   = $false
    }
}

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

function Get-DataRoot {
    $mode = 'portable'
    if ($script:Config.paths -and $script:Config.paths.dataRoot) { $mode = [string]$script:Config.paths.dataRoot }
    if ($mode -eq 'user') {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = $env:USERPROFILE }
        return (Join-Path (Join-Path $base 'R2clone_menu') 'data')
    }
    return (Join-Path $script:BaseDir 'data')
}

function New-RemoteEntry {
    param([string]$Name)
    return @{
        name           = $Name
        type           = ''
        label          = ''
        localRoot      = ''
        lastPath       = ''
        backendOptions = @{}
        extraFlags     = @()
        createdAt      = (Get-Date).ToString('o')
        lastUsedAt     = ''
    }
}

function Get-RemoteEntry {
    param([string]$Name)
    if (-not $Name) { return $null }
    if ($script:Config.remotes.ContainsKey($Name)) { return $script:Config.remotes[$Name] }
    return $null
}

function Resolve-LocalRoot {
    param([string]$Name)
    if ($script:OverrideRoot) { return $script:OverrideRoot }
    $entry = Get-RemoteEntry $Name
    if ($entry -and $entry.localRoot) {
        $value = [string]$entry.localRoot
        if ($value -match '^[A-Za-z]:') { return $value.TrimEnd('\') }
        return ((Join-Path (Get-DataRoot) $value).TrimEnd('\'))
    }
    $type = ''
    if ($entry -and $entry.type) { $type = [string]$entry.type }
    if (-not $type) { $type = Get-RemoteType -Name $Name }
    if (-not $type) { $type = 'unknown' }
    return (Join-Path (Join-Path (Get-DataRoot) $type) $Name)
}

function Get-DefaultLocalRoot {
    param([string]$Name)
    $type = ''
    $entry = Get-RemoteEntry $Name
    if ($entry -and $entry.type) { $type = [string]$entry.type }
    if (-not $type) { $type = Get-RemoteType -Name $Name }
    if (-not $type) { $type = 'unknown' }
    return (Join-Path (Join-Path (Get-DataRoot) $type) $Name)
}

function Get-LocalRoot {
    return (Resolve-LocalRoot $Remote)
}

function Get-RootSource {
    if ($script:OverrideRoot) { return 'параметр -LocalRoot' }
    $entry = Get-RemoteEntry $Remote
    if ($entry -and $entry.localRoot) { return 'файл настроек' }
    return 'по умолчанию: <корень данных>\<type>\<remote>'
}

function Get-LogFile {
    $root = Get-LocalRoot
    return (Join-Path (Split-Path -Parent $root) 'rclone-copy.log')
}

function ConvertTo-RemoteEntry {
    param($Value, [string]$Name)
    $entry = New-RemoteEntry $Name
    if ($Value) {
        foreach ($prop in $Value.PSObject.Properties) {
            switch ($prop.Name) {
                'backendOptions' {
                    $map = @{}
                    if ($prop.Value) {
                        foreach ($k in $prop.Value.PSObject.Properties) { $map[$k.Name] = [string]$k.Value }
                    }
                    $entry.backendOptions = $map
                }
                'extraFlags' {
                    $list = @()
                    foreach ($item in @($prop.Value)) {
                        $one = @{ flag = ''; value = '' }
                        if ($item) {
                            foreach ($fp in $item.PSObject.Properties) { $one[$fp.Name] = [string]$fp.Value }
                        }
                        if ($one.flag) { $list += $one }
                    }
                    $entry.extraFlags = $list
                }
                default { $entry[$prop.Name] = $prop.Value }
            }
        }
    }
    return $entry
}

function Import-Config {
    param([string]$Path = '')
    if (-not $Path) { $Path = $script:ConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return }
        $conf = $raw | ConvertFrom-Json
        $version = 1
        if ($conf.PSObject.Properties['schemaVersion'] -and $conf.schemaVersion) { $version = [int]$conf.schemaVersion }
        if ($version -ge 2) {
            if ($conf.PSObject.Properties['paths'] -and $conf.paths -and $conf.paths.dataRoot) {
                $script:Config.paths.dataRoot = [string]$conf.paths.dataRoot
            }
            if ($conf.PSObject.Properties['default'] -and $conf.default) { $script:Config.default = [string]$conf.default }
            if ($conf.PSObject.Properties['remotes'] -and $conf.remotes) {
                foreach ($p in $conf.remotes.PSObject.Properties) {
                    $script:Config.remotes[$p.Name] = ConvertTo-RemoteEntry -Value $p.Value -Name $p.Name
                }
            }
        } elseif ($conf.PSObject.Properties['roots'] -and $conf.roots) {
            foreach ($p in $conf.roots.PSObject.Properties) {
                if ($p.Value) {
                    $entry = New-RemoteEntry $p.Name
                    $entry.localRoot = [string]$p.Value
                    $script:Config.remotes[$p.Name] = $entry
                }
            }
            if (-not $script:Config.default -and $script:Config.remotes.ContainsKey($Remote)) { $script:Config.default = $Remote }
        }
    } catch {
        Write-Host ('Настройки не прочитаны: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Save-Config {
    param([string]$Path = '')
    if (-not $Path) { $Path = $script:ConfigPath }
    $remotes = [ordered]@{}
    foreach ($name in ($script:Config.remotes.Keys | Sort-Object)) {
        $e = $script:Config.remotes[$name]
        $flags = @()
        foreach ($f in @($e.extraFlags)) { $flags += [ordered]@{ flag = $f.flag; value = $f.value } }
        $opts = [ordered]@{}
        foreach ($k in ($e.backendOptions.Keys | Sort-Object)) { $opts[$k] = $e.backendOptions[$k] }
        $remotes[$name] = [ordered]@{
            type           = $e.type
            label          = $e.label
            localRoot      = $e.localRoot
            lastPath       = $e.lastPath
            backendOptions = $opts
            extraFlags     = $flags
            createdAt      = $e.createdAt
            lastUsedAt     = $e.lastUsedAt
        }
    }
    $conf = [ordered]@{
        schemaVersion = 2
        paths         = [ordered]@{ dataRoot = $script:Config.paths.dataRoot }
        default       = $script:Config.default
        remotes       = $remotes
    }
    $json = $conf | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($true)))
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


function New-DefaultProviderProfile {
    param([string]$Type)
    return @{
        type              = $Type
        label             = $Type
        requiresApp       = $false
        optionalApp       = $false
        authHint          = $null
        docsUrl           = $null
        fields            = @()
        supportsAbout     = $true
        hasHashes         = $false
        attribution       = $null
        notes             = @()
        allowedConfigKeys = @()
        allowedFlags      = @('--tpslimit', '--exclude', '--include', '--max-age', '--size-only')
        experimental      = $true
        interactiveOnly   = $true
    }
}

function Get-CatalogEntry {
    param([string]$Type)
    if (-not $Type) { return $null }
    if ($script:ProviderOverrides.ContainsKey($Type)) { return $script:ProviderOverrides[$Type] }
    if ($script:Providers.ContainsKey($Type)) { return $script:Providers[$Type] }
    return $null
}

function Get-Setting {
    param($Map, [string]$Name, $Default = $null)
    if ($null -eq $Map) { return $Default }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Name)) { return $Map[$Name] }
        return $Default
    }
    $prop = $Map.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Read-FieldSettings {
    param($Field)
    $rawChoices = Get-Setting -Map $Field -Name 'choices'
    $choices = @()
    if ($rawChoices) { $choices = @($rawChoices) }
    return @{
        name     = [string](Get-Setting -Map $Field -Name 'name')
        label    = [string](Get-Setting -Map $Field -Name 'label')
        hint     = [string](Get-Setting -Map $Field -Name 'hint')
        choices  = $choices
        secret   = [bool](Get-Setting -Map $Field -Name 'secret' -Default $false)
        default  = [string](Get-Setting -Map $Field -Name 'default')
        required = [bool](Get-Setting -Map $Field -Name 'required' -Default $false)
    }
}

function Get-ProviderProfile {
    param([string]$Type)
    $providerProfile = New-DefaultProviderProfile $Type
    $entry = Get-CatalogEntry $Type
    if ($entry) {
        foreach ($key in $entry.Keys) { $providerProfile[$key] = $entry[$key] }
    }
    if (-not $providerProfile.label) {
        if ($Type) { $providerProfile.label = $Type } else { $providerProfile.label = 'облако' }
    }
    return $providerProfile
}

function Import-Providers {
    param([string]$Path = '')
    if (-not $Path) { $Path = Join-Path $script:BaseDir 'R2clone_menu.providers.json' }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return }
        $obj = $raw | ConvertFrom-Json
        if (-not $obj.PSObject.Properties['providers']) { return }
        foreach ($prop in $obj.providers.PSObject.Properties) {
            $entry = @{}
            foreach ($field in $prop.Value.PSObject.Properties) {
                if ($field.Name -eq 'fields') {
                    $list = @()
                    foreach ($item in @($field.Value)) {
                        $one = @{}
                        foreach ($fp in $item.PSObject.Properties) { $one[$fp.Name] = $fp.Value }
                        $list += $one
                    }
                    $entry['fields'] = $list
                } elseif ($field.Value -is [System.Object[]]) {
                    $entry[$field.Name] = @($field.Value)
                } else {
                    $entry[$field.Name] = $field.Value
                }
            }
            if (-not $entry.ContainsKey('type')) { $entry['type'] = $prop.Name }
            $script:ProviderOverrides[$prop.Name] = $entry
        }
    } catch {
        Write-Host ('Каталог провайдеров не прочитан: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Get-RemoteType {
    param([string]$Name = '')
    $target = $Name
    if (-not $target) { $target = $Remote }
    if (-not $Name -and $script:RemoteType) { return $script:RemoteType }
    $raw = & rclone config show $target 2>$null
    $type = ''
    foreach ($line in @($raw)) {
        if ($line -match '^\s*type\s*=\s*(\S+)') { $type = $Matches[1]; break }
    }
    if (-not $Name) { $script:RemoteType = $type }
    return $type
}
function Show-Header {
    $disp = if ($script:CurrentPath) { '/' + $script:CurrentPath } else { '/' }
    $type = Get-RemoteType
    $providerProfile = Get-ProviderProfile $type
    $title = '=== R2clone menu ' + $script:AppVersion + ' · ' + $Remote
    if ($providerProfile.label -and $providerProfile.label -ne $Remote) { $title += ' (' + $providerProfile.label + ')' }
    Write-Host ''
    Write-Host ($title + ' ===') -ForegroundColor Cyan
    if ($script:DryRunMode) { Write-Host 'Режим: --dry-run — на Диск ничего не записывается' -ForegroundColor Yellow }
    if ($providerProfile.attribution) {
        $line = [string]$providerProfile.attribution
        if ($providerProfile.docsUrl) { $line += ' (' + $providerProfile.docsUrl + ')' }
        Write-Host $line -ForegroundColor DarkGray
    }
    Write-Host ('Диск    : ' + $disp)
    Write-Host ('Локально: ' + (Get-LocalRoot) + '  [' + (Get-RootSource) + ']')
    $entry = Get-RemoteEntry $Remote
    if ($entry -and @($entry.extraFlags).Count -gt 0) {
        $flagText = (@($entry.extraFlags) | ForEach-Object { ([string]$_.flag) + ' ' + ([string]$_.value) }) -join ', '
        Write-Host ('Флаги   : ' + $flagText.Trim()) -ForegroundColor DarkGray
    }
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
    $entry = Get-RemoteEntry $Remote
    if ($entry) {
        foreach ($extra in @($entry.extraFlags)) {
            $flag = [string]$extra.flag
            if (-not $flag) { continue }
            $flags += $flag
            if ($extra.value) { $flags += [string]$extra.value }
        }
    }
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

function ConvertTo-StoredLocalRoot {
    param([string]$Path)
    if (-not $Path) { return '' }
    $value = $Path.TrimEnd('\')
    $root = (Get-DataRoot).TrimEnd('\')
    if ($value.Length -gt $root.Length -and $value.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $value.Substring($root.Length + 1)
    }
    return $value
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
    Write-Host ' 3. Вернуть папку по умолчанию (<корень данных>\<type>\<remote>)'
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
        $stored = ConvertTo-StoredLocalRoot $path
        $entry = Get-RemoteEntry $Remote
        if (-not $entry) { $entry = New-RemoteEntry $Remote; $script:Config.remotes[$Remote] = $entry }
        $entry.localRoot = $stored
        Save-Config
        Write-Host ('Сохранено: ' + $path) -ForegroundColor Green
        return
    }
    if ($choice -eq '3') {
        $entry = Get-RemoteEntry $Remote
        if ($entry) { $entry.localRoot = '' }
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
    param([string]$Type = '')
    $remoteType = $Type
    if (-not $remoteType) { $remoteType = Get-RemoteType }
    if (-not $remoteType) { $remoteType = 'yandex' }
    $providerProfile = Get-ProviderProfile $remoteType

    Write-Host ''
    Write-Host ('Хранилище : ' + $Remote) -ForegroundColor Cyan
    Write-Host ('Тип       : ' + $remoteType + ' (' + $providerProfile.label + ')')
    if ($providerProfile.experimental) { Write-Host 'Профиль не проверен: настройки могут потребовать уточнения' -ForegroundColor Yellow }
    if ($providerProfile.authHint) { Write-Host ('Ключи и приложение: ' + $providerProfile.authHint) -ForegroundColor DarkGray }
    foreach ($note in @($providerProfile.notes)) { if ($note) { Write-Host ('  - ' + $note) -ForegroundColor DarkGray } }

    if ($providerProfile.interactiveOnly) {
        Write-Host 'Для этого типа доступ настраивается в мастере rclone config.' -ForegroundColor Yellow
        & rclone config
        $script:RemoteType = ''
        Test-Access
        Reset-Items
        return
    }

    $values = @{}
    $hasSecret = $false
    foreach ($field in @($providerProfile.fields)) {
        $info = Read-FieldSettings -Field $field
        $fieldName = $info.name
        $fieldLabel = $info.label
        if (-not $fieldLabel) { $fieldLabel = $fieldName }
        if ($info.hint) { Write-Host ('  ' + $info.hint) -ForegroundColor DarkGray }
        if ($info.choices.Count -gt 0) { Write-Host ('  варианты: ' + ($info.choices -join ', ')) -ForegroundColor DarkGray }
        if ($info.secret) { $hasSecret = $true }
        $value = ''
        do {
            $value = Read-Line -Prompt $fieldLabel
            if (-not $value -and $info.default) { $value = $info.default }
            if ($value -and $info.choices.Count -gt 0 -and ($info.choices -notcontains $value)) {
                Write-Host ('  допустимые значения: ' + ($info.choices -join ', ')) -ForegroundColor Yellow
                $value = ''
            }
            if (-not $value -and $info.required) { Write-Host '  значение обязательно' -ForegroundColor Yellow }
        } while (-not $value -and $info.required)
        if ($value) { $values[$fieldName] = $value }
    }
    if ($hasSecret) { Write-Host 'Секреты вводятся видимым текстом — не оставляйте их на экране.' -ForegroundColor DarkGray }

    $confirm = Read-Line -Prompt ('Пересоздать remote "' + $Remote + '" и авторизоваться в браузере? (y/N)')
    if ($confirm -ne 'y') { Write-Host 'Отменено.'; return }

    & rclone config delete $Remote 2>$null
    $cliArgs = @('config', 'create', $Remote, $remoteType)
    foreach ($field in @($providerProfile.fields)) {
        $key = [string](Get-Setting -Map $field -Name 'name')
        if ($key -and $values.ContainsKey($key) -and $values[$key]) { $cliArgs += $key; $cliArgs += $values[$key] }
    }
    $cliArgs += 'config_is_local=true'
    & rclone @cliArgs
    if ($LASTEXITCODE -ne 0) { Write-Host 'Создать remote не удалось.' -ForegroundColor Red; return }
    $script:RemoteType = ''
    Test-Access
    Reset-Items
}

function Show-Help {
    Write-Host ''
    Write-Host 'Шпаргалка rclone' -ForegroundColor Cyan
    Write-Host ("  rclone lsd {0}:                        — папки в корне" -f $Remote)
    Write-Host ("  rclone lsf {0}: --max-depth 1          — содержимое одной папки" -f $Remote)
    Write-Host ("  rclone lsjson {0}: --max-depth 1       — то же в JSON" -f $Remote)
    Write-Host ("  rclone size `"{0}:Папка`" --json         — размер и число файлов" -f $Remote)
    Write-Host ("  rclone about {0}: --json               — квота хранилища" -f $Remote)
    Write-Host ("  rclone copy `"{0}:Папка`" `"<папка дисков>`" -P   — скачать папку" -f $Remote)
    Write-Host ("  rclone copy `"<папка дисков>\Папка`" `"{0}:Куда`" -P   — загрузить папку" -f $Remote)
    Write-Host ("  rclone copyto `"<папка дисков>\файл`" `"{0}:Куда\файл`" — загрузить один файл" -f $Remote)
    Write-Host ("  rclone sync `"{0}:Папка`" `"<папка дисков>`" -P   — зеркало, УДАЛЯЕТ лишнее локально" -f $Remote)
    Write-Host ("  rclone check `"{0}:Папка`" `"<папка дисков>`" --one-way — сверка" -f $Remote)
    Write-Host '  rclone listremotes                       — список remote'
    Write-Host ("  rclone config show {0}                 — настройки remote" -f $Remote)
    Write-Host ("  rclone config delete {0}               — удалить remote" -f $Remote)
    Write-Host '  rclone selfupdate                        — обновить rclone'
    Write-Host ''
    Write-Host 'Полезные флаги: --transfers N --checkers N --tpslimit N --dry-run --exclude "*.tmp" --max-age 7d'
    Write-Host 'Лимит API: не более 40 запросов в секунду (п. 2.2) — --transfers/--checkers до 8, при 429/509 добавьте --tpslimit 5.' -ForegroundColor DarkGray
}

function Test-FlagAllowed {
    param([string]$Flag, $ProviderProfile)
    if (-not $Flag) { return 'флаг не задан' }
    if (-not $Flag.StartsWith('--')) { return 'флаг должен начинаться с двух дефисов' }
    $lower = $Flag.ToLower()
    if (@($script:DangerousFlags) -contains $lower) {
        return ('флаг ' + $Flag + ' запрещён: меняет конфиг, поднимает сервер или пишет вне целевой папки')
    }
    foreach ($pattern in @($ProviderProfile.allowedFlags)) {
        $item = ([string]$pattern).ToLower()
        if ($item.EndsWith('*')) {
            if ($lower.StartsWith($item.Substring(0, $item.Length - 1))) { return '' }
        } elseif ($lower -eq $item) {
            return ''
        }
    }
    return ('флаг ' + $Flag + ' не входит в список разрешённых для этого типа')
}

function Test-FlagValue {
    param([string]$Flag, [string]$Value)
    $lower = $Flag.ToLower()
    $numeric = @('--tpslimit', '--transfers', '--checkers', '--retries')
    if ($numeric -contains $lower) {
        $number = 0
        if (-not [int]::TryParse([string]$Value, [ref]$number)) { return 'ожидается целое число' }
        if ($number -le 0) { return 'значение должно быть больше нуля' }
        if (($lower -eq '--transfers' -or $lower -eq '--checkers') -and $number -gt 8) {
            return 'предупреждение: выше 8 можно превысить лимит 40 запросов в секунду (п. 2.2)'
        }
    }
    return ''
}

function Show-ExtraSettings {
    $entry = Get-RemoteEntry $Remote
    if (-not $entry) {
        Write-Host ('Для "' + $Remote + '" ещё нет записи в настройках — откройте пункт 20 или скачайте файл.') -ForegroundColor Yellow
        return
    }
    $type = Get-RemoteType
    $providerProfile = Get-ProviderProfile $type
    Write-Host ''
    Write-Host ('Хранилище: ' + $Remote + ' (' + $providerProfile.label + ')') -ForegroundColor Cyan
    Write-Host ('Разрешённые флаги: ' + ((@($providerProfile.allowedFlags)) -join ', '))
    if (@($providerProfile.allowedConfigKeys).Count -gt 0) {
        Write-Host ('Разрешённые ключи: ' + ((@($providerProfile.allowedConfigKeys)) -join ', '))
    }
    Write-Host ''
    $flags = @($entry.extraFlags)
    if ($flags.Count -eq 0) {
        Write-Host '  Флагов нет.'
    } else {
        $i = 0
        foreach ($f in $flags) {
            $i++
            Write-Host ('  {0}. {1} {2}' -f $i, $f.flag, $f.value)
        }
    }
    $keys = @($entry.backendOptions.Keys)
    if ($keys.Count -gt 0) {
        foreach ($k in ($keys | Sort-Object)) { Write-Host ('  ключ: ' + $k + ' = ' + $entry.backendOptions[$k]) }
    }
    Write-Host ''
    Write-Host ' a — добавить флаг, k — добавить ключ конфига, r — удалить флаг, x — сбросить всё, Enter — назад'
    $answer = Read-Line -Prompt 'Действие'
    if (-not $answer) { return }

    if ($answer -eq 'a') {
        $flag = Read-Line -Prompt 'Флаг (например, --tpslimit)'
        if (-not $flag) { return }
        $problem = Test-FlagAllowed -Flag $flag -ProviderProfile $providerProfile
        if ($problem) { Write-Host $problem -ForegroundColor Red; return }
        $value = Read-Line -Prompt 'Значение (Enter — без значения)'
        $valueProblem = Test-FlagValue -Flag $flag -Value $value
        if ($valueProblem) {
            if ($valueProblem.StartsWith('предупреждение')) {
                Write-Host $valueProblem -ForegroundColor Yellow
                if ((Read-Line -Prompt 'Всё равно добавить? (y/N)') -ne 'y') { return }
            } else {
                Write-Host $valueProblem -ForegroundColor Red
                return
            }
        }
        $entry.extraFlags = @($entry.extraFlags) + @(@{ flag = $flag; value = $value })
        Save-Config
        Write-Host ('Добавлено: ' + $flag + ' ' + $value) -ForegroundColor Green
        return
    }
    if ($answer -eq 'k') {
        $key = Read-Line -Prompt 'Ключ конфига'
        if (-not $key) { return }
        if (@($providerProfile.allowedConfigKeys) -notcontains $key) {
            Write-Host ('Ключ "' + $key + '" не входит в разрешённые для этого типа.') -ForegroundColor Red
            return
        }
        $value = Read-Line -Prompt 'Значение'
        & rclone config update $Remote $key $value 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host 'rclone не принял значение.' -ForegroundColor Red; return }
        $entry.backendOptions[$key] = $value
        Save-Config
        Write-Host ('Сохранено: ' + $key) -ForegroundColor Green
        return
    }
    if ($answer -eq 'r') {
        $raw = Read-Line -Prompt 'Номер флага для удаления'
        $index = 0
        if (-not [int]::TryParse($raw, [ref]$index) -or $index -lt 1 -or $index -gt @($entry.extraFlags).Count) {
            Write-Host 'Нет такого номера.' -ForegroundColor Yellow
            return
        }
        $list = @($entry.extraFlags)
        $entry.extraFlags = @($list | Where-Object { $_ -ne $list[$index - 1] })
        Save-Config
        Write-Host 'Удалено.' -ForegroundColor Green
        return
    }
    if ($answer -eq 'x') {
        $entry.extraFlags = @()
        $entry.backendOptions = @{}
        Save-Config
        Write-Host 'Сброшено к умолчаниям.' -ForegroundColor Green
        return
    }
    Write-Host 'Нет такого действия.' -ForegroundColor Yellow
}

function Show-Storages {
    $raw = & rclone listremotes 2>$null
    $names = @()
    foreach ($r in @($raw)) {
        $name = ([string]$r).TrimEnd(':')
        if ($name) { $names += $name }
    }
    if ($names.Count -eq 0) {
        Write-Host 'В rclone нет ни одного remote. Создайте его: rclone config или пункт 18 меню.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host ('{0,-3} {1,-16} {2,-12} {3}' -f '#', 'Хранилище', 'Тип', 'Локальная папка')
    $i = 0
    foreach ($name in $names) {
        $i++
        $entry = Get-RemoteEntry $name
        $type = ''
        if ($entry -and $entry.type) { $type = [string]$entry.type } else { $type = Get-RemoteType -Name $name }
        $path = Resolve-LocalRoot $name
        $mark = ''
        if ($name -eq $Remote) { $mark = ' *' }
        Write-Host ('{0,-3} {1,-16} {2,-12} {3}{4}' -f $i, $name, $type, $path, $mark)
    }
    Write-Host ''
    $defaultText = 'не задано'
    if ($script:Config.default) { $defaultText = [string]$script:Config.default }
    Write-Host ('* — текущее хранилище; по умолчанию: ' + $defaultText)
    Write-Host ' номер — переключиться, a — добавить, l — локальная папка, m — по умолчанию, d — удалить, Enter — назад'
    $answer = Read-Line -Prompt 'Действие'
    if (-not $answer) { return }

    if ($answer -eq 'a') {
        Write-Host ('Доступные типы: ' + (($script:Providers.Keys | Sort-Object) -join ', '))
        $type = Read-Line -Prompt 'Тип'
        if (-not $type) { return }
        $newName = Read-Line -Prompt 'Имя нового remote (например, gdrive)'
        if (-not $newName) { return }
        $script:Remote = $newName
        $script:RemoteType = ''
        $script:CurrentPath = ''
        Set-Credentials -Type $type
        Reset-Items
        return
    }
    if ($answer -eq 'l') { Set-LocalFolder; return }
    if ($answer -eq 'm') {
        $script:Config.default = $Remote
        Save-Config
        Write-Host ('По умолчанию: ' + $Remote) -ForegroundColor Green
        return
    }
    if ($answer -eq 'd') {
        if ($names.Count -lt 2) { Write-Host 'Нельзя удалить единственное хранилище.' -ForegroundColor Yellow; return }
        $del = Read-Line -Prompt 'Имя хранилища для удаления'
        if (-not $del) { return }
        if (@($names) -notcontains $del) { Write-Host 'Нет такого хранилища.' -ForegroundColor Yellow; return }
        if ((Read-Line -Prompt ('Удалить remote "' + $del + '" из rclone? (y/N)')) -ne 'y') { return }
        & rclone config delete $del 2>$null
        if ($script:Config.remotes.ContainsKey($del)) { $script:Config.remotes.Remove($del) }
        if ($script:Config.default -eq $del) { $script:Config.default = '' }
        Save-Config
        if ($del -eq $Remote) {
            $rest = @($names | Where-Object { $_ -ne $del })
            if ($rest.Count -gt 0) { $script:Remote = $rest[0] }
            $script:RemoteType = ''
            $script:CurrentPath = ''
            Reset-Items
        }
        Write-Host ('Удалено: ' + $del) -ForegroundColor Green
        return
    }

    $idx = 0
    if ([int]::TryParse($answer, [ref]$idx) -and $idx -ge 1 -and $idx -le $names.Count) {
        $target = $names[$idx - 1]
        if ($target -ne $Remote) {
            $script:Remote = $target
            $script:RemoteType = ''
            $script:CurrentPath = ''
            Reset-Items
            Write-Host ('Переключено на ' + $target) -ForegroundColor Green
        }
        return
    }
    Write-Host 'Нет такого действия.' -ForegroundColor Yellow
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
        '10. Загрузить папку на Диск',
        '20. Хранилища',
        '21. Расширенные настройки'
    )
    $right = @(
        '11. Загрузить файл на Диск',
        '12. Локальная папка для Диска',
        '13. Место на диске и квота',
        '14. Диагностика доступа',
        '15. Ошибки из журнала',
        '16. Открыть журнал',
        '17. Открыть локальную папку',
        '18. Настроить доступ (ключи)',
        '19. Шпаргалка по rclone',
        ' 0. Выход'
    )
    Write-Host ''
    $rows = [Math]::Max($left.Count, $right.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        $l = ''
        $r = ''
        if ($i -lt $left.Count) { $l = $left[$i] }
        if ($i -lt $right.Count) { $r = $right[$i] }
        Write-Host ($l.PadRight(42) + $r)
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not (Test-Rclone)) { return }

Import-Config
Import-Providers
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
        '18' { Set-Credentials -Type $Type }
        '19' { Show-Help }
        '20' { Show-Storages }
        '21' { Show-ExtraSettings }
        '0' { return }
        'q' { return }
        default { Write-Host 'Нет такого пункта.' -ForegroundColor Yellow }
    }
}
