param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [string]$OutputDir,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "bookstack-config.json"),
    [switch]$Recurse,
    [switch]$IncludeIndex,
    [switch]$CleanOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-OptionalConfig {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    return $null
}

function Get-ConfigValue {
    param(
        [AllowNull()][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name) {
        $value = $Config.$Name
        if ($null -ne $value -and "$value" -ne "") {
            return $value
        }
    }

    return $Default
}

function Get-HtmlFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return @(Get-Item -LiteralPath $Path)
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Input path not found: $Path"
    }

    $searchOption = if ($Recurse) { "AllDirectories" } else { "TopDirectoryOnly" }
    return @([System.IO.Directory]::EnumerateFiles($Path, "*.html", $searchOption) | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object FullName)
}

function Get-InnerHtmlByDivId {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $startMatch = [regex]::Match($Html, "<div\b[^>]*\bid\s*=\s*[""']$([regex]::Escape($Id))[""'][^>]*>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $startMatch.Success) {
        return $null
    }

    $position = $startMatch.Index + $startMatch.Length
    $depth = 1
    $tagRegex = [regex]"</?div\b[^>]*>"

    while ($position -lt $Html.Length) {
        $tagMatch = $tagRegex.Match($Html, $position)
        if (-not $tagMatch.Success) {
            break
        }

        if ($tagMatch.Value.StartsWith("</", [System.StringComparison]::Ordinal)) {
            $depth--
            if ($depth -eq 0) {
                return $Html.Substring($startMatch.Index + $startMatch.Length, $tagMatch.Index - ($startMatch.Index + $startMatch.Length))
            }
        }
        else {
            $depth++
        }

        $position = $tagMatch.Index + $tagMatch.Length
    }

    return $null
}

function Get-BodyInnerHtml {
    param([Parameter(Mandatory = $true)][string]$Html)

    $match = [regex]::Match($Html, "<body\b[^>]*>(?<body>.*)</body>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) {
        return $match.Groups["body"].Value
    }

    return $Html
}

function Get-MimeType {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    if ($Bytes.Length -ge 8 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) {
        return "image/png"
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) {
        return "image/jpeg"
    }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x38) {
        return "image/gif"
    }
    if ([System.IO.Path]::GetExtension($Path).Equals(".svg", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "image/svg+xml"
    }
    if ([System.IO.Path]::GetExtension($Path).Equals(".webp", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "image/webp"
    }

    return "application/octet-stream"
}

function Resolve-LocalAssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$HtmlFileDir,
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return $null
    }

    if ($Reference -match "^(?i)(data:|https?:|mailto:|#)") {
        return $null
    }

    $withoutFragment = ($Reference -split "#", 2)[0]
    $withoutQuery = ($withoutFragment -split "\?", 2)[0]
    $decoded = [System.Uri]::UnescapeDataString($withoutQuery)
    $decoded = $decoded -replace "/", [System.IO.Path]::DirectorySeparatorChar

    if ([System.IO.Path]::IsPathRooted($decoded)) {
        return $decoded
    }

    return [System.IO.Path]::GetFullPath((Join-Path $HtmlFileDir $decoded))
}

function Convert-ImagesToDataUris {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$HtmlFileDir,
        [ref]$EmbeddedCount,
        [ref]$MissingCount
    )

    return [regex]::Replace(
        $Html,
        "<img\b[^>]*>",
        {
            param($match)

            $tag = $match.Value
            $srcMatch = [regex]::Match($tag, "\bsrc\s*=\s*([""'])(?<src>.*?)\1", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $srcMatch.Success) {
                return $tag
            }

            $src = [System.Net.WebUtility]::HtmlDecode($srcMatch.Groups["src"].Value)
            if ($src -match "^(?i)data:") {
                return $tag
            }

            $candidatePath = Resolve-LocalAssetPath -HtmlFileDir $HtmlFileDir -Reference $src

            if ($null -eq $candidatePath -or -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                $dataSrcMatch = [regex]::Match($tag, "\bdata-image-src\s*=\s*([""'])(?<src>.*?)\1", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($dataSrcMatch.Success) {
                    $candidatePath = Resolve-LocalAssetPath -HtmlFileDir $HtmlFileDir -Reference ([System.Net.WebUtility]::HtmlDecode($dataSrcMatch.Groups["src"].Value))
                }
            }

            if ($null -eq $candidatePath -or -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                $MissingCount.Value++
                return $tag
            }

            $bytes = [System.IO.File]::ReadAllBytes($candidatePath)
            $mime = Get-MimeType -Path $candidatePath -Bytes $bytes
            $dataUri = "data:$mime;base64,$([System.Convert]::ToBase64String($bytes))"
            $updated = [regex]::Replace($tag, "\bsrc\s*=\s*([""']).*?\1", "src=`"$dataUri`"", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $updated = [regex]::Replace($updated, "\sdata-[\w:-]+\s*=\s*([""']).*?\1", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $updated = [regex]::Replace($updated, "\sloading\s*=\s*([""']).*?\1", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $EmbeddedCount.Value++
            return $updated
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
}

function Convert-ConfluencePage {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    $html = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $content = Get-InnerHtmlByDivId -Html $html -Id "main-content"
    if ($null -eq $content) {
        $content = Get-BodyInnerHtml -Html $html
    }

    $content = [regex]::Replace($content, "<style\b[^>]*>.*?</style>", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $content = [regex]::Replace($content, "<script\b[^>]*>.*?</script>", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $content = [regex]::Replace($content, "<!--.*?-->", "", [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $embedded = 0
    $missing = 0
    $content = Convert-ImagesToDataUris -Html $content -HtmlFileDir $File.DirectoryName -EmbeddedCount ([ref]$embedded) -MissingCount ([ref]$missing)
    $content = $content -replace "\r\n", "`n"
    $content = $content -replace "\r", "`n"
    $content = [regex]::Replace($content, "\n{3,}", "`n`n").Trim() + "`n"

    $outputPath = Join-Path $DestinationDir $File.Name
    [System.IO.File]::WriteAllText($outputPath, $content, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Source   = $File.FullName
        Output   = $outputPath
        Embedded = $embedded
        Missing  = $missing
    }
}

$config = Read-OptionalConfig -Path $ConfigPath

if (-not $PSBoundParameters.ContainsKey("OutputDir") -or [string]::IsNullOrWhiteSpace($OutputDir)) {
    $configuredReadyDir = Get-ConfigValue -Config $config -Name "ReadyDir"
    if (-not [string]::IsNullOrWhiteSpace($configuredReadyDir) -and $configuredReadyDir -ne "C:\Path\To\Confluence-space-export.html\Ready for Bookstack\ByAPI") {
        $OutputDir = $configuredReadyDir
    }
    else {
        $inputItem = Get-Item -LiteralPath $InputPath
        $baseDir = if ($inputItem.PSIsContainer) { $inputItem.FullName } else { $inputItem.DirectoryName }
        $OutputDir = Join-Path $baseDir "Ready for Bookstack\ByAPI"
    }
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

if ($CleanOutput) {
    Get-ChildItem -LiteralPath $OutputDir -Filter "*.html" -File | Remove-Item -Force
}

$files = @(Get-HtmlFiles -Path $InputPath)
if (-not $IncludeIndex) {
    $files = @($files | Where-Object { $_.Name -ne "index.html" })
}

if ($files.Count -eq 0) {
    Write-Host "No Confluence HTML files found to prepare."
    exit 0
}

$results = @(foreach ($file in $files) {
    Write-Host "Preparing $($file.Name)..."
    Convert-ConfluencePage -File $file -DestinationDir $OutputDir
})

$summaryPath = Join-Path $OutputDir "conversion-summary.txt"
$summary = @(
    "Confluence HTML to BookStack API preparation summary"
    "Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    "Input: $InputPath"
    "Output: $OutputDir"
    "Files: $($results.Count)"
    "Images embedded: $(($results | Measure-Object -Property Embedded -Sum).Sum)"
    "Images missing: $(($results | Measure-Object -Property Missing -Sum).Sum)"
    ""
)

$summary += $results | ForEach-Object {
    "{0} | embedded={1} | missing={2}" -f ([System.IO.Path]::GetFileName($_.Output)), $_.Embedded, $_.Missing
}

[System.IO.File]::WriteAllLines($summaryPath, $summary, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "Done."
Write-Host "Prepared files: $($results.Count)"
Write-Host "Images embedded: $(($results | Measure-Object -Property Embedded -Sum).Sum)"
Write-Host "Images missing: $(($results | Measure-Object -Property Missing -Sum).Sum)"
Write-Host "Output folder: $OutputDir"
Write-Host "Summary: $summaryPath"
