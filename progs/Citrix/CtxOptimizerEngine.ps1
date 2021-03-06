<#
.SYNOPSIS
    Citrix Optimization Engine helps to optimize operating system to run better with XenApp or XenDesktop solutions. 

.DESCRIPTION
    Citrix Optimization Engine helps to optimize operating system to run better with XenApp or XenDesktop solutions. This script can run in three different modes - Analyze, Execute and Rollback. Each execution will automatically generate an XML file with a list of performed actions (stored under .\Logs folder) that can be used to rollback the changes applied. 

.PARAMETER Source
    Source XML file that contains the required configuration. Typically located under .\Templates folder. This file provides instructions that CTXOE can process. 

.PARAMETER Mode
    CTXOE supports three different modes: 
        Analyze - Do not apply any changes, only show the recommended changes. 
        Execute - Apply the changes to the operating system. 
        Rollback - Revert the applied changes. Requires a valid XML backup from the previously run Execute phase. This file is usually called Execute_History.xml. 

.PARAMETER Groups
    Array that allows you to specify which groups to process from a specified source file. 

.PARAMETER OutputXml
    The location where the output XML should be saved. The XML with results is automatically saved under .\Logs folder, but you can optionally specify also other location. This argument can be used together with -OutputHtml.

.PARAMETER OutputHtml
    The location where the output HTML report should be saved. The HTML with results is automatically saved under .\Logs folder, but you can optionally specify another location. This argument can be used together with -OutputXml.

.PARAMETER OptimizerUI
    Parameter used by Citrix Optimizer UI to retrieve information from optimization engine. For internal use only. 
	
.EXAMPLE
    .\CtxOptimizerEngine.ps1 -Source C:\Temp\Win10.xml -Mode Analyze
    Process all entries in Win10.xml file and display the recommended changes. Changes are not applied to the system. 

.EXAMPLE
    .\CtxOptimizerEngine.ps1 -Source C:\Temp\Win10.xml -Mode Execute
    Process all entries from Win10.xml file. These changes are applied to the operating system. 

.EXAMPLE
    .\CtxOptimizerEngine.ps1 -Source C:\Temp\Win10.xml -Mode Execute -Groups "DisableServices", "RemoveApplications"
    Process entries from groups "Disable Services" and "Remove built-in applications" in Win10.xml file. These changes are applied to the operating system. 

.EXAMPLE
    .\CtxOptimizerEngine.ps1 -Source C:\Temp\Win10.xml -Mode Execute -OutputXml C:\Temp\Rollback.xml
    Process all entries from Win10.xml file. These changes are applied to the operating system. Save the rollback instructions in the file rollback.xml. 

.EXAMPLE
    .\CtxOptimizerEngine.ps1 -Source C:\Temp\Rollback.xml -Mode Rollback
    Revert all changes from the file rollback.xml.

.NOTES
    Author: Martin Zugec
    Date:   February 17, 2017

.LINK
    https://support.citrix.com/article/CTX224676    
#>

#Requires -Version 2

Param (
    [Alias("Template")]
    [System.String]$Source,

    [ValidateSet('analyze','execute','rollback')]

    [System.String]$Mode = "Analyze",

    [Array]$Groups,

    [String]$OutputHtml,

    [String]$OutputXml,

    [Switch]$OptimizerUI
)

Write-Host "------------------------------"
Write-Host "| Citrix Optimization Engine |"
Write-Host "| Version 2.0                |"
Write-Host "------------------------------"
Write-Host

Write-Host "Running in " -NoNewline 
Write-Host -ForegroundColor Yellow $Mode -NoNewLine 
Write-Host " mode"

# Error handling. We want Citrix Optimizer to abort on any error, so error action preference is set to "Stop". 
# The problem with this approach is that if Optimizer is called from another script, "Stop" instruction will apply to that script as well, so failure in Optimizer engine will abort calling script(s). 
# As a workaround, instead of terminating the script, Optimizer has a global error handling procedure that will restore previous setting of ErrorActionPreference and properly abort the execution. 
$OriginalErrorActionPreferenceValue = $ErrorActionPreference; 
$ErrorActionPreference = "Stop"

Trap {
    Write-Host "Citrix Optimizer engine has encountered a problem and will now terminate";
    $ErrorActionPreference = $OriginalErrorActionPreferenceValue;
    Write-Error $_;
    Return $False;
}

# Create enumeration for PluginMode. Enumeration cannot be used in the param() section, as that would require a DynamicParam on a script level.
[String]$PluginMode = $Mode

# Just in case if previous run failed, make sure that all modules are reloaded
Remove-Module CTXOEP*

# Test if current host supports transcription or not. PowerShell ISE is one of the hosts that doesn't support transcription. 
Function Test-SupportsTranscription {
    $externalHost = $Host.GetType().GetProperty("ExternalHost",[Reflection.BindingFlags]"NonPublic,Instance").GetValue($host, @())

    Try {
        [Void]$externalHost.GetType().GetProperty("IsTranscribing",[Reflection.BindingFlags]"NonPublic,Instance").GetValue($externalHost, @())
        Return $True
    } Catch {
        Return $False
    }
}

# Test if current host is transcribing or not. 
Function Test-IsTranscribing {
    $externalHost = $Host.GetType().GetProperty("ExternalHost",[Reflection.BindingFlags]"NonPublic,Instance").GetValue($host, @())

    Try {
        Return $externalHost.GetType().GetProperty("IsTranscribing",[Reflection.BindingFlags]"NonPublic,Instance").GetValue($externalHost, @())
    } Catch {
        Return $False
    }
}

# Create $CTXOE_Main variable that defines folder where the script is located. If code is executed manually (copy & paste to Powershell window), current directory is being used
If ($MyInvocation.MyCommand.Path -is [Object]) {
    [string]$Global:CTXOE_Main = $(Split-Path -Parent $MyInvocation.MyCommand.Path)
} Else {
    [string]$Global:CTXOE_Main = $(Get-Location).Path
}

# Create Logs folder if it doesn't exists
$Global:CTXOE_LogFolder = "$CTXOE_Main\Logs\$([DateTime]::Now.ToString('yyyy-MM-dd_HH-mm-ss'))"

If ($(Test-Path "$CTXOE_LogFolder") -eq $false) {
    Write-Host "Creating Logs folder $(Split-Path -Leaf $CTXOE_LogFolder)"
    MkDir $CTXOE_LogFolder | Out-Null
}

# Report the location of log folder to UI
If ($OptimizerUI) {
    $LogFolder = New-Object -TypeName PSObject
    $LogFolder.PSObject.TypeNames.Insert(0,"logfolder")
    $LogFolder | Add-Member -MemberType NoteProperty -Name Location -Value $CTXOE_LogFolder
    Write-Output $LogFolder
}

# Initialize debug log (transcript). PowerShell ISE doesn't support transcriptions at the moment. 
Write-Host "Starting session log"

If (Test-SupportsTranscription) {
    If (Test-IsTranscribing) {Stop-Transcript}
    $CTXOE_DebugLog = "$CTXOE_LogFolder\Log_Debug_CTXOE.log"
    Start-Transcript -Append -Path "$CTXOE_DebugLog"
}

# Check if user is administrator
Write-Host "Checking permissions"
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Throw "You must be administrator in order to execute this script"
}

# Check if template name has been provided. If not, try to detect proper template automatically
If ($Source.Length -eq 0) {
    Write-Host "Template not specified, turning on auto-select mode"; 
    [String]$TemplateName = "Citrix_Windows"

    # If this is server OS, include "Server" in the template name. If this is client, don't do anything. While we could include _Client in the template name, it just looks weird. 
    If ($(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType).InstallationType -eq "Server") {
        $TemplateName += "_Server"
    }

    # Strip the description, keep only numbers. Special processing is required to include "R2" versions. Result of this regex is friendly version number (7, 10 or '2008 R2' for example)
    [String]$OS_Number = $(Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductName).ProductName;
    $OS_Number = $([regex]"([0-9])+\sR([0-9])+|[(0-9)]+").Match($OS_Number).Captures[0].Value.Replace(" ", ""); 
    $TemplateName += "_$($OS_Number)";

    # If available, retrieve a build number (yymm like 1808). This is used on Windows Server 2016 and Windows 10, but is not used on older operating systems and is optional
    [String]$OS_Build = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ReleaseID -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ReleaseID
    If ($OS_Build.Length -gt 0) {$TemplateName += "_$($OS_Build)"}

    # Test if template exists - if not, abort script execution
    If (Test-Path -Path "$CTXOE_Main\Templates\$TemplateName.xml") {
        $Source = "$CTXOE_Main\Templates\$TemplateName.xml";
    } Else {
        Throw "Required template $CTXOE_Main\Templates\$TemplateName.xml has not been found!";
    }
}

# Check if -Source is a fullpath or just name of the template. If it's just the name, expand to a fullpath. 
If (-not $Source.Contains("\")) {
    If (-not $Source.ToLower().EndsWith(".xml")) {
         $Source = "$Source.xml";
    }

    $Source = "$CTXOE_Main\Templates\$Source"; 
}

# Specify the default location of output XML
[String]$ResultsXml = "$CTXOE_LogFolder\$($PluginMode)_History.xml"
If ($OutputHtml.Length -eq 0) {
    [String]$OutputHtml = "$CTXOE_LogFolder\$($PluginMode)_History.html"
}

# Add CTXOE modules to PSModulePath variable. With this modules can be loaded dynamically based on the prefix. 
Write-Host "Adding CTXOE modules"
$Global:CTXOE_Modules = "$CTXOE_Main\Modules"
$Env:PSModulePath = "$([Environment]::GetEnvironmentVariable("PSModulePath"));$($Global:CTXOE_Modules)"

# Older version of PowerShell cannot load modules on-demand. All modules are pre-loaded. 
If ($Host.Version.Major -le 2) {
    Write-Host "Detected older version of PowerShell. Importing all modules manually."
    ForEach ($m_Module in $(Get-ChildItem -Path "$CTXOE_Main\Modules" -Recurse -Filter "*.psm1")) {
        Import-Module -Name $m_Module.FullName
    }
}

Write-Host
Write-Host "Processing definition file $Source"
[Xml]$PackDefinitionXml = Get-Content $Source

# If mode is rollback, check if definition file contains the required history elements
If ($PluginMode -eq "Rollback") {
    If ($PackDefinitionXml.SelectNodes("//rollbackparams").Count -eq 0) {
        Throw "You need to select a log file from execution for rollback. This is usually called execute_history.xml. The file specified doesn't include instructions for rollback" 
    }
}

# Display metadata for selected template. This acts as a header information about template
$PackDefinitionXml.root.metadata.ChildNodes | Select-Object Name, InnerText | Format-Table -HideTableHeaders

# First version of templates organized groups in packs. This was never really used and < pack/> element was removed in schema version 2.0
# This code is used for backwards compatiblity with older templates
If ($PackDefinitionXml.root.pack -is [System.Xml.XmlElement]) {
    Write-host "Old template format has been detected, you should migrate to newer format" -for Red; 
    $GroupElements = $PackDefinitionXml.SelectNodes("/root/pack/group");
} Else {
    $GroupElements = $PackDefinitionXml.SelectNodes("/root/group");
}

# Process template
ForEach ($m_Group in $GroupElements) {
    Write-Host
    Write-Host "        Group: $($m_Group.DisplayName)"
    Write-Host "        Group ID: $($m_Group.ID)"

    If ($Groups.Count -gt 0 -and $Groups -notcontains $m_Group.ID) {
        Write-Host "        Group not included in the -Groups argument, skipping"
        Continue
    }

    If ($m_Group.Enabled -eq "0") {
        Write-Host "    This group is disabled, skipping" -ForegroundColor DarkGray
        Continue
    }

    ForEach ($m_Entry in $m_Group.SelectNodes("./entry")) {
        Write-Host "            $($m_Entry.Name) - " -NoNewline

        If ($m_Entry.Enabled -eq "0") {
            Write-Host "    This entry is disabled, skipping" -ForegroundColor DarkGray
            CTXOE\New-CTXOEHistoryElement -Element $m_Entry -SystemChanged $False -StartTime $([DateTime]::Now) -Result $False -Details "Entry is disabled"

            Continue
        }

        If ($m_Entry.Execute -eq "0") {
            Write-Host " Entry is not marked for execution, skipping" -ForegroundColor DarkGray
            CTXOE\New-CTXOEHistoryElement -Element $m_Entry -SystemChanged $False -StartTime $([DateTime]::Now) -Result $False -Details "Entry is not marked for execution, skipping"

            Continue
        }

        $m_Action = $m_Entry.SelectSingleNode("./action")
        Write-Verbose "            Plugin: $($m_Action.Plugin)"

        # While some plugins can use only a single set of instructions to perform all the different operations (typically services or registry keys), this might not be always possible. 

        # Good example is "PowerShell" plugin - different code can be used to analyze the action and execute the action (compare "Get-CurrentState -eq $True" for analyze to "Set-CurrentState -Mode Example -Setup Mode1" for execute mode).

        # In order to support this scenarios, it is possible to override the default <params /> element with a custom element for analyze and rollback phases. Default is still <params />. With this implementation, there can be an action that will implement all three elements (analyzeparams, rollbackparams and executeparams). 

        [String]$m_ParamsElementName = "params"
        [String]$m_OverrideElement = "$($PluginMode.ToLower())$m_ParamsElementName"

        If ($m_Action.$m_OverrideElement -is [Object]) {
            Write-Verbose "Using custom <$($m_OverrideElement) /> element"
            $m_ParamsElementName = $m_OverrideElement
        }

        # To prevent any unexpected damage to the system, Rollback mode requires use of custom params object and cannot use the default one. 
        If ($PluginMode -eq "Rollback" -and $m_Action.$m_OverrideElement -isnot [Object]) {
            If ($m_Entry.history.systemchanged -eq "0") {
                Write-Host "This entry has not changed, skip" -ForegroundColor DarkGray
                Continue
            } Else {
                Write-Host "Rollback mode requires custom instructions that are not available, skip" -ForegroundColor DarkGray
                Continue
            }
        }

        # Reset variables that are used to report the status
        [Boolean]$Global:CTXOE_Result = $False;
        $Global:CTXOE_Details = "No data returned by this entry (this is unexpected)";

        # Two variables used by rollback. First identify that this entry has modified the system. The second should contain information required for rollback of those changes (if possible). This is required only for "execute" mode. 
        [Boolean]$Global:CTXOE_SystemChanged = $False

        $Global:CTXOE_ChangeRollbackParams = $Null

        [DateTime]$StartTime = Get-Date; 
        CTXOE\Invoke-CTXOEPlugin -PluginName $($m_Action.Plugin) -Params $m_Action.$m_ParamsElementName -Mode $PluginMode -Verbose
		
		# This code is added to have a situation where CTXOE_Result is set, but not to boolean value (for example to empty string). This will prevent engine from crashing and report which entry does not behave as expected. 
		# We do this check here so following code does not need to check if returned value exists
		If ($CTXOE_Result -isnot [Boolean]) {
			$CTXOE_Result = $false; 
			$CTXOE_Details = "While processing $($m_Entry.Name) from group $($m_Group.ID), there was an error or code did not return expected result. This value should be boolean, while returned value is $($CTXOE_Result.GetType().FullName)."; 
		}

        If ($CTXOE_Result -eq $false) {
            Write-Host -ForegroundColor Red $CTXOE_Details
        } Else {
            Write-Host -ForegroundColor Green $CTXOE_Details
        }

        # Save information about changes as an element
        CTXOE\New-CTXOEHistoryElement -Element $m_Entry -SystemChanged $CTXOE_SystemChanged -StartTime $StartTime -Result $CTXOE_Result -Details $CTXOE_Details -RollbackInstructions $CTXOE_ChangeRollbackParams

        If ($OptimizerUI) {
            $history = New-Object -TypeName PSObject
            $history.PSObject.TypeNames.Insert(0,"history")
            $history | Add-Member -MemberType NoteProperty -Name GroupID -Value $m_Group.ID
            $history | Add-Member -MemberType NoteProperty -Name EntryName -Value $m_Entry.Name
            $history | Add-Member -MemberType NoteProperty -Name SystemChanged -Value $m_Entry.SystemChanged
            $history | Add-Member -MemberType NoteProperty -Name StartTime -Value $m_Entry.History.StartTime
            $history | Add-Member -MemberType NoteProperty -Name EndTime -Value $m_Entry.History.EndTime
            $history | Add-Member -MemberType NoteProperty -Name Result -Value $m_Entry.History.Return.Result
            $history | Add-Member -MemberType NoteProperty -Name Details -Value $m_Entry.History.Return.Details

            Write-Output $history
            #Write-Output $m_Entry
        }
    }
}


# Save the output in XML format for further parsing\history
$PackDefinitionXml.Save($ResultsXml);

# Use transformation file to generate HTML report
$XSLT = New-Object System.Xml.Xsl.XslCompiledTransform;
$XSLT.Load("$CTXOE_Main\CtxOptimizerReport.xslt");
$XSLT.Transform($ResultsXml, $OutputHtml);

# If another location is requested, save the XML file here as well. 
If ($OutputXml.Length -gt 0) {
    $PackDefinitionXml.Save($OutputXml); 
}

# If the current host is trascribing, save the transcription
If (Test-IsTranscribing) {Stop-Transcript}
# SIG # Begin signature block
# MIIYRQYJKoZIhvcNAQcCoIIYNjCCGDICAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUZhLGz+zYpuCmRM4J3RShMwcx
# 57mgghMrMIID7jCCA1egAwIBAgIQfpPr+3zGTlnqS5p31Ab8OzANBgkqhkiG9w0B
# AQUFADCBizELMAkGA1UEBhMCWkExFTATBgNVBAgTDFdlc3Rlcm4gQ2FwZTEUMBIG
# A1UEBxMLRHVyYmFudmlsbGUxDzANBgNVBAoTBlRoYXd0ZTEdMBsGA1UECxMUVGhh
# d3RlIENlcnRpZmljYXRpb24xHzAdBgNVBAMTFlRoYXd0ZSBUaW1lc3RhbXBpbmcg
# Q0EwHhcNMTIxMjIxMDAwMDAwWhcNMjAxMjMwMjM1OTU5WjBeMQswCQYDVQQGEwJV
# UzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFu
# dGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMjCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBALGss0lUS5ccEgrYJXmRIlcqb9y4JsRDc2vCvy5Q
# WvsUwnaOQwElQ7Sh4kX06Ld7w3TMIte0lAAC903tv7S3RCRrzV9FO9FEzkMScxeC
# i2m0K8uZHqxyGyZNcR+xMd37UWECU6aq9UksBXhFpS+JzueZ5/6M4lc/PcaS3Er4
# ezPkeQr78HWIQZz/xQNRmarXbJ+TaYdlKYOFwmAUxMjJOxTawIHwHw103pIiq8r3
# +3R8J+b3Sht/p8OeLa6K6qbmqicWfWH3mHERvOJQoUvlXfrlDqcsn6plINPYlujI
# fKVOSET/GeJEB5IL12iEgF1qeGRFzWBGflTBE3zFefHJwXECAwEAAaOB+jCB9zAd
# BgNVHQ4EFgQUX5r1blzMzHSa1N197z/b7EyALt0wMgYIKwYBBQUHAQEEJjAkMCIG
# CCsGAQUFBzABhhZodHRwOi8vb2NzcC50aGF3dGUuY29tMBIGA1UdEwEB/wQIMAYB
# Af8CAQAwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC50aGF3dGUuY29tL1Ro
# YXd0ZVRpbWVzdGFtcGluZ0NBLmNybDATBgNVHSUEDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCAQYwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTEwDQYJKoZIhvcNAQEFBQADgYEAAwmbj3nvf1kwqu9otfrjCR27T4IGXTdf
# plKfFo3qHJIJRG71betYfDDo+WmNI3MLEm9Hqa45EfgqsZuwGsOO61mWAK3ODE2y
# 0DGmCFwqevzieh1XTKhlGOl5QGIllm7HxzdqgyEIjkHq3dlXPx13SYcqFgZepjhq
# IhKjURmDfrYwggSjMIIDi6ADAgECAhAOz/Q4yP6/NW4E2GqYGxpQMA0GCSqGSIb3
# DQEBBQUAMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3Jh
# dGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2aWNlcyBD
# QSAtIEcyMB4XDTEyMTAxODAwMDAwMFoXDTIwMTIyOTIzNTk1OVowYjELMAkGA1UE
# BhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMTQwMgYDVQQDEytT
# eW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIFNpZ25lciAtIEc0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAomMLOUS4uyOnREm7Dv+h8GEKU5Ow
# mNutLA9KxW7/hjxTVQ8VzgQ/K/2plpbZvmF5C1vJTIZ25eBDSyKV7sIrQ8Gf2Gi0
# jkBP7oU4uRHFI/JkWPAVMm9OV6GuiKQC1yoezUvh3WPVF4kyW7BemVqonShQDhfu
# ltthO0VRHc8SVguSR/yrrvZmPUescHLnkudfzRC5xINklBm9JYDh6NIipdC6Anqh
# d5NbZcPuF3S8QYYq3AhMjJKMkS2ed0QfaNaodHfbDlsyi1aLM73ZY8hJnTrFxeoz
# C9Lxoxv0i77Zs1eLO94Ep3oisiSuLsdwxb5OgyYI+wu9qU+ZCOEQKHKqzQIDAQAB
# o4IBVzCCAVMwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwcwYIKwYBBQUHAQEEZzBlMCoGCCsGAQUFBzABhh5odHRw
# Oi8vdHMtb2NzcC53cy5zeW1hbnRlYy5jb20wNwYIKwYBBQUHMAKGK2h0dHA6Ly90
# cy1haWEud3Muc3ltYW50ZWMuY29tL3Rzcy1jYS1nMi5jZXIwPAYDVR0fBDUwMzAx
# oC+gLYYraHR0cDovL3RzLWNybC53cy5zeW1hbnRlYy5jb20vdHNzLWNhLWcyLmNy
# bDAoBgNVHREEITAfpB0wGzEZMBcGA1UEAxMQVGltZVN0YW1wLTIwNDgtMjAdBgNV
# HQ4EFgQURsZpow5KFB7VTNpSYxc/Xja8DeYwHwYDVR0jBBgwFoAUX5r1blzMzHSa
# 1N197z/b7EyALt0wDQYJKoZIhvcNAQEFBQADggEBAHg7tJEqAEzwj2IwN3ijhCcH
# bxiy3iXcoNSUA6qGTiWfmkADHN3O43nLIWgG2rYytG2/9CwmYzPkSWRtDebDZw73
# BaQ1bHyJFsbpst+y6d0gxnEPzZV03LZc3r03H0N45ni1zSgEIKOq8UvEiCmRDoDR
# EfzdXHZuT14ORUZBbg2w6jiasTraCXEQ/Bx5tIB7rGn0/Zy2DBYr8X9bCT2bW+IW
# yhOBbQAuOA2oKY8s4bL0WqkBrxWcLC9JG9siu8P+eJRRw4axgohd8D20UaF5Mysu
# e7ncIAkTcetqGVvP6KUwVyyJST+5z3/Jvz4iaGNTmr1pdKzFHTx/kuDDvBzYBHUw
# ggUwMIIEGKADAgECAhAECRgbX9W7ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9v
# dCBDQTAeFw0xMzEwMjIxMjAwMDBaFw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNp
# Z25pbmcgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4R
# r2d3B9MLMUkZz9D7RZmxOttE9X/lqJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrw
# nIal2CWsDnkoOn7p0WfTxvspJ8fTeyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnC
# wlLyFGeKiUXULaGj6YgsIJWuHEqHCN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8
# y5Kh5TsxHM/q8grkV7tKtel05iv+bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM
# 0SAlI+sIZD5SlsHyDxL0xY4PwaLoLFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6f
# pjOp/RnfJZPRAgMBAAGjggHNMIIByTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGsw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcw
# AoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElE
# Um9vdENBLmNydDCBgQYDVR0fBHoweDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBP
# BgNVHSAESDBGMDgGCmCGSAGG/WwAAgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93
# d3cuZGlnaWNlcnQuY29tL0NQUzAKBghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoK
# o6XqcQPAYPkt9mV1DlgwHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8w
# DQYJKoZIhvcNAQELBQADggEBAD7sDVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+
# C2D9wz0PxK+L/e8q3yBVN7Dh9tGSdQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119E
# efM2FAaK95xGTlz/kLEbBw6RFfu6r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR
# 4pwUR6F6aGivm6dcIFzZcbEMj7uo+MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4v
# cn4c10lFluhZHen6dGRrsutmQ9qzsIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwH
# gfqL2vmCSfdibqFT+hKUGIUukpHqaGxEMrJmoecYpJpkUe8wggVaMIIEQqADAgEC
# AhAI4MABW9nbec0xTxAiIO6GMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25p
# bmcgQ0EwHhcNMTgwOTE4MDAwMDAwWhcNMTkwOTI1MTIwMDAwWjCBljELMAkGA1UE
# BhMCVVMxEDAOBgNVBAgTB0Zsb3JpZGExFzAVBgNVBAcTDkZ0LiBMYXVkZXJkYWxl
# MR0wGwYDVQQKExRDaXRyaXggU3lzdGVtcywgSW5jLjEeMBwGA1UECxMVWGVuQXBw
# KFNlcnZlciBTSEEyNTYpMR0wGwYDVQQDExRDaXRyaXggU3lzdGVtcywgSW5jLjCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMp2P2PX+npQCZbC+oFqFdQZ
# qRWgD9Cy36G3Qeo/rpfwXrLgpMBq9MVzaJezxp0ZtXnDCWfN4nTay2NFT8FNVz+O
# 81+UZTPOfor/2sywMyLm/cwkPLHTfSsixEXhwhZtTM0PQK+4yMSCLiXK5vfcdgXV
# hOvbQGO5Pe+WVlsDKl/wqBoN8EKADhpE2IO734rMkptJS38p51PB0GerWMoy8y8l
# l6t4WLAurreiJkZNdwKaZqoeVOlRAeZY1pqlua5c4mvfmysNUoog+gXHwqA7Xzko
# xs0Rh+T/0YCnFWq+lSo55QHBl+J46YBMl47zEgqAf79JMg3X1sEBwUk7NIE+9NEC
# AwEAAaOCAcUwggHBMB8GA1UdIwQYMBaAFFrEuXsqCqOl6nEDwGD5LfZldQ5YMB0G
# A1UdDgQWBBTPstFb6eXkhbO25/97NmbNDeRvhTAOBgNVHQ8BAf8EBAMCB4AwEwYD
# VR0lBAwwCgYIKwYBBQUHAwMwdwYDVR0fBHAwbjA1oDOgMYYvaHR0cDovL2NybDMu
# ZGlnaWNlcnQuY29tL3NoYTItYXNzdXJlZC1jcy1nMS5jcmwwNaAzoDGGL2h0dHA6
# Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9zaGEyLWFzc3VyZWQtY3MtZzEuY3JsMEwGA1Ud
# IARFMEMwNwYJYIZIAYb9bAMBMCowKAYIKwYBBQUHAgEWHGh0dHBzOi8vd3d3LmRp
# Z2ljZXJ0LmNvbS9DUFMwCAYGZ4EMAQQBMIGEBggrBgEFBQcBAQR4MHYwJAYIKwYB
# BQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBOBggrBgEFBQcwAoZCaHR0
# cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0U0hBMkFzc3VyZWRJRENv
# ZGVTaWduaW5nQ0EuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEB
# AO3AtSNW+NVwqEY4wHFD2TweH7BDzYqKof2cxEakTYkaD/cpywsV47ZkvaRNooOB
# C/5d+Xv+GzOB+Q+fQ8Wn7PQRPxSb+irnvYUhJ8B4BnvrFngD19P2PRz948Zwo2u5
# vQRnScBCbkGXlfrbjcryg69CFkWUQtIW76uDTrdLZ4vPZbEzJdXV28CGtjnhhgB7
# UHClutHq+DZ+1ptpjjnonLqI4IpDfo5XgRuZ5k5PVY9mRlU7QfHE5q4vCuSb6bTV
# zoIeay45wu4lVemjcFf95nOlvuap6/SambalLAemgOUzsvUOTviAJM7K9/pfIHOb
# 5eUA80pQZZZw4WStYhPZP7oxggSEMIIEgAIBATCBhjByMQswCQYDVQQGEwJVUzEV
# MBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29t
# MTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQgQ29kZSBTaWduaW5n
# IENBAhAI4MABW9nbec0xTxAiIO6GMAkGBSsOAwIaBQCggcQwGQYJKoZIhvcNAQkD
# MQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJ
# KoZIhvcNAQkEMRYEFDJH/GfKaqucKOwlNo1sf5oduwmhMGQGCisGAQQBgjcCAQwx
# VjBUoDiANgBDAGkAdAByAGkAeAAgAFMAdQBwAHAAbwByAHQAYQBiAGkAbABpAHQA
# eQAgAFQAbwBvAGwAc6EYgBZodHRwOi8vd3d3LmNpdHJpeC5jb20gMA0GCSqGSIb3
# DQEBAQUABIIBAImeIzPfcaPul5p86D0Xk+2qI0asy7m0MrUzDhHRRvyOQ1FlzR21
# yP3pThGi1z5DNep6ujoMIsBJnukgfbdAGJx/1ZQlWKDkdmxQlwG5EwL0DFx4221q
# SaD5S2tgZg2ltsYgzv+vmHHbeGojf6qvcpIvLyAX0OUKsIc5vMoajHW9Lz0F7laC
# W1iz84znuXuLrCkP4aUtU1OLQaZcLmefD4ZkInkY3z2JzxXHil7mgVxcgAF2s1zC
# 1MWX/63y/SBnjNL8NFrXnXf6Oq3315LOVdNDxpFf+UacdAkOzwanlZO1cPy+4owQ
# eu2mImXe81yY2PSuF6JZJaEAQvUjFHin8UOhggILMIICBwYJKoZIhvcNAQkGMYIB
# +DCCAfQCAQEwcjBeMQswCQYDVQQGEwJVUzEdMBsGA1UEChMUU3ltYW50ZWMgQ29y
# cG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFudGVjIFRpbWUgU3RhbXBpbmcgU2Vydmlj
# ZXMgQ0EgLSBHMgIQDs/0OMj+vzVuBNhqmBsaUDAJBgUrDgMCGgUAoF0wGAYJKoZI
# hvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMTgxMjE0MTYzNDA2
# WjAjBgkqhkiG9w0BCQQxFgQUdD3Hf7DDM1FLsdr9xkozznwcEjUwDQYJKoZIhvcN
# AQEBBQAEggEAndLuBsQCi8TydgiR4Cqrs0CgNaOxhTDzFc9dKmU+PlHPDAuEd89J
# TUUBmUypnQJSTOya2jDjV2heb0EImc+czc87VedCPwumQIT6dDo52I0DuCNsBJAb
# i10TLuoylvMR7yG5zpxrosxqWOjv9x/fUvdj3JRQSRvsNHdSFxs0s03gzBK5vEVF
# Z8vFJKBtkLwAPa/El3aw3Spjd5GpTngrodnpHsylsnp4x13dp2WxwUDazid4A9Gs
# b0rh9/qe4I7138qJGrrByQsA9KUI4T3H3xBX8QC69CnmqrXu6YSelMdDAU59Yt9K
# yogkxGS+94ca+NjKbtr0flPj+Vzm+2o8jw==
# SIG # End signature block
