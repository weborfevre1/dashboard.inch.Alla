param(
  [string]$AssetRoot = "offline-assets"
)

$ErrorActionPreference = "Stop"

function Get-ShortHash {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )

  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha1.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()).Substring(0, 10)
  }
  finally {
    $sha1.Dispose()
  }
}

function Get-LocalRelativePathForUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [Parameter(Mandatory = $true)]
    [string]$AssetRootDirectory
  )

  $uri = [System.Uri]$Url
  $hostName = $uri.Host.ToLowerInvariant()
  $trimmedPath = $uri.AbsolutePath.TrimStart("/")

  if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
    $trimmedPath = "index"
  }

  $directoryPart = [System.IO.Path]::GetDirectoryName($trimmedPath)
  $fileName = [System.IO.Path]::GetFileName($trimmedPath)

  if ([string]::IsNullOrWhiteSpace($fileName)) {
    $fileName = "index"
  }

  if (-not [System.IO.Path]::GetExtension($fileName)) {
    $fileName += ".bin"
  }

  if ($uri.Query) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $extension = [System.IO.Path]::GetExtension($fileName)
    $fileName = "{0}--q{1}{2}" -f $baseName, (Get-ShortHash $uri.Query), $extension
  }

  if ([string]::IsNullOrWhiteSpace($directoryPart)) {
    return [System.IO.Path]::Combine($AssetRootDirectory, $hostName, $fileName)
  }

  return [System.IO.Path]::Combine($AssetRootDirectory, $hostName, $directoryPart, $fileName)
}

function Get-RelativeReference {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FromFile,
    [Parameter(Mandatory = $true)]
    [string]$ToFile
  )

  $fromDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FromFile))
  $fromUri = [System.Uri]::new(($fromDirectory.TrimEnd("\") + "\"))
  $toUri = [System.Uri]::new([System.IO.Path]::GetFullPath($ToFile))

  return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString())
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
  )

  $parent = Split-Path -Parent $DestinationPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $DestinationPath
}

$rootPath = (Get-Location).Path
$assetRootFullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $AssetRoot))

if (-not (Test-Path -LiteralPath $assetRootFullPath)) {
  throw "Asset root not found: $assetRootFullPath"
}

$localizedReferenceCount = 0

$cssFiles = Get-ChildItem -Recurse -File -LiteralPath $assetRootFullPath -Filter *.css
foreach ($cssFile in $cssFiles) {
  $cssContent = Get-Content -Raw -LiteralPath $cssFile.FullName
  $replacements = [ordered]@{}

  $urlPattern = 'url\((?<quote>["'']?)(?<url>https?://[^"''\)]+)\k<quote>\)'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($cssContent, $urlPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $absoluteUrl = $match.Groups["url"].Value.Trim()
    if ($replacements.Contains($absoluteUrl)) {
      continue
    }

    $relativePath = Get-LocalRelativePathForUrl -Url $absoluteUrl -AssetRootDirectory $AssetRoot
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $relativePath))

    if (-not (Test-Path -LiteralPath $fullPath)) {
      Download-File -Url $absoluteUrl -DestinationPath $fullPath
    }

    $replacements[$absoluteUrl] = (Get-RelativeReference -FromFile $cssFile.FullName -ToFile $fullPath).Replace('\', '/')
  }

  $importPattern = '@import\s+(?:url\()?["'']?(?<url>https?://[^"''\)\s;]+)'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($cssContent, $importPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $absoluteUrl = $match.Groups["url"].Value.Trim()
    if ($replacements.Contains($absoluteUrl)) {
      continue
    }

    $relativePath = Get-LocalRelativePathForUrl -Url $absoluteUrl -AssetRootDirectory $AssetRoot
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $relativePath))

    if (-not (Test-Path -LiteralPath $fullPath)) {
      Download-File -Url $absoluteUrl -DestinationPath $fullPath
    }

    $replacements[$absoluteUrl] = (Get-RelativeReference -FromFile $cssFile.FullName -ToFile $fullPath).Replace('\', '/')
  }

  if ($replacements.Count -eq 0) {
    continue
  }

  foreach ($originalUrl in $replacements.Keys) {
    $escapedOriginal = [System.Text.RegularExpressions.Regex]::Escape($originalUrl)
    $replacementValue = $replacements[$originalUrl]
    $cssContent = [System.Text.RegularExpressions.Regex]::Replace($cssContent, $escapedOriginal, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacementValue })
    $localizedReferenceCount++
  }

  [System.IO.File]::WriteAllText($cssFile.FullName, $cssContent, [System.Text.UTF8Encoding]::new($false))
}

[pscustomobject]@{
  CssFilesScanned = $cssFiles.Count
  LocalizedReferences = $localizedReferenceCount
} | Format-List
