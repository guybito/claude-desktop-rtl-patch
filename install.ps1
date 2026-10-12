# Claude RTL Patch -- verified installer.
#
# Downloads patch.ps1 and patch.ps1.sig from GitHub, verifies the signature
# against an RSA-4096 public key hardcoded below (private key lives offline on
# the maintainer's machine -- see C1 mitigation), then elevates to install.
#
# A compromised GitHub repository alone is NOT enough to ship malicious code to
# users -- the attacker would also need the maintainer's offline private key.
#
# Public-key fingerprint (SHA-256 over the embedded JSON blob below):
#   6e:f4:c2:a6:c2:42:34:a1:5f:e5:cd:e5:5d:a5:b0:3c:94:64:b4:56:7f:81:04:7c:83:9a:50:1c:7c:6f:07:c9
# Cross-check this at the project README and any out-of-band channel (e.g.
# release notes, social) before trusting a fresh install.
$ExpectedPubKey = 'eyJNb2R1bHVzIjoieURqOEJOYTZVZlpiQlhJQ3p5dmFVQ2RIbFRId3VBRUMxZnJuOTNSS3pMZnhhVnM4QjI1S3lBVHhaNjc2RUVxM2Q1NFdIclhhY3g0VTN6NWdmcjlGM3E1MFJpeXVLL1c5YUhSWjMxdnk5WEdIMGNUczJCZFpvMExEUVFNbHJVWnVTVFZoRnNyV3hPQXN0WmVvbkpNUnNvZElWNjRibzVuZUhSN01yQmFKK2pqQVFMRktGdFBLUUVNUUd3TTR5OFRmbkFLcGxiTEluODNScThPM2VuaWVMc21nVEtDNzFOSWhMNkhkS1J2Q0Fpck9YMWRGWDQweDhKMEVTUnVzdytQQTJRdnlZTkYzNm54RU0wbStIa2Z5RGo1U0VLcVpZdWJ0TUxhOW40Mys3cktJQUJwVFZsMUpvN0UzQVFOQkd2MTZ6MDIzRThYTGhkZHdjOEZEOFYzZGRMeUVkMVpEd0FQZlRKRnVNWUIzMmZFVC9MQTgrL3U1V2NDREdPdTNLSzltdHVRRE9sSTN4NXJGODdFckdPOVBDSlZMV1NkQUtGc0RFMVBhenNkdmZTKzhkYXA5Sm5CRXRhUlVXOTExQUh3c3pETEFJNk9GdGdSUWt5cmNFSzBVM0FxOVdidHRaVWZXK2pEMXY3YlRldWJtMGJsa1pKWGpzT1BURUtRZllkYnRpUnppWFhHM0REMlpnbDluVVZBd2tGaTduNzNEakN3WDJhK2NNRFBZWFc1Rm1LRHpTUDR4c2tXSVp4bG5RSnMxUVRITmpkVHYzWmE4d1BFTFFlZGtIdFQrOUpFREJNaHp6aVIvdVBHS01Wa1VsYjhlN3BYa0ZpVEVZV1YwaVdPVzJRRnQvUEFJOVRXL0FEblBxdmN5MDJhWmhiNFB4ZGtFMjNiT0FLRElSMDA9IiwiRXhwb25lbnQiOiJBUUFCIn0='

$RepoBase = 'https://raw.githubusercontent.com/guybito/claude-desktop-rtl-patch/main'
$TmpFile  = Join-Path $env:TEMP 'claude_rtl_patch.ps1'

# PS 5.1 defaults to TLS 1.0; GitHub requires 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Download patch.ps1 as RAW bytes -- Invoke-RestMethod would decode and silently
# normalize the BOM, breaking the signature byte-for-byte. WebClient gives us
# the exact bytes the maintainer signed.
$client = New-Object System.Net.WebClient
# Force a fresh fetch from origin. A stale copy cached by WinINET or an
# intermediary proxy (e.g. an older patch.ps1 from before the last re-sign)
# would fail verification for no good reason. This only ever yields the current
# signed file, so it cannot break a working install.
try {
    $client.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $client.Headers.Add('Cache-Control', 'no-cache')
    $client.Headers.Add('Pragma', 'no-cache')
} catch { }
try {
    $patchBytes = $client.DownloadData("$RepoBase/patch.ps1")
    $sigB64     = $client.DownloadString("$RepoBase/patch.ps1.sig").Trim()
} catch {
    Write-Host ""
    Write-Host "Network error downloading patch: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check connectivity and retry." -ForegroundColor Yellow
    return
}

# Decode pubkey (custom JSON format; see tools/sign-release.ps1 for the rationale).
try {
    $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExpectedPubKey))
    $pubObj  = $pubJson | ConvertFrom-Json
    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
    $params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($params)
} catch {
    Write-Host "Internal error: bundled public key is malformed ($($_.Exception.Message))." -ForegroundColor Red
    Write-Host "Do NOT proceed -- this means install.ps1 itself was tampered with." -ForegroundColor Red
    return
}

# Decode signature.
try {
    $sigBytes = [Convert]::FromBase64String($sigB64)
} catch {
    Write-Host ""
    Write-Host "Downloaded signature is not valid base64. Aborting." -ForegroundColor Red
    return
}

# The actual signature check. Verify the EXACT downloaded bytes first -- the
# normal path: raw.githubusercontent.com serves the LF bytes the maintainer
# signed, so this returns $true and nothing below runs. $verifiedBytes is what
# we hand downstream; in the common case it IS $patchBytes byte-for-byte, so a
# working install is completely unchanged.
$verifiedBytes = $patchBytes
$valid = $rsa.VerifyData(
    $patchBytes, $sigBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

# Fallback: some Windows proxies / antivirus / transfer paths convert LF -> CRLF
# in transit. The signature is always computed over LF bytes (see
# tools/sign-release.ps1), and tools/verify-signature.ps1 already normalizes the
# same way before it verifies. Strip CR-before-LF and re-check. This runs ONLY
# after the raw check failed, so it can never change a working install. It is
# NOT a trust weakening: the normalized bytes must still match the maintainer's
# RSA signature, which only the offline private key can produce.
if (-not $valid) {
    $norm = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $patchBytes.Length; $i++) {
        if ($patchBytes[$i] -eq 0x0D -and ($i + 1) -lt $patchBytes.Length -and $patchBytes[$i+1] -eq 0x0A) { continue }
        $norm.Add($patchBytes[$i])
    }
    $normBytes = $norm.ToArray()
    if ($rsa.VerifyData($normBytes, $sigBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
        $valid = $true
        $verifiedBytes = $normBytes
    }
}

if (-not $valid) {
    # Diagnostics so the user (and maintainer) can tell a benign proxy mangle
    # from a real attack, and compare the hash against the published value. This
    # block runs only on failure -- it has no effect on a working install.
    $dlHash = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash($patchBytes)).Replace('-','').ToLower()
    $looksHtml = $patchBytes.Length -ge 1 -and ([char]$patchBytes[0] -eq '<')

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  SIGNATURE VERIFICATION FAILED -- REFUSING TO RUN patch.ps1     " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "The downloaded patch does not match the maintainer's signature." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  * Your network or proxy is intercepting / modifying traffic." -ForegroundColor Yellow
    Write-Host "  * Antivirus is rewriting the downloaded script." -ForegroundColor Yellow
    Write-Host "  * A maintainer pushed patch.ps1 without re-signing." -ForegroundColor Yellow
    Write-Host "  * The GitHub repository was compromised." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Diagnostics (please include these if you open an issue):" -ForegroundColor Cyan
    Write-Host ("  downloaded size  : {0} bytes" -f $patchBytes.Length) -ForegroundColor Gray
    Write-Host ("  downloaded SHA256: {0}" -f $dlHash) -ForegroundColor Gray
    if ($looksHtml) {
        Write-Host "  NOTE: the download starts with '<' -- it looks like an HTML page" -ForegroundColor Yellow
        Write-Host "        (a proxy login / captive portal), not the script. You are" -ForegroundColor Yellow
        Write-Host "        almost certainly behind a proxy that intercepts downloads." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Most failures are a proxy/AV altering the file, NOT an attack. Try:" -ForegroundColor Cyan
    Write-Host "  * a different network (e.g. a phone hotspot)," -ForegroundColor Cyan
    Write-Host "  * temporarily pausing web/HTTPS inspection in your antivirus," -ForegroundColor Cyan
    Write-Host "  * or cloning the repo and running tools\verify-signature.ps1." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Cross-check the public-key fingerprint at:" -ForegroundColor Cyan
    Write-Host "  https://github.com/guybito/claude-desktop-rtl-patch#verification" -ForegroundColor Cyan
    return
}

# Decode bytes to string and strip BOM (we'll re-add it on write). PS 5.1 needs
# the file to start with a UTF-8 BOM to parse Hebrew/box-drawing characters.
# Use $verifiedBytes -- identical to $patchBytes on the normal path, or the
# LF-normalized form when the CRLF fallback above accepted it.
$content = [System.Text.Encoding]::UTF8.GetString($verifiedBytes)
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[System.IO.File]::WriteAllText($TmpFile, $content, [System.Text.UTF8Encoding]::new($true))

Write-Host "Patch verified ($($patchBytes.Length) bytes). Elevating..." -ForegroundColor Green

# Hand the elevated patch.ps1 the pubkey blob we just verified against, as a
# -TrustedPubKey PARAMETER. patch.ps1 uses it to pin the trust anchor for the
# auto-update watcher (see Save-TrustedPubkey in patch.ps1). It MUST be a
# parameter, not an env var: environment variables set here do NOT survive the
# Start-Process -Verb RunAs UAC elevation boundary, so the elevated child would
# never see them. Passing the verified blob (rather than letting patch.ps1
# re-download install.ps1 itself) also avoids a TOCTOU window where the repo
# could change between our verify and patch.ps1's pin.

# Same launch line as the original installer -- nothing user-facing has changed.
# -NoExit keeps the elevated window open so the user can read the patch log.
Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$TmpFile`" -TrustedPubKey `"$ExpectedPubKey`""
