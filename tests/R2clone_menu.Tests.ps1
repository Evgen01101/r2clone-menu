[CmdletBinding()]
param()

[System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo('ru-RU')

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'R2clone_menu.ps1'

. $scriptPath

Describe 'Format-Size' {
    It 'показывает байты' {
        Format-Size 512 | Should Be '512 Б'
    }
    It 'показывает килобайты' {
        Format-Size 2048 | Should Be '2 КБ'
    }
    It 'показывает мегабайты' {
        Format-Size 1048576 | Should Be '1,0 МБ'
    }
    It 'показывает гигабайты' {
        Format-Size 1610612736 | Should Be '1,50 ГБ'
    }
    It 'не падает на нуле' {
        Format-Size 0 | Should Be '0 Б'
    }
}

Describe 'Get-RemotePath' {
    It 'возвращает корень remote' {
        $script:CurrentPath = ''
        Get-RemotePath | Should Be 'ydisk:'
    }
    It 'добавляет текущую папку' {
        $script:CurrentPath = 'A/B'
        Get-RemotePath | Should Be 'ydisk:A/B'
    }
    It 'добавляет вложенный элемент' {
        $script:CurrentPath = 'A'
        Get-RemotePath 'file.txt' | Should Be 'ydisk:A/file.txt'
    }
    It 'работает от корня с вложенным элементом' {
        $script:CurrentPath = ''
        Get-RemotePath 'Папка' | Should Be 'ydisk:Папка'
    }
}

Describe 'Get-LocalRoot и Get-LocalPath' {
    It 'по умолчанию использует disks/remote рядом со скриптом' {
        $script:OverrideRoot = ''
        $script:Roots = @{}
        $script:CurrentPath = ''
        Get-LocalRoot | Should Be (Join-Path (Join-Path $script:BaseDir 'disks') 'ydisk')
    }
    It 'берёт значение из настроек' {
        $script:OverrideRoot = ''
        $script:Roots = @{ ydisk = 'D:\Data' }
        Get-LocalRoot | Should Be 'D:\Data'
    }
    It 'параметр запуска важнее настроек' {
        $script:OverrideRoot = 'E:\Other'
        $script:Roots = @{ ydisk = 'D:\Data' }
        Get-LocalRoot | Should Be 'E:\Other'
    }
    It 'сохраняет структуру папок в локальном пути' {
        $script:OverrideRoot = 'D:\Tmp'
        $script:CurrentPath = 'A/B'
        Get-LocalPath | Should Be 'D:\Tmp\A\B'
    }
    It 'добавляет имя файла' {
        $script:OverrideRoot = 'D:\Tmp'
        $script:CurrentPath = 'A'
        Get-LocalPath 'file.txt' | Should Be 'D:\Tmp\A\file.txt'
    }
}

Describe 'Get-DefaultLocalRoot' {
    It 'создаёт путь disks/<remote>' {
        Get-DefaultLocalRoot 'gdrive' | Should Be (Join-Path (Join-Path $script:BaseDir 'disks') 'gdrive')
    }
}

Describe 'Test-LocalPathProblem' {
    It 'пустой путь' {
        Test-LocalPathProblem -Path '' | Should Be 'путь не задан'
    }
    It 'корректный абсолютный путь' {
        Test-LocalPathProblem -Path 'C:\Temp' | Should Be ''
    }
    It 'относительный путь отклоняется' {
        (Test-LocalPathProblem -Path 'folder\sub') | Should Not Be ''
    }
    It 'запрещённые символы отклоняются' {
        (Test-LocalPathProblem -Path 'C:\a|b') | Should Match 'недопустимые'
    }
    It 'слишком длинный путь отклоняется' {
        $long = 'C:\' + ('a' * 250)
        (Test-LocalPathProblem -Path $long) | Should Match '240'
    }
}

Describe 'Файл настроек' {
    It 'пример настроек — валидный JSON с roots' {
        $example = Join-Path $repoRoot 'R2clone_menu.config.example.json'
        Test-Path -LiteralPath $example | Should Be $true
        $obj = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
        @($obj.roots.PSObject.Properties.Name).Count | Should BeGreaterThan 0
    }
}

Describe 'Идентичность проекта' {
    It 'версия задана и совпадает с CHANGELOG' {
        $script:AppVersion | Should Match '^\d+\.\d+\.\d+$'
        $changelog = Get-Content -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md') -Raw
        $changelog | Should Match ([regex]::Escape($script:AppVersion))
    }
    It 'LICENSE содержит MIT' {
        $license = Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') -Raw
        $license | Should Match 'MIT License'
    }
}
