# Build script for the Ximalaya LMS/Daphile plugin.
# Produces: dist/Ximalaya-<version>.zip (plugin dir at zip top level),
#           dist/Ximalaya-<version>.zip.sha1 and dist/repo.xml (ready for GitHub Pages).
#
# Usage:  pwsh -File build.ps1 [-Version 0.1.0]

param(
	[string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"

$pluginDir = Join-Path $PSScriptRoot "Ximalaya"
$distDir   = Join-Path $PSScriptRoot "dist"

if (-not (Test-Path $pluginDir)) {
	throw "plugin dir not found: $pluginDir"
}

# sanity: keep the version in install.xml in sync
$installXml = Get-Content (Join-Path $pluginDir "install.xml") -Raw
if ($installXml -notmatch [regex]::Escape("<version>$Version</version>")) {
	Write-Warning "install.xml version does not match -Version $Version (edit install.xml or pass -Version)"
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$zipPath = Join-Path $distDir "Ximalaya-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Staging keeps the zip free of junk and guarantees Ximalaya/ is the top level.
$stage = Join-Path $env:TEMP "ximalaya-build-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $pluginDir (Join-Path $stage "Ximalaya") -Recurse

# strip dev junk
Get-ChildItem (Join-Path $stage "Ximalaya") -Recurse -Include *.pm.bak,*.orig,*~,.DS_Store,Thumbs.db |
	Remove-Item -Force -ErrorAction SilentlyContinue

Compress-Archive -Path (Join-Path $stage "Ximalaya") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force

$sha = (Get-FileHash -Algorithm SHA1 $zipPath).Hash.ToLower()
Set-Content -Path "$zipPath.sha1" -Value $sha -NoNewline -Encoding ascii

# download URL placeholder - replace with the real GitHub Pages / raw URL when publishing
$downloadUrl = "https://YOUR_GITHUB_PAGES_HOST/Ximalaya-$Version.zip"

$repoXml = @"
<extensions>
	<details>
		<title>Ximalaya for LMS / Daphile (unofficial)</title>
		<desc>Unofficial Ximalaya (喜马拉雅) music service plugin. Personal use only; requires your own ximalaya.com login cookie. Not affiliated with Ximalaya Inc.</desc>
		<email>noreply@example.com</email>
	</details>
	<plugins>
		<plugin name="Ximalaya" version="$Version" minTarget="7.7" maxTarget="*" os="*">
			<title>PLUGIN_XIMALAYA</title>
			<desc>PLUGIN_XIMALAYA_DESC</desc>
			<url>$downloadUrl</url>
			<sha>$sha</sha>
			<creator>Ximalaya Plugin Project</creator>
			<category>musicservices</category>
			<email>noreply@example.com</email>
		</plugin>
	</plugins>
</extensions>
"@

Set-Content -Path (Join-Path $distDir "repo.xml") -Value $repoXml -Encoding UTF8

Write-Host ""
Write-Host "Built: $zipPath"
Write-Host "SHA1:  $sha"
Write-Host "Repo:  $(Join-Path $distDir 'repo.xml')  (edit the download URL before publishing)"
