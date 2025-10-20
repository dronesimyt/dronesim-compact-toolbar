param(
  # Exactly as requested: 75 or 50
  [ValidateSet(75,50)][int]$ScalePercent = 75,

  # Where your (official) cookedcomps lives (can be a safe copy)
  [string]$CookedCompsRoot = "C:\XboxGames\Microsoft Flight Simulator 2024\Content\Packages\fs-base-ui\cookedcomps"
)

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Err($m){  Write-Host "[ERR ] $m" -ForegroundColor Red }

# ---------- Paths ----------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Join-Path $ScriptRoot "source"     # contains exactly ONE package folder
$TargetRoot = Join-Path $ScriptRoot "target"
$LayoutGen  = Join-Path $ScriptRoot "MSFSLayoutGenerator.exe"

# ---------- Validate base folders/tools ----------
if (-not (Test-Path $SourceRoot)) { Write-Err "Missing 'source' folder."; exit 1 }
$srcPkgs = Get-ChildItem -Path $SourceRoot -Directory
if ($srcPkgs.Count -ne 1) { Write-Err "Expected exactly one package folder in 'source'."; exit 1 }
$SourcePkg = $srcPkgs[0].FullName
$PkgName   = $srcPkgs[0].Name
Write-Info "Source package: $PkgName"

if (-not (Test-Path $CookedCompsRoot)) { Write-Err "CookedComps not found: $CookedCompsRoot"; exit 1 }
if (-not (Test-Path $LayoutGen))       { Write-Err "MSFSLayoutGenerator.exe must be next to this script."; exit 1 }

# ---------- Prepare target ----------
# (changed) build inside target\<PkgName>\ and its cookedcomps\
$TargetPkg = Join-Path $TargetRoot $PkgName
$cookedOut = Join-Path $TargetPkg "cookedcomps"

if (Test-Path $TargetRoot) { Remove-Item -Recurse -Force $TargetRoot }
New-Item -ItemType Directory -Force -Path $TargetPkg | Out-Null
New-Item -ItemType Directory -Force -Path $cookedOut  | Out-Null

# ---------- Copy manifest/layout from SOURCE to TARGET ----------
$srcManifest = Join-Path $SourcePkg "manifest.json"
$srcLayout   = Join-Path $SourcePkg "layout.json"
if (-not (Test-Path $srcManifest)) { Write-Err "manifest.json not found in source package."; exit 1 }
if (-not (Test-Path $srcLayout))   { Write-Err "layout.json not found in source package."; exit 1 }

# (changed) copy into target\<PkgName>\
Copy-Item -Force $srcManifest (Join-Path $TargetPkg "manifest.json")
Copy-Item -Force $srcLayout   (Join-Path $TargetPkg "layout.json")

# ---------- 1–2: find Panel_Toolbar file in cookedcomps ----------
$panelHtml = $null
Get-ChildItem -Path $CookedCompsRoot -Filter "*.html" | ForEach-Object {
  $t = Get-Content -Path $_.FullName -Raw
  if ($t -match 'name="Panel_Toolbar"') { $panelHtml = $_ }
}
if (-not $panelHtml) { Write-Err 'Could not find name="Panel_Toolbar" in cookedcomps'; exit 1 }

$panelHtmlPath = $panelHtml.FullName
$panelJsonPath = [IO.Path]::ChangeExtension($panelHtmlPath, ".json")
$panelGuid     = [IO.Path]::GetFileNameWithoutExtension($panelHtml.Name)  # includes braces
Write-Info "Base file: $($panelHtml.Name)  GUID: $panelGuid"

$fullHtml = Get-Content -Path $panelHtmlPath -Raw

# ---------- Helpers ----------
$sf    = [double]$ScalePercent / 100.0
$reOpt = [System.Text.RegularExpressions.RegexOptions]::Singleline
function ScaleNum([double]$n,[double]$f){ [math]::Round($n*$f,3).ToString('0.###') }

# ---------- 3) Scale all height: calc(var(--unscaledScreenHeight) * Npx / 1080) ----------
$reHeight = New-Object System.Text.RegularExpressions.Regex 'height:\s*calc\(\s*var\(--unscaledScreenHeight\)\s*\*\s*([0-9]+(?:\.[0-9]+)?)px\s*/\s*1080\s*\)', $reOpt
$fullHtml = $reHeight.Replace($fullHtml, {
  param($m)
  $n = [double]$m.Groups[1].Value
  $new = ScaleNum $n $sf
  "height: calc(var(--unscaledScreenHeight) * ${new}px / 1080)"
})

# ---------- 4) name="Toolbar_Trigger" → ensure style="opacity: 0" ----------
$reTriggerOpen = New-Object System.Text.RegularExpressions.Regex '(<ui-resource-element\b[^>]*name="Toolbar_Trigger"[^>]*)(>)', $reOpt
$reStyleAttr   = New-Object System.Text.RegularExpressions.Regex '\sstyle="[^"]*"', $reOpt
$fullHtml = $reTriggerOpen.Replace($fullHtml, {
  param($m)
  $start = $m.Groups[1].Value
  if ($reStyleAttr.IsMatch($start)) {
    $start = $reStyleAttr.Replace($start, {
      param($n)
      $val = $n.Value
      if ($val -match 'opacity:\s*[^;"]+') { $val = [regex]::Replace($val, 'opacity:\s*[^;"]+', 'opacity: 0') }
      else { $val = $val.TrimEnd('"') + '; opacity: 0"' }
      $val
    })
    return $start + $m.Groups[2].Value
  } else {
    return $start + ' style="opacity: 0"' + $m.Groups[2].Value
  }
}, 1)

# 5) Scale the "* 50px / 1080" inside the ToolBar top: calc(...) — robust, no $1/$2
$idx = $fullHtml.IndexOf('name="ToolBar"')
if ($idx -ge 0) {
  $sliceStart = $idx
  $sliceLen   = [Math]::Min(5000, $fullHtml.Length - $sliceStart)   # look ahead up to ~5k chars
  $slice      = $fullHtml.Substring($sliceStart, $sliceLen)

  $scaled50Txt = ([double](50 * $sf)).ToString([System.Globalization.CultureInfo]::InvariantCulture)

  $pattern = '(?is)(top\s*:\s*calc\(\s*var\(--v-anchor\)\s*\+\s*calc\(\s*var\(--unscaledScreenHeight\)\s*\*\s*)50(\s*px\s*/\s*1080\)\s*\)\s*;?)'

  $slice2 = [System.Text.RegularExpressions.Regex]::Replace(
    $slice,
    $pattern,
    { param($m) $m.Groups[1].Value + $scaled50Txt + $m.Groups[2].Value },
    1 # only the first occurrence after name="ToolBar"
  )

  if ($slice2 -ne $slice) {
    $fullHtml = $fullHtml.Remove($sliceStart, $sliceLen).Insert($sliceStart, $slice2)
  }
}

# 6) ONLY in name="IconButton_ToolBar": scale the numeric px in the width calc (robust)
$scaled50Txt = ([double](50 * $sf)).ToString([System.Globalization.CultureInfo]::InvariantCulture)

$rxIconOpen = New-Object System.Text.RegularExpressions.Regex '(?is)<ui-resource-element\b[^>]*name="IconButton_ToolBar"[^>]*>'
$fullHtml = $rxIconOpen.Replace($fullHtml, {
  param($m)
  $tag = $m.Value
  $tag2 = [System.Text.RegularExpressions.Regex]::Replace(
    $tag,
    '(?is)(width\s*:\s*calc\(\s*var\(--unscaledScreenHeight\)\s*\*\s*)([0-9]+(?:\.[0-9]+)?)(\s*px\s*/\s*1080\)\s*;?)',
    { param($n) $n.Groups[1].Value + $scaled50Txt + $n.Groups[3].Value },
    1  # only the first width calc in that opening tag
  )
  return $tag2
}, 1)  # only the first IconButton_ToolBar opening tag

# ---------- 7) Write HTML + JSON into target\<PkgName>\cookedcomps ----------
$outHtml = Join-Path $cookedOut ($panelHtml.Name)   # {GUID}.html
[System.IO.File]::WriteAllText($outHtml, $fullHtml, [System.Text.Encoding]::UTF8)

if (Test-Path $panelJsonPath) {
  Copy-Item -Force $panelJsonPath (Join-Path $cookedOut ([IO.Path]::GetFileName($panelJsonPath)))
}

# ---------- 8) Run MSFSLayoutGenerator in target\<PkgName> ----------
Copy-Item -Force $LayoutGen (Join-Path $TargetPkg "MSFSLayoutGenerator.exe")

Push-Location $TargetPkg
try {
  & .\MSFSLayoutGenerator.exe .\layout.json | Out-Null
} finally {
  Pop-Location
}

# ---------- 9) Done ----------
Write-Info "Done."
Write-Info "Target package: $TargetPkg"
Write-Info "  cookedcomps\$(Split-Path $outHtml -Leaf)"
if (Test-Path $panelJsonPath) { Write-Info "  cookedcomps\$(Split-Path ([IO.Path]::GetFileName($panelJsonPath)) -Leaf)" }
Write-Info "  layout.json (copied from source, regenerated by MSFSLayoutGenerator)"
Write-Info "  manifest.json (copied from source)"
Write-Info "  MSFSLayoutGenerator.exe"
