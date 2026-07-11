<#
.SYNOPSIS
    One-time helper: AES-encrypts your HP BIOS Setup password and prints the
    $BiosPasswordKey and $BiosPasswordBlob lines to paste into Remediate-HPBiosUpdate.ps1.

.DESCRIPTION
    Run this LOCALLY (interactively) on an admin workstation - NOT in Intune.
    CMSL's Get-HPBIOSUpdates -Password takes the PLAINTEXT setup password (not the .bin file
    you use with HPIA), so this stores it AES-encrypted and the remediation decrypts in memory.

    SECURITY NOTE: This is obfuscation, not secrecy. The key travels in the remediation script,
    so anyone who can read that script in Intune can decrypt the password. Restrict who can
    view/edit the Remediation, rotate the BIOS password periodically, and treat the script as a
    secret.

.EXAMPLE
    .\New-EncryptedBiosPassword.ps1
#>

[CmdletBinding()]
param()

$secure = Read-Host -AsSecureString -Prompt 'Enter the HP BIOS Setup password'
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if ([string]::IsNullOrEmpty($plain)) { Write-Error 'No password entered.'; return }

$aes = [System.Security.Cryptography.Aes]::Create()
$aes.GenerateKey()
$aes.GenerateIV()
$enc  = $aes.CreateEncryptor()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
$ct   = $enc.TransformFinalBlock($bytes, 0, $bytes.Length)

# Blob = IV (16 bytes) + ciphertext, Base64-encoded.
$blob = [Convert]::ToBase64String($aes.IV + $ct)
$keyCsv = ($aes.Key -join ',')

# Sanity check round-trip.
$all = [Convert]::FromBase64String($blob)
$dec = $aes.CreateDecryptor()
$rt  = [System.Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($all[16..($all.Length-1)], 0, $all.Length-16))
$aes.Dispose()
if ($rt -ne $plain) { Write-Error 'Round-trip verification failed.'; return }

Write-Host ''
Write-Host 'Paste these two lines into Remediate-HPBiosUpdate.ps1 (replacing the placeholders):' -ForegroundColor Green
Write-Host ''
Write-Host "`$BiosPasswordKey  = [byte[]]@($keyCsv)"
Write-Host "`$BiosPasswordBlob = '$blob'"
Write-Host ''
Write-Host 'Round-trip verified OK.' -ForegroundColor Green
