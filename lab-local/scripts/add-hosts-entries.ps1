#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Ajoute (ou retire) les noms du point d'entrée du laboratoire dans le fichier hosts de Windows.

.DESCRIPTION
    Le navigateur et les pods doivent joindre les services d'eShop par les mêmes
    noms, en .eshop.lab. Les pods les obtiennent de CoreDNS (rôle Ansible lab_dns) ;
    ce script les apprend à Windows, en les faisant pointer vers l'adresse du
    point d'entrée, attribuée par MetalLB. Il peut être relancé sans risque.

    -Remove ne retire que la ligne ajoutée par ce script, reconnue à sa marque
    "# EshopOnContainer lab", et garde une copie du fichier d'origine.

    La liste des noms doit rester identique à lab_dns_names
    (lab-local/ansible/group_vars/control_plane.yml).

.EXAMPLE
    .\lab-local\scripts\add-hosts-entries.ps1
    .\lab-local\scripts\add-hosts-entries.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Names     = @('shop.eshop.lab', 'identity.eshop.lab', 'webhooks.eshop.lab')
$Address   = '192.168.57.20'
$Marker    = '# EshopOnContainer lab'
$Entry     = "$Address`t$($Names -join ' ')`t$Marker"

# Encodage UTF-8 sans BOM, par .NET : Set-Content de PowerShell 5.1 ajouterait un BOM
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Lignes ajoutées par ce script
$OursPattern = "#\s*EshopOnContainer lab\s*$"

# Le fichier hosts porte souvent l'attribut « lecture seule » : il est retiré le temps de l'écriture
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

$Lines = @([System.IO.File]::ReadAllLines($HostsFile))
$Ours  = @($Lines | Where-Object { $_ -match $OursPattern })

if ($Remove) {
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

if ($Ours.Count -gt 0) {
    if ($Ours -contains $Entry) {
        Write-Host "Déjà présent : $Entry"
        exit 0
    }
    Write-Host "Erreur : une ligne de ce script existe, mais diffère : $($Ours -join ' | ')" -ForegroundColor Red
    Write-Host "Lancer d'abord le script avec -Remove." -ForegroundColor Red
    exit 1
}

# Un nom déclaré ailleurs, à la main ou par un autre outil, l'emporterait ou entrerait en conflit
foreach ($Name in $Names) {
    $Pattern = "^\s*[^#\s]+\s+(.*\s)?$([regex]::Escape($Name))(\s|#|$)"
    $Other   = @($Lines | Where-Object { $_ -match $Pattern })
    if ($Other.Count -gt 0) {
        Write-Host "Erreur : '$Name' est déjà déclaré : $($Other -join ' | ')" -ForegroundColor Red
        Write-Host "Corriger la ligne à la main." -ForegroundColor Red
        exit 1
    }
}

$Raw    = [System.IO.File]::ReadAllText($HostsFile)
$Prefix = if ($Raw.Length -gt 0 -and -not $Raw.EndsWith("`n")) { "`r`n" } else { '' }
Invoke-HostsWrite { [System.IO.File]::AppendAllText($HostsFile, "$Prefix$Entry`r`n", $Utf8NoBom) }
Write-Host "Ajouté : $Entry"

# Vérification : Windows résout-il chaque nom ?
foreach ($Name in $Names) {
    $Resolved = (Resolve-DnsName -Name $Name -Type A -ErrorAction SilentlyContinue).IPAddress
    if ($Resolved -contains $Address) {
        Write-Host "Vérifié : $Name -> $Address"
    } else {
        Write-Warning "Windows ne résout pas encore '$Name' vers $Address. Lancer : ipconfig /flushdns"
    }
}

Write-Host "WSL2 relit ce fichier à son démarrage : lancer 'wsl --shutdown' puis rouvrir le terminal."
