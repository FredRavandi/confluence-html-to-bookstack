# Confluence HTML to BookStack

PowerShell tools to convert a Confluence HTML export into BookStack pages.

The scripts are numbered in the order you run them:

```text
API/
  _1_prepare-confluence-html-for-bookstack.ps1
  _2_fix-bookstack-hyperlinks.ps1
  _3_import-ready-bookstack.ps1
  bookstack-config.example.json
```

## What It Does

- Converts exported Confluence HTML pages into cleaner BookStack-ready HTML.
- Embeds local Confluence attachment images into the HTML.
- Lets you organize pages into folders before import.
- Converts folders into BookStack chapters.
- Fixes internal Confluence links after the files are organized.
- Imports the pages into BookStack through the BookStack API.

## Requirements

- PowerShell.
- A Confluence HTML space export.
- A BookStack API token.
- Access to the target BookStack book.

## Setup

Copy the example config:

```powershell
Copy-Item .\API\bookstack-config.example.json .\API\bookstack-config.json
```

Edit `API\bookstack-config.json` and set:

- `BaseUrl`
- `BookUrl`
- `BookSlug`
- `TokenId`
- `TokenSecret`
- `SourceDir`
- `ReadyDir`

Keep `DeleteAfterImport` set to `false` until you have tested the import.

Do not commit `bookstack-config.json`. It contains local paths and API secrets.

## Workflow

Run commands from the project root.

### 1. Prepare The HTML

```powershell
.\API\_1_prepare-confluence-html-for-bookstack.ps1 `
  -InputPath "C:\Path\To\ConfluenceExport\SpaceFolder" `
  -OutputDir "C:\Path\To\Bookstack\API_ReadyforImport"
```

This creates cleaned HTML files and embeds local attachment images.

### 2. Organize The Files

Arrange the prepared files before import:

```text
API_ReadyforImport/
  Root Page.html
  Chapter Name/
    Page In Chapter.html
```

Import rules:

- HTML files directly inside `ReadyDir` become pages at the book root.
- Immediate subfolders become BookStack chapters.
- HTML files inside a subfolder become pages inside that chapter.

### 3. Fix Internal Links

Dry run:

```powershell
.\API\_2_fix-bookstack-hyperlinks.ps1
```

Apply changes:

```powershell
.\API\_2_fix-bookstack-hyperlinks.ps1 -Commit
```

This rewrites Confluence page links and local `.html` links to BookStack page URLs.

### 4. Import To BookStack

Dry run:

```powershell
.\API\_3_import-ready-bookstack.ps1
```

Create pages and chapters:

```powershell
.\API\_3_import-ready-bookstack.ps1 -Commit
```

Update existing pages and chapters:

```powershell
.\API\_3_import-ready-bookstack.ps1 -Commit -UpdateExisting
```

## Notes

- File names become BookStack page names.
- A trailing Confluence page ID such as `_3067805697` is removed from the page name.
- `---` in a file name becomes ` - ` in the page name.
- The hyperlink fixer can only fix links to files that exist under `ReadyDir`.
- Very large pages with many embedded images may fail with HTTP `413`. Split the page or increase your BookStack/web server request size limit.
- Keep generated exports, prepared HTML, real configs, and backup scripts out of Git.

## Acknowledgement

This project was built with reference to the BookStack API and the BookStack API script examples:

https://codeberg.org/bookstack/api-scripts

This project is not officially affiliated with or supported by the BookStack project.
