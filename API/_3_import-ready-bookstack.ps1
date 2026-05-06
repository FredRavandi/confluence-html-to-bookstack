param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "bookstack-config.json"),
    [string]$BaseUrl,
    [string]$BookUrl,
    [string]$BookSlug,
    [string]$ReadyDir,
    [string]$SourceDir,
    [string]$TokenId,
    [string]$TokenSecret,
    [int]$ApiTimeoutSec,
    [ValidateSet("Curl", "WebRequest")]
    [string]$WriteClient,
    [bool]$DeleteAfterImport,
    [switch]$SmokeTest,
    [switch]$Commit,
    [switch]$UpdateExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptVersion = "2026-05-06-config-driven"
$CommandLineParameters = @{} + $PSBoundParameters

function Read-BookStackConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($Config.PSObject.Properties.Name -contains $Name) {
        $value = $Config.$Name
        if ($null -ne $value -and "$value" -ne "") {
            return $value
        }
    }

    return $Default
}

function Use-ParameterOrConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][hashtable]$BoundParameters,
        [object]$Default = $null
    )

    if ($BoundParameters.ContainsKey($Name)) {
        return $BoundParameters[$Name]
    }

    return Get-ConfigValue -Config $Config -Name $Name -Default $Default
}

function Resolve-BookLocation {
    param(
        [string]$ConfiguredBaseUrl,
        [string]$ConfiguredBookUrl,
        [string]$ConfiguredBookSlug
    )

    $resolvedBaseUrl = $ConfiguredBaseUrl
    $resolvedBookSlug = $ConfiguredBookSlug

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredBookUrl)) {
        $uri = [Uri]$ConfiguredBookUrl
        $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ -ne "" })
        $booksIndex = [Array]::IndexOf($segments, "books")

        if ($booksIndex -ge 0 -and $segments.Count -gt ($booksIndex + 1)) {
            if ([string]::IsNullOrWhiteSpace($resolvedBookSlug) -or $resolvedBookSlug -eq "your-book-slug") {
                $resolvedBookSlug = [System.Uri]::UnescapeDataString($segments[$booksIndex + 1])
            }

            if ([string]::IsNullOrWhiteSpace($resolvedBaseUrl) -or $resolvedBaseUrl -eq "https://your-bookstack.example.com") {
                $basePath = ""
                if ($booksIndex -gt 0) {
                    $basePath = "/" + (($segments[0..($booksIndex - 1)]) -join "/")
                }

                $resolvedBaseUrl = "$($uri.Scheme)://$($uri.Authority)$basePath"
            }
        }
    }

    return [pscustomobject]@{
        BaseUrl  = if ($resolvedBaseUrl) { $resolvedBaseUrl.TrimEnd("/") } else { $null }
        BookSlug = $resolvedBookSlug
    }
}

function Assert-ConfiguredValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value,
        [string[]]$Placeholders = @()
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or ($Placeholders -contains $Value)) {
        throw "Set '$Name' in $ConfigPath or pass -$Name on the command line."
    }
}

function ConvertTo-JsonStringLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "null"
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')

    foreach ($char in $Value.ToCharArray()) {
        $code = [int][char]$char

        switch ($code) {
            8  { [void]$builder.Append('\b'); break }
            9  { [void]$builder.Append('\t'); break }
            10 { [void]$builder.Append('\n'); break }
            12 { [void]$builder.Append('\f'); break }
            13 { [void]$builder.Append('\r'); break }
            34 { [void]$builder.Append('\"'); break }
            92 { [void]$builder.Append('\\'); break }
            default {
                if ($code -lt 32) {
                    [void]$builder.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$builder.Append($char)
                }
            }
        }
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-BookStackJsonBody {
    param([Parameter(Mandatory = $true)][hashtable]$Body)

    $parts = foreach ($key in $Body.Keys) {
        $jsonKey = ConvertTo-JsonStringLiteral -Value ([string]$key)
        $value = $Body[$key]

        if ($null -eq $value) {
            $jsonValue = "null"
        }
        elseif ($value -is [bool]) {
            $jsonValue = if ($value) { "true" } else { "false" }
        }
        elseif ($value -is [byte] -or $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or $value -is [decimal] -or $value -is [double] -or $value -is [single]) {
            $jsonValue = [string]$value
        }
        else {
            $jsonValue = ConvertTo-JsonStringLiteral -Value ([string]$value)
        }

        "${jsonKey}:$jsonValue"
    }

    return "{" + ($parts -join ",") + "}"
}

function Invoke-BookStackApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )

    $uri = "$BaseUrl/api/$Path"
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec $ApiTimeoutSec
    }

    $json = ConvertTo-BookStackJsonBody -Body $Body
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Write-Host ("Sending {0:N0} bytes to {1} {2}..." -f $bodyBytes.Length, $Method.ToUpperInvariant(), $Path)

    if ($WriteClient -eq "Curl") {
        $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "bookstack-api-$([guid]::NewGuid()).json")
        [System.IO.File]::WriteAllBytes($tempFile, $bodyBytes)

        try {
            $curlArgs = @(
                "--http1.1",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--connect-timeout", "30",
                "--max-time", "$ApiTimeoutSec",
                "--request", $Method.ToUpperInvariant(),
                "--header", "Authorization: Token ${TokenId}:${TokenSecret}",
                "--header", "Accept: application/json",
                "--header", "Content-Type: application/json; charset=utf-8",
                "--header", "User-Agent: BookStack-PowerShell-Importer/1.0",
                "--data-binary", "@$tempFile",
                $uri
            )

            $curlOutput = & curl.exe @curlArgs
            $curlExitCode = $LASTEXITCODE

            if ($curlExitCode -ne 0) {
                throw "curl.exe failed with exit code $curlExitCode. Response: $curlOutput"
            }

            if ([string]::IsNullOrWhiteSpace($curlOutput)) {
                return $null
            }

            return $curlOutput | ConvertFrom-Json
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force
            }
        }
    }

    $response = Invoke-WebRequest `
        -Method $Method `
        -Uri $uri `
        -Headers $headers `
        -Body $bodyBytes `
        -ContentType "application/json; charset=utf-8" `
        -UseBasicParsing `
        -DisableKeepAlive `
        -TimeoutSec $ApiTimeoutSec

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function Get-BookStackItems {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [int]$Count = 500
    )

    $items = @()
    $offset = 0

    while ($true) {
        $result = Invoke-BookStackApi -Method "GET" -Path "${Endpoint}?count=$Count&offset=$offset"
        if ($null -eq $result.data -or $result.data.Count -eq 0) {
            break
        }

        $items += $result.data

        if ($result.data.Count -lt $Count) {
            break
        }

        $offset += $Count
    }

    return $items
}

function Convert-FileNameToPageName {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $name = $name -replace "_\d+$", ""
    $name = $name -replace "---", " BOOKSTACKDASHTOKEN "
    $name = $name -replace "_", " "
    $name = $name -replace "-", " "
    $name = $name -replace "BOOKSTACKDASHTOKEN", " - "
    $name = $name -replace "\s+", " "
    return [System.Net.WebUtility]::HtmlDecode($name.Trim())
}

function Convert-FolderNameToChapterName {
    param([Parameter(Mandatory = $true)][string]$FolderName)

    $name = $FolderName -replace "_\d+$", ""
    $name = $name -replace "---", " BOOKSTACKDASHTOKEN "
    $name = $name -replace "_", " "
    $name = $name -replace "-", " "
    $name = $name -replace "BOOKSTACKDASHTOKEN", " - "
    $name = $name -replace "\s+", " "
    return [System.Net.WebUtility]::HtmlDecode($name.Trim())
}

function Get-PageChapterId {
    param([Parameter(Mandatory = $true)]$Page)

    if ($Page.PSObject.Properties.Name -contains "chapter_id" -and $null -ne $Page.chapter_id) {
        return [int]$Page.chapter_id
    }

    return 0
}

function Get-PageParentKey {
    param(
        [Parameter(Mandatory = $true)][string]$PageName,
        [int]$ChapterId = 0
    )

    return "$ChapterId|$PageName"
}

function Add-PageToNameIndex {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [Parameter(Mandatory = $true)]$Page
    )

    if (-not $Index.ContainsKey($Page.name)) {
        $Index[$Page.name] = @()
    }

    $Index[$Page.name] = @($Index[$Page.name]) + $Page
}

function Get-ImportPlan {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $jobs = @()
    $chapters = @()
    $bookPriority = 1

    $items = @(Get-ChildItem -LiteralPath $Directory -Force | Where-Object {
        ($_.PSIsContainer) -or ($_.Extension -ieq ".html")
    } | Sort-Object Name)

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $chapterFiles = @(Get-ChildItem -LiteralPath $item.FullName -Filter "*.html" -File | Sort-Object Name)
            if ($chapterFiles.Count -eq 0) {
                Write-Host "Chapter folder skipped because it has no HTML files: $($item.FullName)"
                continue
            }

            $chapterName = Convert-FolderNameToChapterName -FolderName $item.Name
            $chapters += [pscustomobject]@{
                Name     = $chapterName
                Folder   = $item.FullName
                Priority = $bookPriority
            }

            $pagePriority = 1
            foreach ($file in $chapterFiles) {
                $jobs += [pscustomobject]@{
                    File          = $file
                    PageName      = Convert-FileNameToPageName -FileName $file.Name
                    ChapterName   = $chapterName
                    ChapterFolder = $item.FullName
                    PagePriority  = $pagePriority
                }

                $pagePriority++
            }

            $bookPriority++
            continue
        }

        $jobs += [pscustomobject]@{
            File          = $item
            PageName      = Convert-FileNameToPageName -FileName $item.Name
            ChapterName   = $null
            ChapterFolder = $null
            PagePriority  = $bookPriority
        }

        $bookPriority++
    }

    return [pscustomobject]@{
        Chapters = $chapters
        Jobs     = $jobs
    }
}

$config = Read-BookStackConfig -Path $ConfigPath

$BaseUrl = Use-ParameterOrConfig -Name "BaseUrl" -Config $config -BoundParameters $CommandLineParameters
$BookUrl = Use-ParameterOrConfig -Name "BookUrl" -Config $config -BoundParameters $CommandLineParameters
$BookSlug = Use-ParameterOrConfig -Name "BookSlug" -Config $config -BoundParameters $CommandLineParameters
$ReadyDir = Use-ParameterOrConfig -Name "ReadyDir" -Config $config -BoundParameters $CommandLineParameters
$SourceDir = Use-ParameterOrConfig -Name "SourceDir" -Config $config -BoundParameters $CommandLineParameters
$TokenId = Use-ParameterOrConfig -Name "TokenId" -Config $config -BoundParameters $CommandLineParameters
$TokenSecret = Use-ParameterOrConfig -Name "TokenSecret" -Config $config -BoundParameters $CommandLineParameters
$ApiTimeoutSec = [int](Use-ParameterOrConfig -Name "ApiTimeoutSec" -Config $config -BoundParameters $CommandLineParameters -Default 300)
$WriteClient = Use-ParameterOrConfig -Name "WriteClient" -Config $config -BoundParameters $CommandLineParameters -Default "Curl"
$DeleteAfterImport = [bool](Use-ParameterOrConfig -Name "DeleteAfterImport" -Config $config -BoundParameters $CommandLineParameters -Default $false)

$location = Resolve-BookLocation -ConfiguredBaseUrl $BaseUrl -ConfiguredBookUrl $BookUrl -ConfiguredBookSlug $BookSlug
$BaseUrl = $location.BaseUrl
$BookSlug = $location.BookSlug

Assert-ConfiguredValue -Name "BaseUrl" -Value $BaseUrl -Placeholders @("https://your-bookstack.example.com")
Assert-ConfiguredValue -Name "BookSlug" -Value $BookSlug -Placeholders @("your-book-slug")
Assert-ConfiguredValue -Name "TokenId" -Value $TokenId -Placeholders @("BOOKSTACK_TOKEN_ID_HERE")
Assert-ConfiguredValue -Name "TokenSecret" -Value $TokenSecret -Placeholders @("BOOKSTACK_TOKEN_SECRET_HERE")
Assert-ConfiguredValue -Name "ReadyDir" -Value $ReadyDir -Placeholders @("C:\Path\To\Confluence-space-export.html\Ready for Bookstack\ByAPI")

if (@("Curl", "WebRequest") -notcontains $WriteClient) {
    throw "WriteClient must be either 'Curl' or 'WebRequest'. Current value: $WriteClient"
}

if (-not (Test-Path -LiteralPath $ReadyDir)) {
    throw "Ready directory not found: $ReadyDir"
}

$headers = @{
    "Authorization" = "Token ${TokenId}:${TokenSecret}"
    "Accept"        = "application/json"
    "User-Agent"    = "BookStack-PowerShell-Importer/1.0"
}

[System.Net.ServicePointManager]::Expect100Continue = $false

Write-Host "BookStack URL: $BaseUrl"
Write-Host "Script version: $ScriptVersion"
Write-Host "Target book slug: $BookSlug"
Write-Host "Import folder: $ReadyDir"
Write-Host "Write client: $WriteClient"

if (-not $Commit) {
    Write-Host ""
    Write-Host "DRY RUN ONLY. Add -Commit to create/update pages."
}

$book = Get-BookStackItems -Endpoint "books" | Where-Object { $_.slug -eq $BookSlug } | Select-Object -First 1
if ($null -eq $book) {
    throw "Could not find BookStack book with slug '$BookSlug'."
}

if ($SmokeTest) {
    $smokeName = "API Smoke Test $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host ""
    Write-Host "Smoke test page: $smokeName"

    if (-not $Commit) {
        Write-Host "Would create a tiny smoke test page in book ID $($book.id). Add -Commit to actually create it."
        exit 0
    }

    $smokePage = Invoke-BookStackApi -Method "POST" -Path "pages" -Body @{
        book_id  = $book.id
        name     = $smokeName
        html     = "<p>BookStack API smoke test from importer.</p>"
        priority = 9999
    }

    Write-Host "Smoke test created page ID $($smokePage.id)."
    Write-Host "Delete that smoke test page in BookStack after confirming the API path works."
    exit 0
}

$existingChapters = @{}
Get-BookStackItems -Endpoint "chapters" |
    Where-Object { $_.book_id -eq $book.id } |
    ForEach-Object {
        if (-not $existingChapters.ContainsKey($_.name)) {
            $existingChapters[$_.name] = $_
        }
        else {
            Write-Warning "Duplicate chapter name already exists in BookStack and may be ambiguous: $($_.name)"
        }
    }

$existingPagesByParent = @{}
$existingPagesByName = @{}
Get-BookStackItems -Endpoint "pages" |
    Where-Object { $_.book_id -eq $book.id } |
    ForEach-Object {
        $chapterId = Get-PageChapterId -Page $_
        $pageKey = Get-PageParentKey -PageName $_.name -ChapterId $chapterId

        if (-not $existingPagesByParent.ContainsKey($pageKey)) {
            $existingPagesByParent[$pageKey] = $_
        }
        else {
            Write-Warning "Duplicate page name already exists in the same BookStack parent and may be ambiguous: $($_.name)"
        }

        Add-PageToNameIndex -Index $existingPagesByName -Page $_
    }

$importPlan = Get-ImportPlan -Directory $ReadyDir
$chapterPlans = @($importPlan.Chapters)
$pageJobs = @($importPlan.Jobs)

if ($pageJobs.Count -eq 0) {
    Write-Host "No HTML files found to import."
    exit 0
}

$created = 0
$updated = 0
$skipped = 0
$failed = 0
$chaptersCreated = 0
$chaptersExisting = 0
$chapterObjects = @{}

foreach ($chapterPlan in $chapterPlans) {
    Write-Host ""
    Write-Host "Chapter: $($chapterPlan.Name)"
    Write-Host "Folder: $($chapterPlan.Folder)"

    if ($existingChapters.ContainsKey($chapterPlan.Name)) {
        $chapter = $existingChapters[$chapterPlan.Name]
        $chapterObjects[$chapterPlan.Name] = $chapter
        $chaptersExisting++
        Write-Host "Using existing chapter ID $($chapter.id)."

        if ($Commit -and $UpdateExisting) {
            Write-Host "Clearing/updating existing chapter description..."
            Invoke-BookStackApi -Method "PUT" -Path "chapters/$($chapter.id)" -Body @{
                name             = $chapterPlan.Name
                description_html = ""
                priority         = $chapterPlan.Priority
            } | Out-Null
        }

        continue
    }

    if ($Commit) {
        Write-Host "Creating chapter in BookStack..."
        $chapter = Invoke-BookStackApi -Method "POST" -Path "chapters" -Body @{
            book_id          = $book.id
            name             = $chapterPlan.Name
            description_html = ""
            priority         = $chapterPlan.Priority
        }

        Write-Host "Created chapter ID $($chapter.id)."
        $existingChapters[$chapterPlan.Name] = $chapter
        $chapterObjects[$chapterPlan.Name] = $chapter
        $chaptersCreated++
    }
    else {
        Write-Host "Would create chapter in book ID $($book.id)."
        $chapterObjects[$chapterPlan.Name] = [pscustomobject]@{
            id       = $null
            name     = $chapterPlan.Name
            priority = $chapterPlan.Priority
        }
    }
}

foreach ($job in $pageJobs) {
    $file = $job.File
    $pageName = $job.PageName
    $chapter = $null
    $chapterId = 0

    if ($null -ne $job.ChapterName) {
        $chapter = $chapterObjects[$job.ChapterName]
        if ($null -ne $chapter.id) {
            $chapterId = [int]$chapter.id
        }
    }

    $html = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    Write-Host ""
    Write-Host "Page: $pageName"
    Write-Host "File: $($file.FullName)"
    if ($null -ne $job.ChapterName) {
        Write-Host "Target chapter: $($job.ChapterName)"
    }
    else {
        Write-Host "Target: book root"
    }

    try {
        $pageKey = Get-PageParentKey -PageName $pageName -ChapterId $chapterId
        $existing = $null
        $existingInDifferentParent = $false

        if ($chapterId -ne 0 -or $null -eq $job.ChapterName) {
            if ($existingPagesByParent.ContainsKey($pageKey)) {
                $existing = $existingPagesByParent[$pageKey]
            }
        }

        if ($null -eq $existing -and $existingPagesByName.ContainsKey($pageName)) {
            $sameNamePages = @($existingPagesByName[$pageName])
            if ($sameNamePages.Count -eq 1) {
                $existing = $sameNamePages[0]
                $existingInDifferentParent = $true
            }
            else {
                Write-Host "Skipped: multiple existing pages have this name in BookStack, and no exact parent match was found."
                $skipped++
                continue
            }
        }

        if ($null -ne $existing) {

            if (-not $UpdateExisting) {
                if ($existingInDifferentParent) {
                    Write-Host "Skipped: page already exists in another location. Use -UpdateExisting to move/overwrite it."
                }
                else {
                    Write-Host "Skipped: page already exists. Use -UpdateExisting to overwrite it."
                }
                $skipped++
                continue
            }

            if ($Commit) {
                Write-Host "Updating page in BookStack..."
                $updateBody = @{
                    name = $pageName
                    html = $html
                    priority = $job.PagePriority
                }

                if ($null -ne $job.ChapterName) {
                    $updateBody["chapter_id"] = $chapterId
                }
                else {
                    $updateBody["book_id"] = $book.id
                }

                Invoke-BookStackApi -Method "PUT" -Path "pages/$($existing.id)" -Body $updateBody | Out-Null

                Write-Host "Updated existing page ID $($existing.id)."
                if ($existingInDifferentParent) {
                    Write-Host "Moved page to the selected parent."
                }
                $updated++

                if ($DeleteAfterImport) {
                    Remove-Item -LiteralPath $file.FullName -Force
                    Write-Host "Deleted imported HTML file."
                }
            }
            else {
                if ($existingInDifferentParent) {
                    Write-Host "Would update and move existing page ID $($existing.id) to the selected parent."
                }
                else {
                    Write-Host "Would update existing page ID $($existing.id)."
                }
            }
        }
        else {
            if ($Commit) {
                Write-Host "Creating page in BookStack..."
                $createBody = @{
                    name     = $pageName
                    html     = $html
                    priority = $job.PagePriority
                }

                if ($null -ne $job.ChapterName) {
                    $createBody["chapter_id"] = $chapterId
                }
                else {
                    $createBody["book_id"] = $book.id
                }

                $createdPage = Invoke-BookStackApi -Method "POST" -Path "pages" -Body $createBody

                Write-Host "Created page ID $($createdPage.id)."
                $created++

                if ($DeleteAfterImport) {
                    Remove-Item -LiteralPath $file.FullName -Force
                    Write-Host "Deleted imported HTML file."
                }
            }
            else {
                if ($null -ne $job.ChapterName) {
                    Write-Host "Would create new page in chapter '$($job.ChapterName)'."
                }
                else {
                    Write-Host "Would create new page in book ID $($book.id)."
                }
            }
        }
    }
    catch {
        $failed++
        Write-Warning "Failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done."
Write-Host "Chapters created:  $chaptersCreated"
Write-Host "Chapters existing: $chaptersExisting"
Write-Host "Created: $created"
Write-Host "Updated: $updated"
Write-Host "Skipped: $skipped"
Write-Host "Failed:  $failed"

if (-not $Commit) {
    Write-Host ""
    Write-Host "Run again with -Commit when you are ready to import."
}
