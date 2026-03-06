#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$NewName,

    [Parameter(Position = 1)]
    [string]$OldName = 'Cameek.Ue.MyProject',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message)
    throw $Message
}

function Test-ValidProjectName {
    param([string]$Value)
    return $Value -match '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$'
}

function Normalize-PathValue {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Is-ExcludedPath {
    param([string]$Path)
    $fullPath = Normalize-PathValue $Path

    foreach ($excluded in $script:ExcludedRootPaths) {
        if ($fullPath.Equals($excluded, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        $directoryPrefix = $excluded + [System.IO.Path]::DirectorySeparatorChar
        $altDirectoryPrefix = $excluded + [System.IO.Path]::AltDirectorySeparatorChar

        if ($fullPath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($altDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-IsTextFile {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] 4096
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        $stream.Dispose()
    }

    if ($bytesRead -eq 0) {
        return $true
    }

    for ($i = 0; $i -lt $bytesRead; $i++) {
        if ($buffer[$i] -eq 0) {
            return $false
        }
    }

    return $true
}

function Read-TextFile {
    param([string]$Path)

    $reader = [System.IO.StreamReader]::new($Path, $true)
    try {
        $content = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding
    }
    finally {
        $reader.Dispose()
    }

    return [PSCustomObject]@{
        Content  = $content
        Encoding = $encoding
    }
}

function To-RelativePath {
    param([string]$Path)
    return [System.IO.Path]::GetRelativePath($script:RepoRoot, $Path)
}

if ([string]::IsNullOrWhiteSpace($NewName)) {
    Fail 'New name cannot be empty.'
}

if ([string]::IsNullOrWhiteSpace($OldName)) {
    Fail 'Old name cannot be empty.'
}

if ($NewName -eq $OldName) {
    Fail 'New name and old name are identical. Nothing to do.'
}

if ($NewName -match '[\\/:\*\?"<>\|]') {
    Fail 'New name cannot contain path separators or invalid filename characters.'
}

if (-not (Test-ValidProjectName $NewName)) {
    Fail 'New name must be a valid dotted C# identifier (for example: Acme.Ue.MyProject).'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoRoot = Normalize-PathValue (Join-Path $scriptDir '..')
Set-Location -LiteralPath $script:RepoRoot

$script:ExcludedRootPaths = @(
    '.git',
    'bin',
    'obj',
    '.vs',
    '.idea',
    'node_modules',
    '.scripts'
) | ForEach-Object {
    Normalize-PathValue (Join-Path $script:RepoRoot $_)
}

$contentUpdates = 0
$files = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Force -File
foreach ($file in $files) {
    if (Is-ExcludedPath $file.FullName) {
        continue
    }

    if (-not (Test-IsTextFile $file.FullName)) {
        continue
    }

    $fileData = Read-TextFile $file.FullName
    if (-not $fileData.Content.Contains($OldName)) {
        continue
    }

    $contentUpdates++
    if ($DryRun) {
        Write-Host "[DRY-RUN] update $(To-RelativePath $file.FullName)"
        continue
    }

    $updatedContent = $fileData.Content.Replace($OldName, $NewName)
    [System.IO.File]::WriteAllText($file.FullName, $updatedContent, $fileData.Encoding)
}

$pathRenames = 0
$renameCandidates = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Force |
    Where-Object { -not (Is-ExcludedPath $_.FullName) -and $_.Name.Contains($OldName) } |
    Sort-Object { $_.FullName.Length } -Descending

foreach ($item in $renameCandidates) {
    $newItemName = $item.Name.Replace($OldName, $NewName)
    if ($newItemName -eq $item.Name) {
        continue
    }

    $targetPath = Join-Path $item.DirectoryName $newItemName
    if (Test-Path -LiteralPath $targetPath) {
        Fail "Cannot rename $(To-RelativePath $item.FullName) to $(To-RelativePath $targetPath): target already exists."
    }

    $pathRenames++
    if ($DryRun) {
        Write-Host "[DRY-RUN] rename $(To-RelativePath $item.FullName) -> $(To-RelativePath $targetPath)"
        continue
    }

    Rename-Item -LiteralPath $item.FullName -NewName $newItemName
}

$alignmentRenames = 0
$rootProjects = Get-ChildItem -LiteralPath $script:RepoRoot -File -Filter '*.csproj' | Sort-Object Name
$rootSolutions = @(
    Get-ChildItem -LiteralPath $script:RepoRoot -File -Filter '*.sln'
    Get-ChildItem -LiteralPath $script:RepoRoot -File -Filter '*.slnx'
) | Sort-Object Name

if ($rootProjects.Count -eq 1 -and $rootSolutions.Count -gt 0) {
    $projectBaseName = [System.IO.Path]::GetFileNameWithoutExtension($rootProjects[0].Name)
    foreach ($solution in $rootSolutions) {
        $expectedSolutionName = "$projectBaseName$($solution.Extension)"
        if ($solution.Name -eq $expectedSolutionName) {
            continue
        }

        $targetSolutionPath = Join-Path $script:RepoRoot $expectedSolutionName
        if (Test-Path -LiteralPath $targetSolutionPath) {
            Fail "Cannot align solution name to $expectedSolutionName because it already exists."
        }

        $alignmentRenames++
        if ($DryRun) {
            Write-Host "[DRY-RUN] align $(To-RelativePath $solution.FullName) -> $expectedSolutionName"
            continue
        }

        Rename-Item -LiteralPath $solution.FullName -NewName $expectedSolutionName
    }
}

if (-not $DryRun) {
    $remainingContent = New-Object System.Collections.Generic.List[string]
    $remainingFiles = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Force -File
    foreach ($file in $remainingFiles) {
        if (Is-ExcludedPath $file.FullName) {
            continue
        }

        if (-not (Test-IsTextFile $file.FullName)) {
            continue
        }

        $fileData = Read-TextFile $file.FullName
        if ($fileData.Content.Contains($OldName)) {
            $remainingContent.Add((To-RelativePath $file.FullName))
        }
    }

    $remainingPaths = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Force |
        Where-Object { -not (Is-ExcludedPath $_.FullName) -and $_.Name.Contains($OldName) } |
        ForEach-Object { To-RelativePath $_.FullName }

    if ($remainingContent.Count -gt 0 -or $remainingPaths.Count -gt 0) {
        Write-Host 'Validation failed. Old name is still present.'

        if ($remainingContent.Count -gt 0) {
            Write-Host 'Files with remaining content references:'
            foreach ($file in $remainingContent) {
                Write-Host "  - $file"
            }
        }

        if ($remainingPaths.Count -gt 0) {
            Write-Host 'Paths that still contain old name:'
            foreach ($path in $remainingPaths) {
                Write-Host "  - $path"
            }
        }

        exit 2
    }
}

if ($DryRun) {
    Write-Host "Dry-run complete. Files to update: $contentUpdates, paths to rename: $pathRenames, aligned solution names: $alignmentRenames."
}
else {
    Write-Host "Rename complete. Updated files: $contentUpdates, renamed paths: $pathRenames, aligned solution names: $alignmentRenames."
}

$repoFolderName = Split-Path -Leaf $script:RepoRoot
if ($repoFolderName.Contains($OldName)) {
    Write-Host "Note: repository directory still contains '$OldName'. Rename the folder manually if needed."
}
