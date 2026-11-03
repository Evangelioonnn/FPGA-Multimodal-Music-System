$ErrorActionPreference = 'Stop'
$ddLabRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ddPackageRoot = [System.IO.Path]::GetFullPath((Join-Path $ddLabRoot '../..'))
$ddOriginal = [System.IO.File]::ReadAllBytes((Join-Path $ddPackageRoot 'bin/velocity_keyboard/velocity_keyboard.bin'))
$ddHexPath = Join-Path $PSScriptRoot 'image/velocity_keyboard.hex'
$ddBytes = [System.Collections.Generic.Dictionary[uint32,byte]]::new()
[uint32]$ddBase = 0
foreach ($ddLine in [System.IO.File]::ReadAllLines($ddHexPath)) {
    if ([string]::IsNullOrWhiteSpace($ddLine)) { continue }
    if (-not $ddLine.StartsWith(':')) { throw 'Invalid Intel HEX line' }
    $ddRecord = [System.Collections.Generic.List[byte]]::new()
    for ($ddI=1; $ddI -lt $ddLine.Length; $ddI+=2) { $ddRecord.Add([Convert]::ToByte($ddLine.Substring($ddI,2),16)) }
    $ddSum = 0; foreach($ddB in $ddRecord) { $ddSum += $ddB }
    if (($ddSum -band 255) -ne 0 -or $ddRecord.Count -ne $ddRecord[0]+5) { throw 'HEX checksum/length mismatch' }
    $ddCount = $ddRecord[0]; [uint32]$ddOffset = $ddRecord[1]*256+$ddRecord[2]
    switch ($ddRecord[3]) {
        0 { for($ddI=0;$ddI -lt $ddCount;$ddI++) {
            [uint32]$ddAddress = $ddBase+$ddOffset+$ddI
            if($ddBytes.ContainsKey($ddAddress)) { throw 'Duplicate Flash address in HEX' }
            $ddBytes.Add($ddAddress,$ddRecord[4+$ddI])
        } }
        1 { }
        2 { $ddBase = ($ddRecord[4]*256+$ddRecord[5])*16 }
        4 { $ddBase = ($ddRecord[4]*256+$ddRecord[5])*65536 }
        5 { }
        default { throw 'Unsupported HEX record type' }
    }
}
if ($ddBytes.Count -ne $ddOriginal.Length) { throw 'Keil image has missing or extra Flash bytes' }
for ($ddI=0;$ddI -lt $ddOriginal.Length;$ddI++) {
    [uint32]$ddAddress = 0x08000000+$ddI
    if (-not $ddBytes.ContainsKey($ddAddress) -or $ddBytes[$ddAddress] -ne $ddOriginal[$ddI]) {
        throw ('Keil output differs at 0x{0:X8}' -f $ddAddress)
    }
}
Write-Output ('KEIL_IMAGE_BYTE_EXACT_PASS: {0} Flash bytes at 0x08000000. No hardware accessed.' -f $ddOriginal.Length)
