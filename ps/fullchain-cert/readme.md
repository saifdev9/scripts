# TLS full-chain certificates (nginx on Windows)

Android rejects HTTPS connections when a server sends only its own certificate,
with the error `Trust anchor for certification path not found`. Browsers and
Windows hide this problem, because they download missing intermediate
certificates themselves. Android doesn't. nginx must therefore serve the
**full chain**: the server certificate followed by its intermediate certificates.

## Required chains

| Tenant   | Host                      | Issued by         | Chain to serve (in order)                                           |
| -------- | ------------------------- | ----------------- | ------------------------------------------------------------------- |
| IRAGE    | `friskit.irage.in`        | Let's Encrypt YE1 | server → YE1 → Root YE (signed by X2) → ISRG Root X2 (signed by X1) |
| NOBORU   | `rms.noborudmcc.com:3000` | Sectigo DV R36    | server → DV R36 → Root R46 (signed by USERTrust)                    |
| VMATHRAN | `rms.vmathran.in`         | Sectigo DV R36    | server → DV R36 → Root R46 (signed by USERTrust)                    |

The script below builds these automatically. It also knows the other Let's
Encrypt intermediates (YE1–YE3, YR1–YR3), because Let's Encrypt can switch
between them at any renewal.

**Requirements:** PowerShell 5.1 or later, and outbound access to
`letsencrypt.org` and `crt.sectigo.com`. OpenSSL isn't needed on the server.

## Steps

### 1. Build the full chain

Set the 3 lines at the top of the script for the server you're on:

| Server layout                   | `$Dir`                                                | `$Cert`           | `$Out`                      |
| ------------------------------- | ----------------------------------------------------- | ----------------- | --------------------------- |
| nginx `ssl` folder (e.g. IRAGE) | `C:\ProgramData\Indiminds\Friskit\nginx\ssl\<domain>` | `fullchain.pem`   | `fullchain.new.pem`         |
| `C:\Friskit\Program Files\SSL`  | `C:\Friskit\Program Files\SSL`                        | `certificate.crt` | `certificate.fullchain.crt` |

`$Cert` is the file nginx's `ssl_certificate` points to now. `$Out` is the new
file the script creates.

Then run it in **one** of two ways, in PowerShell **as Administrator**:

- **Copy-paste (no file needed):** copy the script from the section below,
  edit the 3 lines, paste the whole block into PowerShell and press Enter.
  Press Enter again if nothing happens.
- **As a file:** save it as `scripts\Build-FullChain.ps1`, edit the 3 lines,
  then run:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\Build-FullChain.ps1
  ```

The script reads the server certificate from `$Cert`, downloads the matching
intermediates, checks every link in the chain, and writes `$Out` to the same
folder. It never modifies `$Cert` or the private key. If anything goes wrong,
it stops with a red error and writes nothing.

Expected output (Sectigo):

```
0. CN=rms.vmathran.in  <-  CN=Sectigo Public Server Authentication CA DV R36, ...
1. CN=Sectigo Public Server Authentication CA DV R36, ...  <-  CN=Sectigo Public Server Authentication Root R46, ...
2. CN=Sectigo Public Server Authentication Root R46, ...  <-  CN=USERTrust RSA Certification Authority, ...
OK: wrote C:\Friskit\Program Files\SSL\certificate.fullchain.crt (3 certificates). Server cert expires 2026-12-03.
```

A Let's Encrypt certificate prints 4 numbered lines instead of 3.

If the script prints `Unknown issuer '...'`, the certificate came from an
intermediate the script doesn't list. Add that intermediate's download link
to `$chains` in the script.

### 2. Point nginx at the new file

From the nginx folder, find every `server` block that uses the current
certificate file (`$Cert`):

```powershell
Get-ChildItem -Recurse -Filter *.conf | Select-String -SimpleMatch 'fullchain.pem'      # or 'certificate.crt'
```

In each block, change only `ssl_certificate` to the `$Out` file:

```nginx
# nginx ssl folder layout
ssl_certificate     "C:/ProgramData/Indiminds/Friskit/nginx/ssl/<domain>/fullchain.new.pem";

# C:\Friskit\Program Files\SSL layout
ssl_certificate     "C:\Friskit\Program Files\SSL\certificate.fullchain.crt";
```

Leave `ssl_certificate_key` unchanged.

### 3. Test and reload

Run these from the folder that contains `nginx.exe`:

```powershell
.\nginx.exe -t          # must print "syntax is ok" and "test is successful"
.\nginx.exe -s reload
```

Don't reload if `-t` fails. A `key values mismatch` error means the server
certificate doesn't match the private key.

### 4. Verify from outside

```bash
openssl s_client -connect <host>:<port> -servername <host> </dev/null \
  | grep -E '^ *[0-9]+ s:|Verify return code'
```

The check passes when the output lists 3 certificates (Sectigo) or 4
(Let's Encrypt) and ends with `Verify return code: 0 (ok)`.

### Rollback

Point `ssl_certificate` back to the original `$Cert` file, then run
`nginx -t` and `nginx -s reload`.

## After every certificate renewal

Renewal replaces the original certificate (`$Cert`) and the private key, but
**not** `$Out`, which still holds the old server certificate. Right after each
renewal, **re-run step 1 and then step 3**. No nginx conf change is needed the
second time.

If you skip this, nginx either fails to reload because the key no longer
matches, or keeps serving the old certificate until it expires.

The better long-term fix is to configure the renewal tool to write the full
chain itself. Once it does, this step isn't needed.

<details>
<summary>The script: copy-paste it, or save it as <code>scripts\Build-FullChain.ps1</code></summary>

```powershell
& {
# ======== EDIT THESE 3 LINES ========
$Dir  = "C:\Friskit\Program Files\SSL"   # folder that holds the certificate
$Cert = "certificate.crt"                # current certificate file (nginx ssl_certificate)
$Out  = "certificate.fullchain.crt"      # new file to create for nginx
# ====================================
# Builds an nginx full-chain file: server cert + intermediates. Reads the FIRST
# certificate in $Cert as the server cert, picks the intermediates from its
# issuer, checks every link, and writes $Out. Never modifies $Cert or the key.
# Wrapped in & { } so any error stops the whole run, even when pasted.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$X509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]

# Issuer CN of the server cert -> certificates to append, in order (leaf's issuer first).
# "url|CN" picks the cert issued by CN out of a PKCS#7 (.p7c) bundle.
$le = "https://letsencrypt.org/certs/gen-y"
$r36 = "http://crt.sectigo.com/SectigoPublicServerAuthenticationCADVR36.crt"
$r46 = "http://crt.sectigo.com/SectigoPublicServerAuthenticationRootR46.p7c|USERTrust RSA Certification Authority"
$chains = @{
  "YE1" = @("$le/int-ye1.pem", "$le/root-ye-by-x2.pem", "$le/root-x2-by-x1.pem")
  "YE2" = @("$le/int-ye2.pem", "$le/root-ye-by-x2.pem", "$le/root-x2-by-x1.pem")
  "YE3" = @("$le/int-ye3.pem", "$le/root-ye-by-x2.pem", "$le/root-x2-by-x1.pem")
  "YR1" = @("$le/int-yr1.pem", "$le/root-yr-by-x1.pem")
  "YR2" = @("$le/int-yr2.pem", "$le/root-yr-by-x1.pem")
  "YR3" = @("$le/int-yr3.pem", "$le/root-yr-by-x1.pem")
  "Sectigo Public Server Authentication CA DV R36" = @($r36, $r46)
}

function Read-Pem([string] $text) {
  [regex]::Matches($text, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----') | ForEach-Object {
    $X509::new([Convert]::FromBase64String(($_.Value -replace '-----(BEGIN|END) CERTIFICATE-----|\s', '')))
  }
}

function To-Pem($c) {
  $b64 = [Convert]::ToBase64String($c.RawData)
  "-----BEGIN CERTIFICATE-----`n" + (($b64 -split '(.{64})' | Where-Object { $_ }) -join "`n") + "`n-----END CERTIFICATE-----"
}

function Get-Cert([string] $spec) {
  $url, $pick = $spec -split '\|'
  $tmp = [IO.Path]::GetTempFileName()
  try {
    Invoke-WebRequest $url -UseBasicParsing -OutFile $tmp
    $bytes = [IO.File]::ReadAllBytes($tmp)
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  if ($pick) {
    $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $col.Import($bytes)
    $c = $col | Where-Object { $_.Issuer -like "*CN=$pick*" } | Select-Object -First 1
    if (-not $c) { throw "No certificate issued by '$pick' in $url" }
    return $c
  }
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  if ($text -match 'BEGIN CERTIFICATE') { return Read-Pem $text | Select-Object -First 1 }
  return $X509::new($bytes)   # DER (.crt)
}

$certPath = Join-Path $Dir $Cert
$leaf = Read-Pem (Get-Content $certPath -Raw) | Select-Object -First 1
if (-not $leaf) { throw "No certificate found in $certPath" }
$issuerCN = $leaf.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
if (-not $chains.ContainsKey($issuerCN)) {
  throw "Unknown issuer '$issuerCN'. Add its intermediates to `$chains in this script."
}

$chain = @($leaf) + @($chains[$issuerCN] | ForEach-Object { Get-Cert $_ })

for ($i = 0; $i -lt $chain.Count; $i++) {
  "{0}. {1}  <-  {2}" -f $i, $chain[$i].Subject, $chain[$i].Issuer
  if ($i -gt 0 -and $chain[$i - 1].Issuer -ne $chain[$i].Subject) {
    throw "Chain broken at #${i}: '$($chain[$i - 1].Issuer)' is not '$($chain[$i].Subject)'"
  }
}
if ($leaf.NotAfter -lt (Get-Date)) { Write-Warning "Server certificate EXPIRED on $($leaf.NotAfter)" }

$outPath = Join-Path $Dir $Out
$pem = (($chain | ForEach-Object { To-Pem $_ }) -join "`n") + "`n"
[IO.File]::WriteAllText($outPath, $pem, (New-Object System.Text.ASCIIEncoding))   # no BOM
"OK: wrote $outPath ($($chain.Count) certificates). Server cert expires $($leaf.NotAfter.ToString('yyyy-MM-dd'))."
}
```

</details>
