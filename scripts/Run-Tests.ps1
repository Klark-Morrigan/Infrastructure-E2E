<#
.SYNOPSIS
    Runs unit tests locally. Delegates to the shared runner in
    PowerShell-Common.

.EXAMPLE
    .\Run-Tests.ps1
#>

# Repo root is one level up now that this script lives under scripts\;
# PowerShell-Common is a sibling of the repo root, so two levels up from here.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '..', 'PowerShell-Common', '.github', `
    'actions', 'run-unit-tests', 'Run-Tests.ps1')) -TestsRoot $repoRoot
