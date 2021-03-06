﻿<# 
 .Parameter artifactUrl
  Url for application artifact to use
 .Parameter imageName
  Name of the image getting build. Default is myimage:latest.
 .Parameter baseImage
  BaseImage to use. Default is using Get-BestGenericImage to get the best generic image to use.
 .Parameter isolation
  Isolation mode for the image build process (default is process if baseImage OS matches host OS)
 .Parameter memory
  Memory allocated for building image. 8G is default.
 .Parameter myScripts
  This allows you to specify a number of scripts you want to copy to the c:\run\my folder in the container (override functionality)
#>
function New-NavImage {
    Param (
        [string] $artifactUrl,
        [string] $imageName = "myimage:latest",
        [string] $baseImage = "",
        [ValidateSet('','process','hyperv')]
        [string] $isolation = "",
        [string] $memory = "",
        $myScripts = @()
    )

    if ($memory -eq "") {
        $memory = "4G"
    }

    $myScripts | ForEach-Object {
        if ($_ -is [string]) {
            if ($_.StartsWith("https://", "OrdinalIgnoreCase") -or $_.StartsWith("http://", "OrdinalIgnoreCase")) {
            } elseif (!(Test-Path $_)) {
                throw "Script directory or file $_ does not exist"
            }
        } elseif ($_ -isnot [Hashtable]) {
            throw "Illegal value in myScripts"
        }
    }

    $os = (Get-CimInstance Win32_OperatingSystem)
    if ($os.OSType -ne 18 -or !$os.Version.StartsWith("10.0.")) {
        throw "Unknown Host Operating System"
    }
    $UBR = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR).UBR
    
    $hostOsVersion = [System.Version]::Parse("$($os.Version).$UBR")
    $hostOs = "Unknown/Insider build"
    $bestGenericImageName = Get-BestGenericImageName -onlyMatchingBuilds

    if ($os.BuildNumber -eq 19041) { 
        $hostOs = "2004"
    }
    elseif ($os.BuildNumber -eq 18363) { 
        $hostOs = "1909"
    }
    elseif ($os.BuildNumber -eq 18362) { 
        $hostOs = "1903"
    }
    elseif ($os.BuildNumber -eq 17763) { 
        $hostOs = "ltsc2019"
    }
    elseif ($os.BuildNumber -eq 17134) { 
        $hostOs = "1803"
    }
    elseif ($os.BuildNumber -eq 16299) { 
        $hostOs = "1709"
    }
    elseif ($os.BuildNumber -eq 15063) {
        $hostOs = "1703"
    }
    elseif ($os.BuildNumber -eq 14393) {
        $hostOs = "ltsc2016"
    }

    if ("$baseImage" -eq "") {
        $baseImage = $bestGenericImageName
        if ("$baseImage" -eq "") {
            throw "Unable to find matching generic image for your host OS. You must pull and specify baseImage manually."
        }
    }
    Write-Host "Pulling latest image $baseImage"
    DockerDo -command pull -imageName $baseImage | Out-Null

    $genericTag = [Version](Get-NavContainerGenericTag -containerOrImageName $baseImage)
    Write-Host "Generic Tag: $genericTag"
    if ($genericTag -lt [Version]"0.1.0.1") {
        throw "Generic tag must be at least 0.1.0.1. Cannot build image based on $genericTag"
    }

    $containerOsVersion = [Version](Get-NavContainerOsVersion -containerOrImageName $baseImage)
    if ("$containerOsVersion".StartsWith('10.0.14393.')) {
        $containerOs = "ltsc2016"
        if (!$useBestContainerOS -and $TimeZoneId -eq $null) {
            $timeZoneId = (Get-TimeZone).Id
        }
    }
    elseif ("$containerOsVersion".StartsWith('10.0.15063.')) {
        $containerOs = "1703"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.16299.')) {
        $containerOs = "1709"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.17134.')) {
        $containerOs = "1803"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.17763.')) {
        $containerOs = "ltsc2019"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.18362.')) {
        $containerOs = "1903"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.18363.')) {
        $containerOs = "1909"
    }
    elseif ("$containerOsVersion".StartsWith('10.0.19041.')) {
        $containerOs = "2004"
    }
    else {
        $containerOs = "unknown"
    }
    Write-Host "Container OS Version: $containerOsVersion ($containerOs)"
    Write-Host "Host OS Version: $hostOsVersion ($hostOs)"

    if (($hostOsVersion.Major -lt $containerOsversion.Major) -or 
        ($hostOsVersion.Major -eq $containerOsversion.Major -and $hostOsVersion.Minor -lt $containerOsversion.Minor) -or 
        ($hostOsVersion.Major -eq $containerOsversion.Major -and $hostOsVersion.Minor -eq $containerOsversion.Minor -and $hostOsVersion.Build -lt $containerOsversion.Build)) {

        throw "The container operating system is newer than the host operating system, cannot use image"
    
    }

    if ($hostOsVersion -eq $containerOsVersion) {
        if ($isolation -eq "") { $isolation = "process" }
    }
    else {
        if ($isolation -eq "") {
            $isolation = "hyperv"
        }
        elseif ($isolation -eq "process") {
            Write-Host "WARNING: Host OS and Base Image Container OS doesn't match and process isolation is specified. If you encounter issues, please try hyperv instead."
        }
    }

    $downloadsPath = "c:\bcartifacts.cache"
    if (!(Test-Path $downloadsPath)) {
        New-Item $downloadsPath -ItemType Directory | Out-Null
    }

    $buildFolder = "c:\$('$TMP$')-$($imageName -replace '[:/]', '-')"
    if (Test-Path $buildFolder) {
        Remove-Item $buildFolder -Force -Recurse
    }
    New-Item $buildFolder -ItemType Directory | Out-Null

    try {

        $myFolder = Join-Path $buildFolder "my"
        new-Item -Path $myFolder -ItemType Directory | Out-Null
    
        $myScripts | ForEach-Object {
            if ($_ -is [string]) {
                if ($_.StartsWith("https://", "OrdinalIgnoreCase") -or $_.StartsWith("http://", "OrdinalIgnoreCase")) {
                    $uri = [System.Uri]::new($_)
                    $filename = [System.Uri]::UnescapeDataString($uri.Segments[$uri.Segments.Count-1])
                    $destinationFile = Join-Path $myFolder $filename
                    Download-File -sourceUrl $_ -destinationFile $destinationFile
                    if ($destinationFile.EndsWith(".zip", "OrdinalIgnoreCase")) {
                        Write-Host "Extracting .zip file"
                        Expand-Archive -Path $destinationFile -DestinationPath $myFolder
                        Remove-Item -Path $destinationFile -Force
                    }
                } elseif (Test-Path $_ -PathType Container) {
                    Copy-Item -Path "$_\*" -Destination $myFolder -Recurse -Force
                } else {
                    if ($_.EndsWith(".zip", "OrdinalIgnoreCase")) {
                        Expand-Archive -Path $_ -DestinationPath $myFolder
                    } else {
                        Copy-Item -Path $_ -Destination $myFolder -Force
                    }
                }
            } else {
                $hashtable = $_
                $hashtable.Keys | ForEach-Object {
                    Set-Content -Path (Join-Path $myFolder $_) -Value $hashtable[$_]
                }
            }
        }

        $artifactPaths = Download-Artifacts -artifactUrl $artifactUrl -includePlatform
        $appArtifactPath = $artifactPaths[0]
        $platformArtifactPath = $artifactPaths[1]

        $appManifestPath = Join-Path $appArtifactPath "manifest.json"
        $appManifest = Get-Content $appManifestPath | ConvertFrom-Json

        $isBcSandbox = "N"
        if ($appManifest.PSObject.Properties.name -eq "isBcSandbox") {
            if ($appManifest.isBcSandbox) {
                $IsBcSandbox = "Y"
            }
        }

        $database = $appManifest.database
        $databasePath = Join-Path $appArtifactPath $database
        $licenseFile = ""
        if ($appManifest.PSObject.Properties.name -eq "licenseFile") {
            $licenseFile = $appManifest.licenseFile
            if ($licenseFile) {
                $licenseFilePath = Join-Path $appArtifactPath $licenseFile
            }
        }
        $nav = ""
        if ($appManifest.PSObject.Properties.name -eq "Nav") {
            $nav = $appManifest.Nav
        }
        $cu = ""
        if ($appManifest.PSObject.Properties.name -eq "Cu") {
            $cu = $appManifest.Cu
        }
    
        $navDvdPath = Join-Path $buildFolder "NAVDVD"
        New-Item $navDvdPath -ItemType Directory | Out-Null

        Write-Host "Copying Platform Artifacts"
        Get-ChildItem -Path $platformArtifactPath | % {
            if ($_.PSIsContainer) {
                Copy-Item -Path $_.FullName -Destination $navDvdPath -Recurse
            }
            else {
                Copy-Item -Path $_.FullName -Destination $navDvdPath
            }
        }

        $dbPath = Join-Path $navDvdPath "SQLDemoDatabase\CommonAppData\Microsoft\Microsoft Dynamics NAV\ver\Database"
        New-Item $dbPath -ItemType Directory | Out-Null
        Write-Host "Copy Database"
        Copy-Item -path $databasePath -Destination $dbPath -Force
        if ($licenseFile) {
            Write-Host "Copy Licensefile"
            Copy-Item -path $licenseFilePath -Destination $dbPath -Force
        }

        "Installers", "ConfigurationPackages", "TestToolKit", "UpgradeToolKit", "Extensions", "Applications","Applications.*" | % {
            $appSubFolder = Join-Path $appArtifactPath $_
            if (Test-Path "$appSubFolder" -PathType Container) {
                $destFolder = Join-Path $navDvdPath $_
                if (Test-Path $destFolder) {
                    Remove-Item -path $destFolder -Recurse -Force
                }
                Write-Host "Copy $_"
                Copy-Item -Path "$appSubFolder" -Destination $navDvdPath -Recurse
            }
        }
    
        docker images --format "{{.Repository}}:{{.Tag}}" | % { 
            if ($_ -eq $imageName) 
            {
                docker rmi $imageName -f
            }
        }

        Write-Host $buildFolder

@"
FROM $baseimage

ENV DatabaseServer=localhost DatabaseInstance=SQLEXPRESS DatabaseName=CRONUS IsBcSandbox=$isBcSandbox artifactUrl=$artifactUrl

COPY my /run/
COPY NAVDVD /NAVDVD/

RUN \Run\start.ps1 -installOnly

LABEL legal="http://go.microsoft.com/fwlink/?LinkId=837447" \
      created="$([DateTime]::Now.ToUniversalTime().ToString("yyyyMMddHHmm"))" \
      nav="$nav" \
      cu="$cu" \
      country="$($appManifest.Country)" \
      version="$($appmanifest.Version)" \
      platform="$($appManifest.Platform)"
"@ | Set-Content (Join-Path $buildFolder "DOCKERFILE")

docker build --isolation=$isolation --memory $memory --tag $imageName $buildFolder

    }
    finally {
        Remove-Item $buildFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Set-Alias -Name New-BCImage -Value New-NavImage
Export-ModuleMember -Function New-NavImage -Alias New-BCImage
