$script:DefaultContainer      = "kntu_pbx_core"
$script:DefaultDirectoryPath  = "/etc/freeswitch/directory/default"
$script:DefaultSequentialPath = "/etc/freeswitch/dialplan/default/01_sequential.xml"

function Invoke-FsContainerSh {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string]$StdinContent,
        [string]$Container = $script:DefaultContainer
    )

    if ($PSBoundParameters.ContainsKey('StdinContent')) {
        $output = $StdinContent | & podman exec -i $Container sh -c $Command 2>&1
    } else {
        $output = & podman exec $Container sh -c $Command 2>&1
    }

    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n")
    }
}

function Invoke-FsReloadXml {
    param(
        [string]$Container = $script:DefaultContainer
    )

    $res = Invoke-FsContainerSh -Command 'fs_cli -x "reloadxml"' -Container $Container
    if ($res.ExitCode -ne 0) {
        Write-Error "Failed to reload XML:`n$($res.Output)"
        return
    }
    Write-Host "FreeSWITCH: $($res.Output)" -ForegroundColor Cyan
}

function Add-FsUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d+$')]
        [string]$UserId,
        [string]$Password = "`$`${default_password}",
        [string]$DisplayName = "Extension $UserId",
        [string]$Context = "default",
        [string]$DirectoryPath = $script:DefaultDirectoryPath,
        [string]$Container = $script:DefaultContainer,
        [switch]$NoReload
    )

    $ErrorActionPreference = "Stop"
    $filePath = "$($DirectoryPath.TrimEnd('/'))/$UserId.xml"

    $existsCheck = Invoke-FsContainerSh -Command "test -f '$filePath'" -Container $Container
    if ($existsCheck.ExitCode -eq 0) {
        Write-Warning "User $UserId already exists in ${Container}:$filePath."
        return
    }

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = "  "
    $settings.OmitXmlDeclaration = $true

    $sw = [System.IO.StringWriter]::new()
    $writer = [System.Xml.XmlWriter]::Create($sw, $settings)

    $writer.WriteStartElement("include")
    $writer.WriteStartElement("user")
    $writer.WriteAttributeString("id", $UserId)

    $writer.WriteStartElement("params")
    @(
        @{ name = "password"; value = $Password }
        @{ name = "vm-password"; value = $UserId }
    ) | ForEach-Object {
        $writer.WriteStartElement("param")
        $writer.WriteAttributeString("name", $_.name)
        $writer.WriteAttributeString("value", $_.value)
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()

    $writer.WriteStartElement("variables")
    @(
        @{ name = "toll_allow"; value = "domestic,international,local" }
        @{ name = "accountcode"; value = $UserId }
        @{ name = "user_context"; value = $Context }
        @{ name = "effective_caller_id_name"; value = $DisplayName }
        @{ name = "effective_caller_id_number"; value = $UserId }
        @{ name = "outbound_caller_id_name"; value = "`$`${outbound_caller_name}" }
        @{ name = "outbound_caller_id_number"; value = "`$`${outbound_caller_id}" }
    ) | ForEach-Object {
        $writer.WriteStartElement("variable")
        $writer.WriteAttributeString("name", $_.name)
        $writer.WriteAttributeString("value", $_.value)
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()

    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.Flush()
    $writer.Close()

    if ($PSCmdlet.ShouldProcess("${Container}:$filePath", "Create user $UserId")) {
        $writeRes = Invoke-FsContainerSh `
            -Command "mkdir -p '$DirectoryPath' && cat > '$filePath'" `
            -StdinContent $sw.ToString() `
            -Container $Container

        if ($writeRes.ExitCode -ne 0) {
            Write-Error "Failed to write ${filePath}: $($writeRes.Output)"
            return
        }

        Write-Host "Created user $UserId at ${Container}:$filePath" -ForegroundColor Green

        if (-not $NoReload) {
            Invoke-FsReloadXml -Container $Container
        }
    }
}

function Remove-FsUser {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d+$')]
        [string]$UserId,
        [string]$DirectoryPath = $script:DefaultDirectoryPath,
        [string]$Container = $script:DefaultContainer,
        [switch]$NoReload
    )

    $filePath = "$($DirectoryPath.TrimEnd('/'))/$UserId.xml"
    $existsCheck = Invoke-FsContainerSh -Command "test -f '$filePath'" -Container $Container
    if ($existsCheck.ExitCode -ne 0) {
        Write-Warning "User file ${Container}:$filePath not found."
        return
    }

    if ($PSCmdlet.ShouldProcess("${Container}:$filePath", "Remove user $UserId")) {
        $rmRes = Invoke-FsContainerSh -Command "rm -f '$filePath'" -Container $Container
        if ($rmRes.ExitCode -ne 0) {
            Write-Error "Failed to remove ${filePath}: $($rmRes.Output)"
            return
        }

        Write-Host "Removed user $UserId from $Container." -ForegroundColor Yellow

        if (-not $NoReload) {
            Invoke-FsReloadXml -Container $Container
        }
    }
}

function Get-FsUser {
    [CmdletBinding()]
    param(
        [string]$UserId,
        [string]$DirectoryPath = $script:DefaultDirectoryPath,
        [string]$Container = $script:DefaultContainer
    )

    $dirCheck = Invoke-FsContainerSh -Command "test -d '$DirectoryPath'" -Container $Container
    if ($dirCheck.ExitCode -ne 0) {
        Write-Error "Directory ${Container}:$DirectoryPath not found."
        return
    }

    $shCmd = "for f in '$($DirectoryPath.TrimEnd('/'))'/*.xml; do [ -f `"`$f`" ] || continue; echo '===FS_FILE:'`$(basename `"`$f`")'==='; cat `"`$f`"; echo ''; done"
    $res = Invoke-FsContainerSh -Command $shCmd -Container $Container
    if ($res.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($res.Output)) {
        return
    }

    $blocks = $res.Output -split '(?m)^===FS_FILE:' | Where-Object { $_.Trim() -ne '' }
    $results = foreach ($block in $blocks) {
        $lines = $block -split "`n", 2
        if ($lines.Count -lt 2) { continue }
        $fileName = $lines[0].Replace('===', '').Trim()
        $rawXml   = $lines[1].Trim()

        try {
            [xml]$xml = $rawXml
            $userNode = $xml.include.user
            if (-not $userNode) { continue }

            $id = $userNode.id
            if ($UserId -and $id -ne $UserId) { continue }

            $displayName = ($userNode.variables.variable | Where-Object { $_.name -eq "effective_caller_id_name" }).value
            $context     = ($userNode.variables.variable | Where-Object { $_.name -eq "user_context" }).value

            [PSCustomObject]@{
                UserId      = $id
                DisplayName = $displayName
                Context     = $context
                File        = $fileName
            }
        } catch {
            Write-Warning "Failed to parse ${fileName}: $_"
        }
    }

    $results | Sort-Object UserId
}

function Set-FsSequentialHunt {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = "sequential_hunting_with_confirm",
        [ValidateRange(1, 300)]
        [int]$LegTimeout = 15,
        [string]$ConfirmFile = "tone_stream://%(200,0,800)",
        [string[]]$ContinueOnFail = @("TIMEOUT", "NO_ANSWER", "USER_NOT_REGISTERED"),
        [string[]]$FailOnSingleReject = @("USER_BUSY", "CALL_REJECTED"),
        [string]$LuaScriptPath = "`$`${conf_dir}/scripts/seq_contacts.lua",
        [string]$OutputPath = $script:DefaultSequentialPath,
        [string]$Container = $script:DefaultContainer,
        [switch]$NoReload
    )

    $ErrorActionPreference = "Stop"
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = "  "
    $settings.OmitXmlDeclaration = $true

    $sw = [System.IO.StringWriter]::new()
    $writer = [System.Xml.XmlWriter]::Create($sw, $settings)

    $writer.WriteStartElement("extension")
    $writer.WriteAttributeString("name", $Name)

    $writer.WriteStartElement("condition")
    $writer.WriteAttributeString("field", "`${user_exists(id `${destination_number} `${domain_name})}")
    $writer.WriteAttributeString("expression", "^true`$")

    $actions = @(
        @{ app = "set";    data = "group_confirm_file=$ConfirmFile" }
        @{ app = "set";    data = "continue_on_fail=$($ContinueOnFail -join ',')" }
        @{ app = "set";    data = "fail_on_single_reject=$($FailOnSingleReject -join ',')" }
        @{ app = "set";    data = "hangup_after_bridge=true" }
        @{ app = "set";    data = "seq_contacts=`${lua($LuaScriptPath `${destination_number} `${domain_name})}" }
        @{ app = "bridge"; data = "{leg_timeout=$LegTimeout}`${seq_contacts}" }
    )

    foreach ($action in $actions) {
        $writer.WriteStartElement("action")
        $writer.WriteAttributeString("application", $action.app)
        $writer.WriteAttributeString("data", $action.data)
        $writer.WriteEndElement()
    }

    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.Flush()
    $writer.Close()

    if ($PSCmdlet.ShouldProcess("${Container}:$OutputPath", "Update sequential hunting config")) {
        $parentDir = [System.IO.Path]::GetDirectoryName($OutputPath)
        $writeRes = Invoke-FsContainerSh `
            -Command "mkdir -p '$parentDir' && cat > '$OutputPath'" `
            -StdinContent $sw.ToString() `
            -Container $Container

        if ($writeRes.ExitCode -ne 0) {
            Write-Error "Failed to write ${OutputPath}: $($writeRes.Output)"
            return
        }

        Write-Host "Updated sequential hunting config: ${Container}:$OutputPath" -ForegroundColor Green

        if (-not $NoReload) {
            Invoke-FsReloadXml -Container $Container
        }
    }
}

function Get-FsSequentialHunt {
    [CmdletBinding()]
    param(
        [string]$Path = $script:DefaultSequentialPath,
        [string]$Container = $script:DefaultContainer
    )

    $res = Invoke-FsContainerSh -Command "cat '$Path'" -Container $Container
    if ($res.ExitCode -ne 0) {
        Write-Warning "File ${Container}:$Path not found."
        return
    }

    [xml]$xml = $res.Output
    $actions = $xml.extension.condition.action

    $getVal = {
        param($key)
        $item = $actions | Where-Object { $_.application -eq "set" -and $_.data -like "$key=*" }
        if ($item) { $item.data.Substring($key.Length + 1) } else { $null }
    }

    $bridgeData = ($actions | Where-Object { $_.application -eq "bridge" }).data
    $timeout = if ($bridgeData -match 'leg_timeout=(\d+)') { [int]$Matches[1] } else { $null }

    [PSCustomObject]@{
        Name               = $xml.extension.name
        LegTimeout         = $timeout
        ConfirmFile        = & $getVal "group_confirm_file"
        ContinueOnFail     = & $getVal "continue_on_fail"
        FailOnSingleReject = & $getVal "fail_on_single_reject"
        Path               = "${Container}:$Path"
    }
}

Export-ModuleMember -Function Add-FsUser, Remove-FsUser, Get-FsUser, Set-FsSequentialHunt, Get-FsSequentialHunt