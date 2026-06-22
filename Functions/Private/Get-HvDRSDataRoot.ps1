function Get-HvDRSDataRoot {
    <#
    .SYNOPSIS
        Resolves the root directory HvDRS uses for its rule store and lock files.

    .DESCRIPTION
        $env:ProgramData is unset on non-Windows hosts (e.g. Linux/macOS used for
        module development and Pester runs). Falling back to the OS temp directory
        keeps default parameter values evaluable there without affecting production
        behavior on Windows Server, where $env:ProgramData is always defined.
    #>
    [CmdletBinding()]
    param()

    if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }
}
