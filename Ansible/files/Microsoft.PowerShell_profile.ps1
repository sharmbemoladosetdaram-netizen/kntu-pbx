# Microsoft.PowerShell_profile.ps1
# Put this in powershell $PROFILE

$banner = @"
 ██╗  ██╗███╗   ██╗████████╗██╗   ██╗    ██████╗ ██████╗ ██╗  ██╗
 ██║ ██╔╝████╗  ██║╚══██╔══╝██║   ██║    ██╔══██╗██╔══██╗╚██╗██╔╝
 █████╔╝ ██╔██╗ ██║   ██║   ██║   ██║    ██████╔╝██████╔╝ ╚███╔╝ 
 ██╔═██╗ ██║╚██╗██║   ██║   ██║   ██║    ██╔═══╝ ██╔══██╗ ██╔██╗ 
 ██║  ██╗██║ ╚████║   ██║   ╚██████╔╝    ██║     ██████╔╝██╔╝ ██╗
 ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝     ╚═╝     ╚═════╝ ╚═╝  ╚═╝
"@
Clear-Host
Write-Host
Write-Host
Write-Host $banner -ForegroundColor Cyan
Write-Host
Write-Host

Import-Module KntuPbxManager -ErrorAction SilentlyContinue

# --- 2. Remove dangerous built-in commands ---
$DangerousCmdlets = @(
    "Import-Module", "Remove-Module", "Invoke-Expression", 
    "Get-Content", "Set-Content", "Add-Content", "Clear-Content",
    "Invoke-Command", "Invoke-RestMethod", "Invoke-WebRequest"
)
foreach ($cmd in $DangerousCmdlets) {
    # Remove Aliases and Functions
    Remove-Item -Path "Alias:\$cmd" -ErrorAction Ignore
    Remove-Item -Path "Function:\$cmd" -ErrorAction Ignore
    
    # Hide native Cmdlets by making them Private
    $targetCmd = Get-Command $cmd -ErrorAction Ignore
    if ($targetCmd) {
        $targetCmd.Visibility = 'Private'
    }
}

# --- 3. Custom Tab Completion ---
Set-PSReadLineKeyHandler -Key Tab -ScriptBlock {
    $line = $null
    $cursor = $null
    
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    if ([string]::IsNullOrWhiteSpace($line)) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert("Get-Command -Module KntuPbxManager")
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext()
    }
}

# --- 4. Define the custom prompt with the current path ---
function prompt {
    # Get the current location
    $currentPath = Get-Location

    # Write the static part of the prompt
    Write-Host "KntuPbx " -NoNewline -ForegroundColor Cyan
    
    # Write the path
    Write-Host "$currentPath" -NoNewline -ForegroundColor Yellow
    
    # Write the final character
    Write-Host "> " -NoNewline
    
    # Return a space to tell PowerShell we've handled the prompt
    return " "
}