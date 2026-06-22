$private = Get-ChildItem -Path "$PSScriptRoot\Functions\Private" -Filter '*.ps1' -ErrorAction SilentlyContinue
$public  = Get-ChildItem -Path "$PSScriptRoot\Functions\Public"  -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in ($private + $public)) {
    . $file.FullName
}

# A public .ps1 file's BaseName does not necessarily match the function(s) it
# defines (e.g. AffinityRules.ps1 defines six functions) — parse each file's AST
# to find the actual top-level function names to export.
$publicFunctionNames = foreach ($file in $public) {
    $tokens = $null
    $errors = $null
    $ast    = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        Select-Object -ExpandProperty Name
}

Export-ModuleMember -Function $publicFunctionNames
