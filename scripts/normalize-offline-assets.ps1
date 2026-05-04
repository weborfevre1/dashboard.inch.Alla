param(
  [string]$HtmlPath = "preline-ecommerce-index.html",
  [string]$AssetRoot = "offline-assets"
)

$ErrorActionPreference = "Stop"

function Get-RelativeToRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$FullPath
  )

  $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd("\")
  $full = [System.IO.Path]::GetFullPath($FullPath)

  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside the root: $full"
  }

  return $full.Substring($root.Length).TrimStart("\").Replace("\", "/")
}

function Get-DetectedExtension {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 12) {
    if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) {
      return ".jpg"
    }

    if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
      return ".png"
    }

    if ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x38) {
      return ".gif"
    }

    if ($bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x46 -and
        $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x45 -and $bytes[10] -eq 0x42 -and $bytes[11] -eq 0x50) {
      return ".webp"
    }

    if ($bytes[4] -eq 0x66 -and $bytes[5] -eq 0x74 -and $bytes[6] -eq 0x79 -and $bytes[7] -eq 0x70) {
      $brand = [System.Text.Encoding]::ASCII.GetString($bytes, 8, [Math]::Min(4, $bytes.Length - 8))
      if ($brand -like "avif") {
        return ".avif"
      }
      if ($brand -like "heic" -or $brand -like "heix" -or $brand -like "mif1") {
        return ".heic"
      }
    }
  }

  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x77 -and $bytes[1] -eq 0x4F -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x32) {
    return ".woff2"
  }

  $sampleLength = [Math]::Min($bytes.Length, 4096)
  if ($sampleLength -gt 0) {
    $sample = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $sampleLength)
    $trimmed = $sample.TrimStart()

    if ($trimmed.StartsWith("<svg", [System.StringComparison]::OrdinalIgnoreCase) -or
        $trimmed.StartsWith("<?xml", [System.StringComparison]::OrdinalIgnoreCase)) {
      return ".svg"
    }

    if ($sample -match '@font-face|font-family\s*:|url\(') {
      return ".css"
    }

    if ($sample -match 'window\.dataLayer|function\s+gtag|function\s*\(|var\s+|let\s+|const\s+|=>') {
      return ".js"
    }
  }

  if ($Path -like '*fonts.googleapis.com*') {
    return ".css"
  }

  if ($Path -like '*www.googletagmanager.com*') {
    return ".js"
  }

  if ($Path -like '*images.unsplash.com*') {
    return ".jpg"
  }

  return ".bin"
}

$rootPath = (Get-Location).Path
$htmlFullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $HtmlPath))
$assetRootFullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $AssetRoot))

if (-not (Test-Path -LiteralPath $htmlFullPath)) {
  throw "HTML file not found: $htmlFullPath"
}

if (-not (Test-Path -LiteralPath $assetRootFullPath)) {
  throw "Asset root not found: $assetRootFullPath"
}

$renameMap = [ordered]@{}
$binFiles = Get-ChildItem -Recurse -File -LiteralPath $assetRootFullPath -Filter *.bin

foreach ($file in $binFiles) {
  $newExtension = Get-DetectedExtension -Path $file.FullName
  if ($newExtension -eq ".bin") {
    continue
  }

  $destinationPath = [System.IO.Path]::ChangeExtension($file.FullName, $newExtension)
  if ($destinationPath -eq $file.FullName) {
    continue
  }

  if (Test-Path -LiteralPath $destinationPath) {
    Remove-Item -LiteralPath $destinationPath -Force
  }

  Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force

  $oldRelative = Get-RelativeToRoot -RootPath $rootPath -FullPath $file.FullName
  $newRelative = Get-RelativeToRoot -RootPath $rootPath -FullPath $destinationPath
  $renameMap[$oldRelative] = $newRelative
}

$textFiles = @($htmlFullPath)
$textFiles += Get-ChildItem -Recurse -File -LiteralPath $assetRootFullPath -Filter *.css | Select-Object -ExpandProperty FullName

foreach ($textFile in $textFiles) {
  $content = Get-Content -Raw -LiteralPath $textFile
  $changed = $false

  foreach ($oldRelative in $renameMap.Keys) {
    if ($content.Contains($oldRelative)) {
      $content = $content.Replace($oldRelative, $renameMap[$oldRelative])
      $changed = $true
    }
  }

  if ($changed) {
    [System.IO.File]::WriteAllText($textFile, $content, [System.Text.UTF8Encoding]::new($false))
  }
}

$report = [pscustomobject]@{
  RenamedCount = $renameMap.Count
  RemainingBinFiles = (Get-ChildItem -Recurse -File -LiteralPath $assetRootFullPath -Filter *.bin | Measure-Object).Count
}

$report | Format-List
