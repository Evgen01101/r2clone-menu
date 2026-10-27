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
    It 'по умолчанию: <корень данных>\<type>\<remote>' {
        $script:OverrideRoot = ''
        $script:Config.remotes = @{ ydisk = @{ type = 'yandex'; localRoot = '' } }
        $script:CurrentPath = ''
        $expected = Join-Path (Join-Path (Get-DataRoot) 'yandex') 'ydisk'
        Get-LocalRoot | Should Be $expected
    }
    It 'абсолютный путь из настроек используется как есть' {
        $script:OverrideRoot = ''
        $script:Config.remotes = @{ ydisk = @{ type = 'yandex'; localRoot = 'D:\Data' } }
        Get-LocalRoot | Should Be 'D:\Data'
    }
    It 'относительный путь пристраивается к корню данных' {
        $script:OverrideRoot = ''
        $script:Config.remotes = @{ ydisk = @{ type = 'yandex'; localRoot = 'yandex\ydisk' } }
        Get-LocalRoot | Should Be (Join-Path (Get-DataRoot) 'yandex\ydisk')
    }
    It 'параметр запуска важнее настроек' {
        $script:OverrideRoot = 'E:\Other'
        $script:Config.remotes = @{ ydisk = @{ type = 'yandex'; localRoot = 'D:\Data' } }
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
    It 'корень данных переключается на пользовательский' {
        $script:Config.paths.dataRoot = 'user'
        (Get-DataRoot) | Should Match 'R2clone_menu\\data$'
        $script:Config.paths.dataRoot = 'portable'
    }
}

Describe 'Get-DefaultLocalRoot' {
    It 'строит путь <корень>\<type>\<remote>' {
        $script:Config.remotes = @{ gdrive = @{ type = 'drive'; localRoot = '' } }
        Get-DefaultLocalRoot 'gdrive' | Should Be (Join-Path (Join-Path (Get-DataRoot) 'drive') 'gdrive')
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
    It 'пример настроек — валидный JSON схемы v2' {
        $example = Join-Path $repoRoot 'R2clone_menu.config.example.json'
        Test-Path -LiteralPath $example | Should Be $true
        $obj = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
        $obj.schemaVersion | Should Be 2
        $obj.paths.dataRoot | Should Not BeNullOrEmpty
        @($obj.remotes.PSObject.Properties.Name).Count | Should BeGreaterThan 0
    }
}

Describe 'Миграция конфига' {
    It 'конвертирует старый roots в схему v2' {
        $tmp = Join-Path $env:TEMP ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($tmp, '{"roots":{"ydisk":"D:\\Data"}}', (New-Object Text.UTF8Encoding($false)))
            $script:Config = @{ schemaVersion = 2; paths = @{ dataRoot = 'portable' }; default = ''; remotes = @{} }
            Import-Config -Path $tmp
            $script:Config.remotes.ContainsKey('ydisk') | Should Be $true
            $script:Config.remotes['ydisk'].localRoot | Should Be 'D:\Data'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'читает схему v2 и сохраняет флаги' {
        $tmp = Join-Path $env:TEMP ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $json = '{"schemaVersion":2,"paths":{"dataRoot":"user"},"default":"gdrive","remotes":{"gdrive":{"type":"drive","localRoot":"drive\\gdrive","extraFlags":[{"flag":"--tpslimit","value":"5"}]}}}'
            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
            $script:Config = @{ schemaVersion = 2; paths = @{ dataRoot = 'portable' }; default = ''; remotes = @{} }
            Import-Config -Path $tmp
            $script:Config.paths.dataRoot | Should Be 'user'
            $script:Config.default | Should Be 'gdrive'
            @($script:Config.remotes['gdrive'].extraFlags).Count | Should Be 1
            @($script:Config.remotes['gdrive'].extraFlags)[0].flag | Should Be '--tpslimit'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            $script:Config.paths.dataRoot = 'portable'
        }
    }
    It 'сохраняет конфиг в схеме v2' {
        $tmp = Join-Path $env:TEMP ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $script:Config = @{
                schemaVersion = 2
                paths         = @{ dataRoot = 'portable' }
                default       = 'ydisk'
                remotes       = @{
                    ydisk = @{ type = 'yandex'; label = 'Яндекс.Диск'; localRoot = 'D:\Data'; lastPath = ''; backendOptions = @{}; extraFlags = @(); createdAt = ''; lastUsedAt = '' }
                }
            }
            Save-Config -Path $tmp
            $obj = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
            $obj.schemaVersion | Should Be 2
            $obj.remotes.ydisk.localRoot | Should Be 'D:\Data'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
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

Describe 'Каталог провайдеров' {
    It 'содержит пять стартовых типов' {
        foreach ($t in @('yandex', 'drive', 'onedrive', 's3', 'dropbox')) {
            $script:Providers.ContainsKey($t) | Should Be $true
        }
    }
    It 'каждый профиль заполнен обязательными полями' {
        foreach ($t in @($script:Providers.Keys)) {
            $p = Get-ProviderProfile $t
            $p.type | Should Be $t
            ($p.label.Length -gt 0) | Should Be $true
            $p.ContainsKey('fields') | Should Be $true
            $p.ContainsKey('allowedFlags') | Should Be $true
        }
    }
    It 'яндекс требует своё приложение и содержит атрибуцию' {
        $p = Get-ProviderProfile 'yandex'
        $p.requiresApp | Should Be $true
        ($p.attribution.Length -gt 0) | Should Be $true
        @($p.fields).Count | Should Be 2
    }
    It 'Google Drive работает без своего клиента' {
        $p = Get-ProviderProfile 'drive'
        $p.requiresApp | Should Be $false
        $p.optionalApp | Should Be $true
        $p.supportsAbout | Should Be $true
        $p.hasHashes | Should Be $true
        @($p.fields).Count | Should Be 2
    }
    It 'S3 без квоты, без хэшей и с пятью полями' {
        $p = Get-ProviderProfile 's3'
        $p.supportsAbout | Should Be $false
        $p.hasHashes | Should Be $false
        @($p.fields).Count | Should Be 5
    }
    It 'неизвестный тип получает безопасный профиль' {
        $p = Get-ProviderProfile 'unknown_backend'
        $p.experimental | Should Be $true
        $p.interactiveOnly | Should Be $true
        $p.label | Should Be 'unknown_backend'
        @($p.fields).Count | Should Be 0
    }
}

Describe 'Оверрайд каталога' {
    It 'перекрывает существующую запись и добавляет новую' {
        $tmp = Join-Path $env:TEMP ('providers-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $json = '{"schemaVersion":1,"providers":{"minio_test":{"label":"MinIO Test","fields":[{"name":"endpoint","label":"Endpoint","required":true}]},"drive":{"label":"GDrive Override"}}}'
            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
            Import-Providers -Path $tmp
            (Get-ProviderProfile 'minio_test').label | Should Be 'MinIO Test'
            @((Get-ProviderProfile 'minio_test').fields).Count | Should Be 1
            (Get-ProviderProfile 'drive').label | Should Be 'GDrive Override'
            (Get-ProviderProfile 'drive').supportsAbout | Should Be $true
        } finally {
            $script:ProviderOverrides = @{}
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-Setting' {
    It 'возвращает значение существующего ключа' {
        $map = @{ name = 'client_id'; label = 'ClientID' }
        Get-Setting -Map $map -Name 'label' | Should Be 'ClientID'
    }
    It 'не падает на отсутствующем ключе и отдаёт значение по умолчанию' {
        $map = @{ name = 'client_id' }
        { Get-Setting -Map $map -Name 'choices' } | Should Not Throw
        Get-Setting -Map $map -Name 'choices' | Should BeNullOrEmpty
        Get-Setting -Map $map -Name 'default' -Default 'x' | Should Be 'x'
    }
    It 'читает свойства PSCustomObject' {
        $obj = [pscustomobject]@{ label = 'Google Drive' }
        Get-Setting -Map $obj -Name 'label' | Should Be 'Google Drive'
        Get-Setting -Map $obj -Name 'choices' | Should BeNullOrEmpty
    }
    It 'возвращает значение по умолчанию для $null' {
        Get-Setting -Map $null -Name 'label' -Default 'none' | Should Be 'none'
    }
}

Describe 'Поля каталога без choices и default' {
    It 'читаются через Get-Setting без ошибок StrictMode: <type>' -TestCases @(
        @{ type = 'yandex' }
        @{ type = 'drive' }
        @{ type = 'onedrive' }
        @{ type = 's3' }
        @{ type = 'dropbox' }
    ) {
        param($type)
        $providerProfile = Get-ProviderProfile $type
        foreach ($field in @($providerProfile.fields)) {
            { Get-Setting -Map $field -Name 'choices' } | Should Not Throw
            { Get-Setting -Map $field -Name 'default' } | Should Not Throw
            { Get-Setting -Map $field -Name 'required' } | Should Not Throw
            { Get-Setting -Map $field -Name 'name' } | Should Not Throw
            $info = Read-FieldSettings -Field $field
            $rawChoices = Get-Setting -Map $field -Name 'choices'
            if ($rawChoices) {
                $info.choices.Count | Should Be @($rawChoices).Count
            } else {
                $info.choices.Count | Should Be 0
            }
            [string]$info.name | Should Not BeNullOrEmpty
        }
    }
    It 'все поля каталога содержат имя и подпись' {
        foreach ($type in @('yandex', 'drive', 'onedrive', 's3', 'dropbox')) {
            foreach ($field in @((Get-ProviderProfile $type).fields)) {
                [string](Get-Setting -Map $field -Name 'name') | Should Not BeNullOrEmpty
                [string](Get-Setting -Map $field -Name 'label') | Should Not BeNullOrEmpty
            }
        }
    }
}
