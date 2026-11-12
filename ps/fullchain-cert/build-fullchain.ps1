<#
  Build-FullChain.ps1 - builds an nginx full-chain file: server cert + intermediates.

  Usage (PowerShell, on the server):
    .\Build-FullChain.ps1 -Dir "C:\ProgramData\Indiminds\Friskit\nginx\ssl\friskit.irage.in"

  Reads the FIRST certificate in -Cert (default fullchain.pem) as the server cert,
  so it works on a leaf-only file and on an existing full chain alike. Picks the
  intermediates from that cert's issuer, checks every link, and writes -Out
  (default fullchain.new.pem). Never modifies -Cert or the private key.
#>
param(
  [Parameter(Mandatory = $true)] [string] $Dir,
  [string] $Cert = "fullchain.pem",
  [string] $Out = "fullchain.new.pem"
)
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
