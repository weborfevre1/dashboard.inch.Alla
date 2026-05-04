param(
  [string]$HtmlPath = "preline-ecommerce-index.html",
  [string]$SourcePageUrl = "https://preline.co/pro/ecommerce/index.html",
  [string]$AssetRoot = "offline-assets",
  [switch]$SkipPostProcess
)

$ErrorActionPreference = "Stop"
$script:MirrorWarnings = [System.Collections.Generic.List[string]]::new()

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

function Resolve-AbsoluteUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$Reference
  )

  if ([string]::IsNullOrWhiteSpace($Reference)) {
    return $null
  }

  $trimmed = $Reference.Trim()
  if ($trimmed.StartsWith("data:", [System.StringComparison]::OrdinalIgnoreCase) -or
      $trimmed.StartsWith("javascript:", [System.StringComparison]::OrdinalIgnoreCase) -or
      $trimmed.StartsWith("mailto:", [System.StringComparison]::OrdinalIgnoreCase) -or
      $trimmed.StartsWith("#")) {
    return $null
  }

  if ($trimmed.StartsWith("//")) {
    $baseUri = [System.Uri]$BaseUrl
    return "$($baseUri.Scheme):$trimmed"
  }

  try {
    return ([System.Uri]::new([System.Uri]$BaseUrl, $trimmed)).AbsoluteUri
  }
  catch {
    return $null
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

  $relativePath = if ([string]::IsNullOrWhiteSpace($directoryPart)) {
    [System.IO.Path]::Combine($AssetRootDirectory, $hostName, $fileName)
  }
  else {
    [System.IO.Path]::Combine($AssetRootDirectory, $hostName, $directoryPart, $fileName)
  }

  return $relativePath
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

  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $DestinationPath
  }
  catch {
    $statusCode = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }

    if ($statusCode -eq 404) {
      $extension = [System.IO.Path]::GetExtension($DestinationPath).ToLowerInvariant()
      switch ($extension) {
        ".svg" {
          [System.IO.File]::WriteAllText($DestinationPath, '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" viewBox="0 0 1 1"></svg>', [System.Text.UTF8Encoding]::new($false))
        }
        ".css" {
          [System.IO.File]::WriteAllText($DestinationPath, '/* upstream asset returned 404 */', [System.Text.UTF8Encoding]::new($false))
        }
        ".js" {
          [System.IO.File]::WriteAllText($DestinationPath, '/* upstream asset returned 404 */', [System.Text.UTF8Encoding]::new($false))
        }
        default {
          [System.IO.File]::WriteAllBytes($DestinationPath, [byte[]]@())
        }
      }

      $script:MirrorWarnings.Add("Used a placeholder for missing upstream asset: $Url")
      return
    }

    throw "Failed to download $Url -> $DestinationPath. $($_.Exception.Message)"
  }
}

function Get-HtmlAssetMatches {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Html,
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl
  )

  $results = [System.Collections.Generic.List[object]]::new()

  $linkPattern = '<link\b(?<tag>[^>]*?)\bhref=(?<quote>["''])(?<url>[^"'']+)\k<quote>(?<rest>[^>]*)>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $linkPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $fullTag = $match.Value
    $url = $match.Groups["url"].Value
    if ($fullTag -match '\brel=(["''])(?<rel>[^"'']+)\1' -and $Matches["rel"] -match '(stylesheet|icon|apple-touch-icon|preload)') {
      $absoluteUrl = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $url
      if ($absoluteUrl) {
        $results.Add([pscustomobject]@{
            Original = $url
            Absolute = $absoluteUrl
            Kind = "html"
          })
      }
    }
  }

  $scriptPattern = '<script\b[^>]*?\bsrc=(?<quote>["''])(?<url>[^"'']+)\k<quote>[^>]*>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $scriptPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $url = $match.Groups["url"].Value
    $absoluteUrl = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $url
    if ($absoluteUrl) {
      $results.Add([pscustomobject]@{
          Original = $url
          Absolute = $absoluteUrl
          Kind = "html"
        })
    }
  }

  $imgPattern = '<img\b[^>]*?\bsrc=(?<quote>["''])(?<url>[^"'']+)\k<quote>[^>]*>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $imgPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $url = $match.Groups["url"].Value
    $absoluteUrl = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $url
    if ($absoluteUrl) {
      $results.Add([pscustomobject]@{
          Original = $url
          Absolute = $absoluteUrl
          Kind = "html"
        })
    }
  }

  $srcsetPattern = '\bsrcset=(?<quote>["''])(?<url>[^"'']+)\k<quote>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $srcsetPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $value = $match.Groups["url"].Value
    foreach ($candidate in ($value -split ',')) {
      $parts = $candidate.Trim() -split '\s+'
      if ($parts.Count -gt 0) {
        $absoluteUrl = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $parts[0]
        if ($absoluteUrl) {
          $results.Add([pscustomobject]@{
              Original = $parts[0]
              Absolute = $absoluteUrl
              Kind = "html"
            })
        }
      }
    }
  }

  return $results
}

function Get-CssUrlMatches {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CssContent,
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl
  )

  $results = [System.Collections.Generic.List[object]]::new()

  $urlPattern = 'url\((?<quote>["'']?)(?<url>[^"''\)]+)\k<quote>\)'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($CssContent, $urlPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $original = $match.Groups["url"].Value.Trim()
    $absolute = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $original
    if ($absolute) {
      $results.Add([pscustomobject]@{
          Original = $original
          Absolute = $absolute
          Kind = "css"
        })
    }
  }

  $importPattern = '@import\s+(?:url\()?["'']?(?<url>[^"''\)\s;]+)'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($CssContent, $importPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $original = $match.Groups["url"].Value.Trim()
    $absolute = Resolve-AbsoluteUrl -BaseUrl $BaseUrl -Reference $original
    if ($absolute) {
      $results.Add([pscustomobject]@{
          Original = $original
          Absolute = $absolute
          Kind = "css"
        })
    }
  }

  return $results
}

$htmlFullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $HtmlPath))
$assetRootFullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $AssetRoot))

if (-not (Test-Path -LiteralPath $htmlFullPath)) {
  throw "HTML file not found: $htmlFullPath"
}

if (-not (Test-Path -LiteralPath $assetRootFullPath)) {
  New-Item -ItemType Directory -Path $assetRootFullPath -Force | Out-Null
}

$htmlContent = Get-Content -Raw -LiteralPath $htmlFullPath
$htmlAssetMatches = Get-HtmlAssetMatches -Html $htmlContent -BaseUrl $SourcePageUrl

$assetMap = [ordered]@{}
$downloadedUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$pendingCssUrls = [System.Collections.Generic.Queue[string]]::new()

foreach ($match in $htmlAssetMatches) {
  if (-not $assetMap.Contains($match.Absolute)) {
    $relativePath = Get-LocalRelativePathForUrl -Url $match.Absolute -AssetRootDirectory $AssetRoot
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $relativePath))
    $assetMap[$match.Absolute] = [pscustomobject]@{
      RelativePath = $relativePath
      FullPath = $fullPath
      Url = $match.Absolute
    }
  }
}

foreach ($asset in $assetMap.Values) {
  if ($downloadedUrls.Add($asset.Url)) {
    if (-not (Test-Path -LiteralPath $asset.FullPath)) {
      Download-File -Url $asset.Url -DestinationPath $asset.FullPath
    }

    if ([System.IO.Path]::GetExtension($asset.FullPath).Equals(".css", [System.StringComparison]::OrdinalIgnoreCase)) {
      $pendingCssUrls.Enqueue($asset.Url)
    }
  }
}

while ($pendingCssUrls.Count -gt 0) {
  $cssUrl = $pendingCssUrls.Dequeue()
  $cssAsset = $assetMap[$cssUrl]
  $cssContent = Get-Content -Raw -LiteralPath $cssAsset.FullPath
  $cssMatches = Get-CssUrlMatches -CssContent $cssContent -BaseUrl $cssUrl

  $replacements = [ordered]@{}
  foreach ($match in $cssMatches) {
    if (-not $assetMap.Contains($match.Absolute)) {
      $relativePath = Get-LocalRelativePathForUrl -Url $match.Absolute -AssetRootDirectory $AssetRoot
      $fullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $relativePath))
      $assetMap[$match.Absolute] = [pscustomobject]@{
        RelativePath = $relativePath
        FullPath = $fullPath
        Url = $match.Absolute
      }
    }

    $nestedAsset = $assetMap[$match.Absolute]
    if ($downloadedUrls.Add($nestedAsset.Url)) {
      if (-not (Test-Path -LiteralPath $nestedAsset.FullPath)) {
        Download-File -Url $nestedAsset.Url -DestinationPath $nestedAsset.FullPath
      }

      if ([System.IO.Path]::GetExtension($nestedAsset.FullPath).Equals(".css", [System.StringComparison]::OrdinalIgnoreCase)) {
        $pendingCssUrls.Enqueue($nestedAsset.Url)
      }
    }

    $replacements[$match.Original] = Get-RelativeReference -FromFile $cssAsset.FullPath -ToFile $nestedAsset.FullPath
  }

  foreach ($key in $replacements.Keys) {
    $escapedKey = [System.Text.RegularExpressions.Regex]::Escape($key)
    $replacementValue = $replacements[$key].Replace('\', '/')
    $cssContent = [System.Text.RegularExpressions.Regex]::Replace($cssContent, $escapedKey, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacementValue })
  }

  [System.IO.File]::WriteAllText($cssAsset.FullPath, $cssContent, [System.Text.UTF8Encoding]::new($false))
}

foreach ($match in $htmlAssetMatches) {
  $asset = $assetMap[$match.Absolute]
  $localReference = (Get-RelativeReference -FromFile $htmlFullPath -ToFile $asset.FullPath).Replace('\', '/')
  $escapedOriginal = [System.Text.RegularExpressions.Regex]::Escape($match.Original)
  $htmlContent = [System.Text.RegularExpressions.Regex]::Replace($htmlContent, $escapedOriginal, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $localReference })
}

[System.IO.File]::WriteAllText($htmlFullPath, $htmlContent, [System.Text.UTF8Encoding]::new($false))

if (-not $SkipPostProcess) {
  $normalizeScript = Join-Path $PSScriptRoot "normalize-offline-assets.ps1"
  if (Test-Path -LiteralPath $normalizeScript) {
    & $normalizeScript -HtmlPath $HtmlPath -AssetRoot $AssetRoot | Out-Null
  }

  $localizeCssScript = Join-Path $PSScriptRoot "localize-css-urls.ps1"
  if (Test-Path -LiteralPath $localizeCssScript) {
    & $localizeCssScript -AssetRoot $AssetRoot | Out-Null
  }
}

$report = [pscustomobject]@{
  HtmlFile = $htmlFullPath
  AssetRoot = $assetRootFullPath
  AssetCount = $assetMap.Count
  WarningCount = $script:MirrorWarnings.Count
}

$report | Format-List

if ($script:MirrorWarnings.Count -gt 0) {
  ""
  "Warnings:"
  $script:MirrorWarnings
}
