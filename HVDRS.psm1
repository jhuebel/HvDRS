$private = Get-ChildItem -Path "$PSScriptRoot\Functions\Private" -Filter '*.ps1' -ErrorAction SilentlyContinue
$public  = Get-ChildItem -Path "$PSScriptRoot\Functions\Public"  -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in ($private + $public)) {
    . $file.FullName
}

Export-ModuleMember -Function ($public | Select-Object -ExpandProperty BaseName)
