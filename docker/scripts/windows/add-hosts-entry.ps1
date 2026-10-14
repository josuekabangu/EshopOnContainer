#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Ajoute (ou retire) le nom identity-api dans le fichier hosts de Windows.

.DESCRIPTION
    Le navigateur et les conteneurs doivent joindre Identity.API par la même
    adresse, http://identity-api:5223. Les conteneurs connaissent ce nom par le
    réseau Docker ; ce script l'apprend à Windows en le faisant pointer vers
    127.0.0.1. Il peut être relancé sans risque : il ne fait rien si le nom est
    déjà déclaré vers cette adresse.

    -Remove ne retire que la ligne ajoutée par ce script, reconnue à sa marque
    "# EshopOnContainer", et garde une copie du fichier d'origine.

.EXAMPLE
    .\add-hosts-entry.ps1
    .\add-hosts-entry.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Name      = 'identity-api'
$Address   = '127.0.0.1'
$Marker    = '# EshopOnContainer'
$Entry     = "$Address`t$Name`t$Marker"

# Encodage UTF-8 sans BOM : un BOM en tête du fichier hosts pourrait gêner sa lecture.
# Les commandes Set-Content et Add-Content de Windows PowerShell 5.1 en ajoutent un :
# les écritures passent donc par .NET directement.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Lignes actives (non commentées) qui déclarent ce nom
$Pattern     = "^\s*[^#\s]+\s+(.*\s)?$([regex]::Escape($Name))(\s|#|$)"
# Parmi elles, celles qu'a ajoutées ce script
$OursPattern = "#\s*EshopOnContainer\s*$"

# Le fichier hosts porte souvent l'attribut « lecture seule », que les droits
# d'administrateur ne lèvent pas. Il est retiré le temps de l'écriture, puis remis.
function Invoke-HostsWrite([scriptblock]$Write) {
    $Item        = Get-Item -Path $HostsFile -Force
    $WasReadOnly = $Item.IsReadOnly
    if ($WasReadOnly) { $Item.IsReadOnly = $false }
    try {
        & $Write
    }
    finally {
        if ($WasReadOnly) { (Get-Item -Path $HostsFile -Force).IsReadOnly = $true }
    }
}

$Lines    = @([System.IO.File]::ReadAllLines($HostsFile))
$Existing = @($Lines | Where-Object { $_ -match $Pattern })

if ($Remove) {
    $Ours = @($Existing | Where-Object { $_ -match $OursPattern })
    if ($Ours.Count -eq 0) {
        Write-Host "Aucune ligne ajoutée par ce script : rien à retirer."
        exit 0
    }
    Copy-Item -Path $HostsFile -Destination "$HostsFile.bak" -Force
    $Kept = @($Lines | Where-Object { $_ -notin $Ours })
    Invoke-HostsWrite { [System.IO.File]::WriteAllLines($HostsFile, [string[]]$Kept, $Utf8NoBom) }
    Write-Host "Retiré : $($Ours -join ' | ')"
    Write-Host "Copie de l'original : $HostsFile.bak"
    exit 0
}

if ($Existing.Count -gt 0) {
    if ($Existing | Where-Object { $_ -match "^\s*$([regex]::Escape($Address))\s" }) {
        Write-Host "Déjà présent : $($Existing -join ' | ')"
        exit 0
    }
    Write-Host "Erreur : '$Name' est déjà déclaré avec une autre adresse : $($Existing -join ' | ')" -ForegroundColor Red
    Write-Host "Corriger la ligne à la main." -ForegroundColor Red
    exit 1
}

# Ajouter un saut de ligne si le fichier ne se termine pas par un
$Raw    = [System.IO.File]::ReadAllText($HostsFile)
$Prefix = if ($Raw.Length -gt 0 -and -not $Raw.EndsWith("`n")) { "`r`n" } else { '' }
Invoke-HostsWrite { [System.IO.File]::AppendAllText($HostsFile, "$Prefix$Entry`r`n", $Utf8NoBom) }
Write-Host "Ajouté : $Entry"

# Vérification : Windows résout-il le nom ?
$Resolved = (Resolve-DnsName -Name $Name -Type A -ErrorAction SilentlyContinue).IPAddress
if ($Resolved -contains $Address) {
    Write-Host "Vérifié : $Name -> $Address"
} else {
    Write-Warning "Windows ne résout pas encore '$Name' vers $Address. Lancer : ipconfig /flushdns"
}

Write-Host "WSL2 relit ce fichier à son démarrage : lancer 'wsl --shutdown' puis rouvrir le terminal."
