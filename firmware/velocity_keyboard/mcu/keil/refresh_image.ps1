$ErrorActionPreference = 'Stop'
$ddLabRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ddProof = Get-Content -LiteralPath (Join-Path $ddLabRoot 'VERSION.json') -Raw | ConvertFrom-Json
$ddPackageRoot = [System.IO.Path]::GetFullPath((Join-Path $ddLabRoot '../..'))
$ddElf = Join-Path $ddPackageRoot 'bin/velocity_keyboard/velocity_keyboard.elf'
$ddExpected = $ddProof.outputs.'velocity_keyboard.elf'
if ((Get-FileHash -LiteralPath $ddElf -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ddExpected) {
    throw 'ELF differs from qualified MCU firmware. Nothing copied or programmed.'
}
$ddBinPath = Join-Path $ddPackageRoot 'bin/velocity_keyboard/velocity_keyboard.bin'
$ddBinHash = (Get-FileHash -LiteralPath $ddBinPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ddBinHash -ne $ddProof.outputs.'velocity_keyboard.bin') {
    throw 'BIN differs from current MCU build. Nothing programmed.'
}
$ddRaw = [System.IO.File]::ReadAllBytes($ddBinPath)
$ddReset = [BitConverter]::ToUInt32($ddRaw, 4)
if (($ddReset -band 1) -ne 1 -or $ddReset -lt 0x08000000 -or $ddReset -ge (0x08000000+$ddRaw.Length)) {
    throw 'Invalid MCU reset vector.'
}
$ddOffset = $ddReset-($ddReset % 2)-0x08000000
$ddContainer = Join-Path $PSScriptRoot 'image_container.c'
$ddOldSource = [System.IO.File]::ReadAllText($ddContainer)
$ddStamp = '/* MCU binary SHA256: '+$ddBinHash+' */'
$ddNewSource = $ddOldSource -replace '/\* MCU binary SHA256: [0-9a-f]+ \*/\r?\n', ''
$ddNewSource = $ddStamp+"`n"+($ddNewSource -replace 'qualified_firmware_start \+ [0-9]+', ('qualified_firmware_start + '+$ddOffset))
if ($ddNewSource -ne $ddOldSource) {
    [System.IO.File]::WriteAllText($ddContainer, $ddNewSource, [System.Text.UTF8Encoding]::new($false))
}
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'image') -Force | Out-Null
Write-Output 'MCU ELF/BIN verified; native Keil source refreshed when image changes. No hardware accessed.'
