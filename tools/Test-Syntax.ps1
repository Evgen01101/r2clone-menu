[CmdletBinding()]
param(
    [string]$Root = ''
)

if (-not $Root) {
    $here = $PSScriptRoot
    if (-not $here) { $here = (Get-Location).Path }
    $Root = Split-Path -Parent $here
}

$problems = @()
$files = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' })

if ($files.Count -eq 0) {
    Write-Host 'Не найдено ни одного .ps1 для проверки.' -ForegroundColor Red
    exit 1
}

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors) {
        foreach ($e in $parseErrors) {
            $problems += ('{0}:{1}: {2}' -f $file.Name, $e.Extent.StartLineNumber, $e.Message)
        }
    }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host ('ОШИБКА: ' + $p) -ForegroundColor Red }
    exit 1
}

Write-Host ('Синтаксис в порядке. Проверено файлов: ' + $files.Count) -ForegroundColor Green
exit 0
