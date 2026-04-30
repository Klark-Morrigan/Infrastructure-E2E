<#
.SYNOPSIS
    Runs unit tests locally. Delegates to the shared runner in
    Infrastructure-Common.

.EXAMPLE
    .\Run-Tests.ps1
#>

& ([IO.Path]::Combine($PSScriptRoot, '..', 'Infrastructure-Common', '.github', `
    'actions', 'run-unit-tests', 'Run-Tests.ps1')) -TestsRoot $PSScriptRoot
