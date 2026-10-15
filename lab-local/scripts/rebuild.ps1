<#
.SYNOPSIS
    Démarre ou reconstruit le laboratoire, en une seule commande.

.DESCRIPTION
    Enchaîne les étapes des sections 4 à 6 de lab-local/README.md :
    démarrage des machines par Vagrant (Windows), préparation des accès SSH
    et construction du cluster par Ansible (WSL2), puis vérification des nœuds.
    Le playbook étant idempotent, le script peut être relancé sans risque
    sur un cluster existant.

.PARAMETER Rebuild
    Détruit d'abord les machines : reconstruction complète, à partir de machines neuves.

.EXAMPLE
    .\lab-local\scripts\rebuild.ps1
    .\lab-local\scripts\rebuild.ps1 -Rebuild
#>
param(
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$VagrantDir = Join-Path $RepoRoot 'lab-local\vagrant'
# Chemin du dépôt vu de WSL2, par exemple /mnt/f/...
$RepoWsl    = (wsl -e wslpath -a ($RepoRoot -replace '\\', '/')).Trim()

function Invoke-Step([string]$Title, [scriptblock]$Action) {
    Write-Host "`n=== $Title" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "Échec de l'étape « $Title » (code $LASTEXITCODE)." }
}

$Start = Get-Date

# Prérequis vérifiés avant de toucher aux machines. Vagrant, VMware et WSL2 sont propres
# à chaque compte Windows : lancé depuis un autre compte, par exemple par « Exécuter en
# tant qu'administrateur » avec un compte administrateur distinct, le script trouverait
# une autre distribution WSL2, sans Ansible, et créerait des machines dans ce compte.
# La commande bash ne contient aucun guillemet double : Windows PowerShell 5.1 les transmet mal à wsl.exe.
Invoke-Step 'Vérification des prérequis' {
    Write-Host "Compte Windows : $env:USERNAME"
    wsl -e bash -c 'echo Distribution WSL2 : $WSL_DISTRO_NAME, utilisateur $(whoami); command -v ansible-playbook >/dev/null || { echo ansible-playbook est introuvable dans la distribution WSL2 par défaut de ce compte.; exit 1; }'
}

Push-Location $VagrantDir
try {
    if ($Rebuild) {
        Invoke-Step 'Destruction des machines' { vagrant destroy -f }
    }
    Invoke-Step 'Démarrage des machines' { vagrant up --provider vmware_desktop }
}
finally {
    Pop-Location
}

Invoke-Step 'Préparation des accès SSH' {
    wsl -e bash -c "cd '$RepoWsl' && bash lab-local/scripts/setup-ssh.sh"
}

# ANSIBLE_CONFIG est passé explicitement : le répertoire est sur /mnt/f, et Ansible
# ignore un ansible.cfg placé dans un répertoire accessible en écriture à tous.
Invoke-Step 'Construction du cluster' {
    wsl -e bash -c "cd '$RepoWsl/lab-local/ansible' && ANSIBLE_CONFIG='$RepoWsl/lab-local/ansible/ansible.cfg' ansible-playbook site.yml"
}

Invoke-Step 'Vérification des nœuds' {
    wsl -e bash -c "ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl get nodes -o wide"
}

Write-Host ("`nLaboratoire prêt en {0:mm\:ss}." -f ((Get-Date) - $Start)) -ForegroundColor Green