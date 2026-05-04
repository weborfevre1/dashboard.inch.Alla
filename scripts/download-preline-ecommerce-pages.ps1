param(
  [string]$AssetRoot = "offline-assets",
  [string[]]$PageUrls = @(
    "https://preline.co/pro/ecommerce/products.html",
    "https://preline.co/pro/ecommerce/product-details.html",
    "https://preline.co/pro/ecommerce/add-product.html",
    "https://preline.co/pro/ecommerce/orders.html",
    "https://preline.co/pro/ecommerce/purchase-orders.html",
    "https://preline.co/pro/ecommerce/order-details.html",
    "https://preline.co/pro/ecommerce/reviews.html",
    "https://preline.co/pro/ecommerce/discounts.html",
    "https://preline.co/pro/ecommerce/store.html",
    "https://preline.co/pro/ecommerce/payouts.html",
    "https://preline.co/pro/ecommerce/search.html",
    "https://preline.co/pro/ecommerce/empty-states.html"
  )
)

$ErrorActionPreference = "Stop"

function Get-LocalHtmlNameFromUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url
  )

  $uri = [System.Uri]$Url
  $leafName = [System.IO.Path]::GetFileNameWithoutExtension($uri.AbsolutePath.TrimEnd("/"))

  if ([string]::IsNullOrWhiteSpace($leafName)) {
    $leafName = "index"
  }

  return "preline-ecommerce-$leafName.html"
}

function Save-RemoteHtml {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
  )

  $parent = Split-Path -Parent $DestinationPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $response = Invoke-WebRequest -UseBasicParsing -Uri $Url
  [System.IO.File]::WriteAllText($DestinationPath, $response.Content, [System.Text.UTF8Encoding]::new($false))
}

function Update-AnchorLinks {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$HtmlFiles,
    [Parameter(Mandatory = $true)]
    [hashtable]$PageMap
  )

  foreach ($htmlFile in $HtmlFiles) {
    $content = Get-Content -Raw -LiteralPath $htmlFile
    $updated = $false

    foreach ($sourceUrl in $PageMap.Keys) {
      $localFileName = $PageMap[$sourceUrl]
      $sourcePath = ([System.Uri]$sourceUrl).AbsolutePath
      $variants = @(
        $sourceUrl,
        $sourcePath,
        "../../$($sourcePath.TrimStart('/'))"
      ) | Select-Object -Unique

      foreach ($variant in $variants) {
        $escapedVariant = [System.Text.RegularExpressions.Regex]::Escape($variant)
        $pattern = '(<a\b[^>]*?\bhref=["''])' + $escapedVariant + '(["''])'
        $newContent = [System.Text.RegularExpressions.Regex]::Replace(
          $content,
          $pattern,
          ('$1' + $localFileName + '$2'),
          [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($newContent -ne $content) {
          $content = $newContent
          $updated = $true
        }
      }
    }

    if ($updated) {
      [System.IO.File]::WriteAllText($htmlFile, $content, [System.Text.UTF8Encoding]::new($false))
    }
  }
}

$rootPath = (Get-Location).Path
$mirrorScript = Join-Path $PSScriptRoot "mirror-preline-page-assets.ps1"
$normalizeScript = Join-Path $PSScriptRoot "normalize-offline-assets.ps1"
$localizeCssScript = Join-Path $PSScriptRoot "localize-css-urls.ps1"

if (-not (Test-Path -LiteralPath $mirrorScript)) {
  throw "Mirror script not found: $mirrorScript"
}

$downloadedPages = [System.Collections.Generic.List[string]]::new()
$pageMap = @{}

foreach ($pageUrl in $PageUrls) {
  $localFileName = Get-LocalHtmlNameFromUrl -Url $pageUrl
  $localFilePath = Join-Path $rootPath $localFileName

  Save-RemoteHtml -Url $pageUrl -DestinationPath $localFilePath
  & $mirrorScript -HtmlPath $localFileName -SourcePageUrl $pageUrl -AssetRoot $AssetRoot -SkipPostProcess | Out-Null

  $downloadedPages.Add($localFileName)
  $pageMap[$pageUrl] = $localFileName
}

$indexFileName = "preline-ecommerce-index.html"
$indexFilePath = Join-Path $rootPath $indexFileName
if (Test-Path -LiteralPath $indexFilePath) {
  $pageMap["https://preline.co/pro/ecommerce/index.html"] = $indexFileName
  $downloadedPages.Add($indexFileName)
}

$allLocalPages = $downloadedPages | Sort-Object -Unique

if (Test-Path -LiteralPath $normalizeScript) {
  foreach ($htmlFile in $allLocalPages) {
    & $normalizeScript -HtmlPath $htmlFile -AssetRoot $AssetRoot | Out-Null
  }
}

if (Test-Path -LiteralPath $localizeCssScript) {
  & $localizeCssScript -AssetRoot $AssetRoot | Out-Null
}

if (Test-Path -LiteralPath $normalizeScript) {
  foreach ($htmlFile in $allLocalPages) {
    & $normalizeScript -HtmlPath $htmlFile -AssetRoot $AssetRoot | Out-Null
  }
}

$fullHtmlPaths = $allLocalPages | ForEach-Object { Join-Path $rootPath $_ }
Update-AnchorLinks -HtmlFiles $fullHtmlPaths -PageMap $pageMap

[pscustomobject]@{
  DownloadedPageCount = ($PageUrls | Measure-Object).Count
  LocalHtmlFiles = ($allLocalPages -join ", ")
  AssetRoot = [System.IO.Path]::GetFullPath((Join-Path $rootPath $AssetRoot))
} | Format-List
