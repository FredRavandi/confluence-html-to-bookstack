# BookStack Confluence Import Tools

PowerShell utilities for converting a Confluence HTML space export into BookStack API-ready HTML, fixing internal links after manual organization, and importing the result into a BookStack book.

This project was built for a workflow where Confluence-exported pages are prepared locally, organized into folders that represent BookStack chapters, then uploaded through the BookStack REST API.

## What This Does

- Extracts useful page body HTML from Confluence export files.
- Embeds local Confluence attachment images as `data:image/...;base64,...` so pages can be imported as self-contained HTML.
- Lets you manually organize prepared HTML files into folders before import.
- Converts immediate subfolders under the ready folder into BookStack chapters.
- Rewrites Confluence-origin hyperlinks to BookStack page URLs before import.
- Imports pages into a configured BookStack book via API.

## Folder Layout

Recommended project layout:

```text
Bookstack/
  API/
    bookstack-config.example.json
    bookstack-config.json              # local only, ignored by git
    _1_prepare-confluence-html-for-bookstack.ps1
    _2_fix-bookstack-hyperlinks.ps1
    _3_import-ready-bookstack.ps1
  API_ReadyforImport/                  # generated/organized output, ignored by git
  Confluence-space-export-*.html/       # raw Confluence exports, ignored by git
  AGENT.md                            # local agent notes, ignored by git
  README.md
  .gitignore
```

## Configuration

Copy the example config and fill in your own values:

```powershell
Copy-Item .\API\bookstack-config.example.json .\API\bookstack-config.json
```

Required config fields:

- `BaseUrl`: BookStack base URL, for example `https://bookstack.example.com`.
- `BookUrl`: Full URL to the target book, for example `https://bookstack.example.com/books/my-book`.
- `BookSlug`: Target BookStack book slug.
- `TokenId`: BookStack API token ID.
- `TokenSecret`: BookStack API token secret.
- `ReadyDir`: Folder containing prepared and organized HTML files.
- `SourceDir`: Original Confluence HTML export folder.
- `WriteClient`: Usually `Curl`, which is more reliable for large HTML/image payloads.
- `DeleteAfterImport`: Use `false` for first runs. Use `true` only when you are comfortable deleting successfully imported HTML files.

Do not commit `bookstack-config.json`; it contains secrets and local paths.

## Workflow

Run commands from the project root.

### 1. Prepare Confluence HTML

Convert a Confluence export folder into BookStack-ready HTML:

```powershell
.\API\_1_prepare-confluence-html-for-bookstack.ps1 `
  -InputPath "C:\Path\To\Confluence-space-export.html\YourSpace" `
  -OutputDir "C:\Path\To\Bookstack\API_ReadyforImport"
```

The script:

- extracts `<div id="main-content">` where available,
- removes scripts/styles/comments,
- embeds local images from Confluence `attachments`,
- writes `conversion-summary.txt`.

### 2. Organize Files

Manually arrange the generated HTML files:

```text
API_ReadyforImport/
  Page-at-book-root.html
  Chapter Name/
    Page-in-that-chapter.html
```

Import behavior:

- HTML files directly in `ReadyDir` become book-level pages.
- Immediate subfolders become BookStack chapters.
- HTML files inside a subfolder become pages in that chapter.

### 3. Fix Hyperlinks

Dry-run first:

```powershell
.\API\_2_fix-bookstack-hyperlinks.ps1
```

Apply changes:

```powershell
.\API\_2_fix-bookstack-hyperlinks.ps1 -Commit
```

The script rewrites:

- Confluence page URLs such as `/wiki/spaces/.../pages/123456789/...`
- local `.html` links between exported pages

to BookStack page URLs under the configured `BookUrl`.

When run with `-Commit`, it creates a `_hyperlink_backup_yyyyMMdd-HHmmss` folder unless `-NoBackup` is provided. It also writes `hyperlink-fix-summary.txt`.

### 4. Dry-Run Import

```powershell
.\API\_3_import-ready-bookstack.ps1
```

This checks the target book and prints what would be created or updated.

### 5. Import

Create new pages/chapters:

```powershell
.\API\_3_import-ready-bookstack.ps1 -Commit
```

Update existing pages too:

```powershell
.\API\_3_import-ready-bookstack.ps1 -Commit -UpdateExisting
```

Run a tiny API test page:

```powershell
.\API\_3_import-ready-bookstack.ps1 -SmokeTest -Commit
```

Delete the smoke-test page manually in BookStack after confirming the API path works.

## Important Notes

- Keep `DeleteAfterImport` set to `false` until you have verified the import behavior.
- Rename numeric-only HTML files before running the hyperlink fixer/importer if you want readable BookStack page names and slugs.
- The hyperlink fixer only rewrites links it can map to files present under `ReadyDir`.
- Remote Confluence images that are not local attachments may remain as remote URLs. Those may not render for users without access to the source Confluence site.
- BookStack page names are derived from file names. A trailing Confluence page ID like `_3067805697` is removed.
- `---` in a file name becomes ` - ` in the BookStack page title.

## Public Repository Safety

Before publishing:

- Confirm `API/bookstack-config.json` is not committed.
- Confirm any old scripts with hardcoded tokens are not committed.
- Confirm generated HTML exports are not committed unless they are safe to publish.
- Review prepared HTML for internal company data before sharing publicly.

The included `.gitignore` is intentionally conservative to reduce accidental disclosure.


