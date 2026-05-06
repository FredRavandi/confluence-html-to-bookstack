param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "bookstack-config.json"),
    [string]$ReadyDir,
    [string]$BookUrl,
    [string]$BookSlug,
    [switch]$Commit,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptVersion = "2026-05-06-link-fixer"

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

function ConvertTo-BookStackSlug {
    param([Parameter(Mandatory = $true)][string]$Name)

    $normalized = $Name.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()

    foreach ($char in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $plain = $builder.ToString().Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = [regex]::Replace($plain, "[^a-z0-9]+", "-").Trim("-")

    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "page"
    }

    return $slug
}

function Get-PageIdFromFileName {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($stem -match "_(?<id>\d+)$") {
        return $matches["id"]
    }

    if ($stem -match "^\d+$") {
        return $stem
    }

    return $null
}

function Get-HrefFragment {
    param([Parameter(Mandatory = $true)][string]$Href)

    $hashIndex = $Href.IndexOf("#")
    if ($hashIndex -lt 0) {
        return ""
    }

    return $Href.Substring($hashIndex)
}

function Remove-HrefQueryAndFragment {
    param([Parameter(Mandatory = $true)][string]$Href)

    $clean = $Href
    $hashIndex = $clean.IndexOf("#")
    if ($hashIndex -ge 0) {
        $clean = $clean.Substring(0, $hashIndex)
    }

    $queryIndex = $clean.IndexOf("?")
    if ($queryIndex -ge 0) {
        $clean = $clean.Substring(0, $queryIndex)
    }

    return $clean
}

function Get-ConfluencePageId {
    param([Parameter(Mandatory = $true)][string]$Href)

    if ($Href -match "(?i)/wiki/spaces/[^/]+/pages/(?<id>\d+)") {
        return $matches["id"]
    }

    if ($Href -match "(?i)/wiki/pages/viewpage\.action\?pageId=(?<id>\d+)") {
        return $matches["id"]
    }

    return $null
}

function Get-ResolvedLocalHtmlPath {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentDirectory,
        [Parameter(Mandatory = $true)][string]$Href
    )

    $clean = Remove-HrefQueryAndFragment -Href $Href
    if ($clean -notmatch "(?i)\.html$") {
        return $null
    }

    if ($clean -match "^(?i)(https?:|mailto:|data:)") {
        return $null
    }

    $decoded = [System.Uri]::UnescapeDataString($clean)
    $decoded = $decoded -replace "/", [System.IO.Path]::DirectorySeparatorChar

    if ([System.IO.Path]::IsPathRooted($decoded)) {
        return [System.IO.Path]::GetFullPath($decoded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $CurrentDirectory $decoded))
}

function New-TargetUrl {
    param(
        [Parameter(Mandatory = $true)]$Page,
        [string]$Fragment = ""
    )

    return "$($script:ResolvedBookUrl)/page/$($Page.Slug)$Fragment"
}

function Resolve-RewrittenHref {
    param(
        [Parameter(Mandatory = $true)][string]$Href,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory,
        [Parameter(Mandatory = $true)][hashtable]$PageById,
        [Parameter(Mandatory = $true)][hashtable]$PageByPath,
        [Parameter(Mandatory = $true)][hashtable]$PageByFileName
    )

    $decodedHref = [System.Net.WebUtility]::HtmlDecode($Href)

    if ($decodedHref -match "^(?i)(mailto:|data:|#)") {
        return $null
    }

    if ($decodedHref -match "(?i)/books/[^/]+/page/") {
        return $null
    }

    $fragment = Get-HrefFragment -Href $decodedHref
    $pageId = Get-ConfluencePageId -Href $decodedHref
    if (-not [string]::IsNullOrWhiteSpace($pageId)) {
        if ($PageById.ContainsKey($pageId)) {
            return [pscustomobject]@{
                NewHref = New-TargetUrl -Page $PageById[$pageId] -Fragment $fragment
                Reason  = "confluence-page-id"
            }
        }

        return [pscustomobject]@{
            NewHref = $null
            Reason  = "missing-page-id:$pageId"
        }
    }

    $localPath = Get-ResolvedLocalHtmlPath -CurrentDirectory $CurrentDirectory -Href $decodedHref
    if ($null -ne $localPath) {
        $pathKey = $localPath.ToLowerInvariant()
        if ($PageByPath.ContainsKey($pathKey)) {
            return [pscustomobject]@{
                NewHref = New-TargetUrl -Page $PageByPath[$pathKey] -Fragment $fragment
                Reason  = "local-html-path"
            }
        }

        $fileName = [System.IO.Path]::GetFileName($localPath).ToLowerInvariant()
        if ($PageByFileName.ContainsKey($fileName)) {
            $matches = @($PageByFileName[$fileName])
            if ($matches.Count -eq 1) {
                return [pscustomobject]@{
                    NewHref = New-TargetUrl -Page $matches[0] -Fragment $fragment
                    Reason  = "local-html-filename"
                }
            }

            return [pscustomobject]@{
                NewHref = $null
                Reason  = "ambiguous-local-html:$fileName"
            }
        }
    }

    return $null
}

$config = Read-BookStackConfig -Path $ConfigPath

if (-not $PSBoundParameters.ContainsKey("ReadyDir")) {
    $ReadyDir = Get-ConfigValue -Config $config -Name "ReadyDir"
}
if (-not $PSBoundParameters.ContainsKey("BookUrl")) {
    $BookUrl = Get-ConfigValue -Config $config -Name "BookUrl"
}
if (-not $PSBoundParameters.ContainsKey("BookSlug")) {
    $BookSlug = Get-ConfigValue -Config $config -Name "BookSlug"
}

if ([string]::IsNullOrWhiteSpace($ReadyDir) -or -not (Test-Path -LiteralPath $ReadyDir -PathType Container)) {
    throw "ReadyDir not found: $ReadyDir"
}
if ([string]::IsNullOrWhiteSpace($BookUrl)) {
    $baseUrl = Get-ConfigValue -Config $config -Name "BaseUrl"
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($BookSlug)) {
        throw "Set BookUrl or BaseUrl + BookSlug in $ConfigPath."
    }

    $BookUrl = "$($baseUrl.TrimEnd("/"))/books/$BookSlug"
}

$script:ResolvedBookUrl = $BookUrl.TrimEnd("/")

$htmlFiles = @(Get-ChildItem -LiteralPath $ReadyDir -Recurse -Filter "*.html" -File | Sort-Object FullName)
if ($htmlFiles.Count -eq 0) {
    Write-Host "No HTML files found under ReadyDir: $ReadyDir"
    exit 0
}

$pageById = @{}
$pageByPath = @{}
$pageByFileName = @{}
$warnings = New-Object System.Collections.Generic.List[string]

foreach ($file in $htmlFiles) {
    $pageName = Convert-FileNameToPageName -FileName $file.Name
    $pageId = Get-PageIdFromFileName -FileName $file.Name
    $page = [pscustomobject]@{
        Id           = $pageId
        Name         = $pageName
        Slug         = ConvertTo-BookStackSlug -Name $pageName
        FullName     = $file.FullName
        RelativePath = $file.FullName.Substring($ReadyDir.Length).TrimStart("\", "/")
    }

    if (-not [string]::IsNullOrWhiteSpace($pageId)) {
        if ($pageById.ContainsKey($pageId)) {
            $warnings.Add("Duplicate page ID $pageId found: $($page.RelativePath)")
        }
        else {
            $pageById[$pageId] = $page
        }
    }

    $pageByPath[$file.FullName.ToLowerInvariant()] = $page

    $fileKey = $file.Name.ToLowerInvariant()
    if (-not $pageByFileName.ContainsKey($fileKey)) {
        $pageByFileName[$fileKey] = @()
    }
    $pageByFileName[$fileKey] = @($pageByFileName[$fileKey]) + $page
}

$hrefRegex = [regex]"(?i)\bhref\s*=\s*(?<quote>[""'])(?<href>.*?)(\k<quote>)"
$stats = @{
    ChangedFiles    = 0
    RewrittenLinks  = 0
    UnresolvedLinks = 0
}
$details = New-Object System.Collections.Generic.List[string]
$backupDir = $null

if ($Commit -and -not $NoBackup) {
    $backupDir = Join-Path $ReadyDir ("_hyperlink_backup_{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

foreach ($file in $htmlFiles) {
    $original = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $fileState = @{
        Changed = $false
    }

    $updated = $hrefRegex.Replace($original, {
        param($match)

        $quote = $match.Groups["quote"].Value
        $href = $match.Groups["href"].Value
        $rewrite = Resolve-RewrittenHref `
            -Href $href `
            -CurrentDirectory $file.DirectoryName `
            -PageById $pageById `
            -PageByPath $pageByPath `
            -PageByFileName $pageByFileName

        if ($null -eq $rewrite) {
            return $match.Value
        }

        if ([string]::IsNullOrWhiteSpace($rewrite.NewHref)) {
            $stats["UnresolvedLinks"] = [int]$stats["UnresolvedLinks"] + 1
            $details.Add("UNRESOLVED | $($file.FullName.Substring($ReadyDir.Length).TrimStart('\', '/')) | $($rewrite.Reason) | $href")
            return $match.Value
        }

        $fileState["Changed"] = $true
        $stats["RewrittenLinks"] = [int]$stats["RewrittenLinks"] + 1
        $details.Add("REWRITE | $($file.FullName.Substring($ReadyDir.Length).TrimStart('\', '/')) | $($rewrite.Reason) | $href -> $($rewrite.NewHref)")
        return "href=$quote$($rewrite.NewHref)$quote"
    })

    if ($fileState["Changed"]) {
        $stats["ChangedFiles"] = [int]$stats["ChangedFiles"] + 1

        if ($Commit) {
            if ($null -ne $backupDir) {
                $relative = $file.FullName.Substring($ReadyDir.Length).TrimStart("\", "/")
                $backupPath = Join-Path $backupDir $relative
                $backupParent = Split-Path -Path $backupPath -Parent
                if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
                    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
                }
                Copy-Item -LiteralPath $file.FullName -Destination $backupPath -Force
            }

            Set-Content -LiteralPath $file.FullName -Value $updated -Encoding UTF8
        }
    }
}

$summaryPath = Join-Path $ReadyDir "hyperlink-fix-summary.txt"
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("BookStack hyperlink fix summary")
$summary.Add("Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
$summary.Add("Script version: $ScriptVersion")
$summary.Add("Mode: $(if ($Commit) { 'COMMIT' } else { 'DRY RUN' })")
$summary.Add("ReadyDir: $ReadyDir")
$summary.Add("BookUrl: $script:ResolvedBookUrl")
$summary.Add("HTML files scanned: $($htmlFiles.Count)")
$summary.Add("Known page IDs: $($pageById.Count)")
$summary.Add("Changed files: $($stats["ChangedFiles"])")
$summary.Add("Rewritten links: $($stats["RewrittenLinks"])")
$summary.Add("Unresolved internal links: $($stats["UnresolvedLinks"])")
if ($null -ne $backupDir) {
    $summary.Add("Backup folder: $backupDir")
}
$summary.Add("")

foreach ($warning in $warnings) {
    $summary.Add("WARNING | $warning")
}
foreach ($detail in $details) {
    $summary.Add($detail)
}

if ($Commit) {
    Set-Content -LiteralPath $summaryPath -Value $summary -Encoding UTF8
}
else {
    $summary | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
    if ($summary.Count -gt 80) {
        Write-Host "... $($summary.Count - 80) more summary lines omitted from console. Run with -Commit to write the full summary file."
    }
}

Write-Host ""
Write-Host "Done."
Write-Host "Mode: $(if ($Commit) { 'COMMIT' } else { 'DRY RUN' })"
Write-Host "HTML files scanned: $($htmlFiles.Count)"
Write-Host "Changed files: $($stats["ChangedFiles"])"
Write-Host "Rewritten links: $($stats["RewrittenLinks"])"
Write-Host "Unresolved internal links: $($stats["UnresolvedLinks"])"
if ($Commit) {
    Write-Host "Summary: $summaryPath"
}
else {
    Write-Host "No files changed. Add -Commit to rewrite hyperlinks."
}
