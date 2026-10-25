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

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host ('ОШИБКА: ' + $e) -ForegroundColor Red }
    Write-Host ('Всего проблем: ' + $errors.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'Проверки гигиены пройдены: CRLF у .bat, BOM у .ps1, валидный JSON, обязательные файлы на месте.' -ForegroundColor Green
exit 0
