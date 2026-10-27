[CmdletBinding()]
param(
    [string]$Root = ''
)

if (-not $Root) {
    $here = $PSScriptRoot
    if (-not $here) { $here = (Get-Location).Path }
    $Root = Split-Path -Parent $here
}

$errors = New-Object System.Collections.Generic.List[string]
$selfName = 'tools/Test-Hygiene.ps1'

Get-ChildItem -LiteralPath $Root -Filter *.bat -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    ForEach-Object {
        $name = $_.Name
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
                $errors.Add($name + ': конец строки LF без CR (нужен CRLF)')
                break
            }
        }
    }

Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) { $errors.Add($_.Name + ': нет UTF-8 BOM (PowerShell 5.1 сломает кириллицу)') }
    }

Get-ChildItem -LiteralPath $Root -Filter *.json -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    ForEach-Object {
        try {
            $null = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $errors.Add($_.Name + ': некорректный JSON')
        }
    }

foreach ($file in @('README.md', 'CHANGELOG.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $file))) { $errors.Add($file + ': файл отсутствует') }
}

$tracked = @()
$gitOk = $false
if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
    Push-Location -LiteralPath $Root
    try {
        $tracked = @(& git -c core.quotepath=false ls-files)
        $gitOk = ($LASTEXITCODE -eq 0)
    } catch {
        $gitOk = $false
    } finally {
        Pop-Location
    }
}

if (-not $gitOk -or $tracked.Count -eq 0) {
    $skip = @('R2clone_menu.config.json', 'rclone.conf')
    $tracked = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '\\\.git\\' -and
            $_.FullName -notmatch '\\dist\\' -and
            $_.Extension -ne '.log' -and
            $skip -notcontains $_.Name
        } |
        ForEach-Object { $_.FullName.Substring($Root.TrimEnd('\').Length + 1).TrimStart('\', '/').Replace('\', '/') })
}

foreach ($bad in @('R2clone_menu.config.json', 'rclone.conf')) {
    if ($tracked -contains $bad) { $errors.Add($bad + ': личный файл попал в git') }
}
foreach ($item in $tracked) {
    if ($item -match '\.log$') { $errors.Add($item + ': журнал попал в git') }
}

$ignorePath = Join-Path $Root '.gitignore'
if (-not (Test-Path -LiteralPath $ignorePath)) {
    $errors.Add('.gitignore: файл отсутствует')
} else {
    $ignoreText = [IO.File]::ReadAllText($ignorePath, [Text.Encoding]::UTF8)
    foreach ($rule in @('R2clone_menu.config.json', '*.log', 'dist/')) {
        if (-not $ignoreText.Contains($rule)) { $errors.Add('.gitignore: нет правила ' + $rule) }
    }
}

$textExtensions = @('.md', '.ps1', '.psm1', '.bat', '.json', '.yml', '.yaml', '.txt')
$secretRules = @(
    @{ Name = 'похоже на ключ доступа'; Pattern = '(?i)(client_secret|access_token|refresh_token|client_id|secret_access_key|password)\s*[=:]\s*["'']?[A-Za-z0-9_\-\/\+]{16,}' }
    @{ Name = 'приватный ключ'; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
)
$allowMarkers = @('YOUR_', 'ВАШ', 'не прикладывайте', 'Не прикладывайте', 'placeholder', 'xxxx', '***', '<')
$personalRules = @(
    @{ Name = 'путь пользователя Windows'; Pattern = '(?i)[A-Z]:\\Users\\[^\\<]+\\' }
    @{ Name = 'личный путь загрузок'; Pattern = 'D:\\Загрузки' }
    @{ Name = 'личный путь проекта'; Pattern = 'E:\\AI\\' }
)

foreach ($rel in $tracked) {
    $ext = [IO.Path]::GetExtension([string]$rel).ToLower()
    if ($textExtensions -notcontains $ext) { continue }
    $full = Join-Path $Root ([string]$rel).Replace('/', '\')
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $text = ''
    try { $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) } catch { continue }
    $lines = $text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($rule in $secretRules) {
            if ($line -match $rule.Pattern) {
                $allowed = $false
                foreach ($marker in $allowMarkers) { if ($line.Contains($marker)) { $allowed = $true; break } }
                if (-not $allowed) { $errors.Add($rel + ':' + ($i + 1) + ': ' + $rule.Name) }
            }
        }
        if ($rel -ne $selfName) {
            foreach ($rule in $personalRules) {
                if ($line -match $rule.Pattern) { $errors.Add($rel + ':' + ($i + 1) + ': ' + $rule.Name) }
            }
        }
    }
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host ('ОШИБКА: ' + $e) -ForegroundColor Red }
    Write-Host ('Всего проблем: ' + $errors.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'Проверки гигиены пройдены: CRLF у .bat, BOM у .ps1, валидный JSON, обязательные файлы, нет ключей и личных путей в индексе, правила .gitignore на месте.' -ForegroundColor Green
exit 0
