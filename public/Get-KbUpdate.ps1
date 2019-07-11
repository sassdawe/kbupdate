function Get-KbUpdate {
    <#
    .SYNOPSIS
        Gets download links and detailed information for KB files (SPs/hotfixes/CUs, etc)

    .DESCRIPTION
        Parses catalog.update.microsoft.com and grabs details for KB files (SPs/hotfixes/CUs, etc)

        Because Microsoft's RSS feed does not work, the command has to parse a few webpages which can result in slowness.

        Use the Simple parameter for simplified output and faster results.

    .PARAMETER Name
        The KB name or number. For example, KB4057119 or 4057119.

    .PARAMETER Architecture
        Can be x64, x86, ia64 or "All". Defaults to All.

    .PARAMETER Simple
        A lil faster. Returns, at the very least: Title, Architecture, Language, Hotfix, UpdateId and Link

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Update
        Author: Chrissy LeMaire (@cl), netnerds.net
        Copyright: (c) licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .EXAMPLE
        PS C:\> Get-KbUpdate -Name KB4057119

        Gets detailed information about KB4057119. This works for SQL Server or any other KB.

    .EXAMPLE
        PS C:\> Get-KbUpdate -Name KB4057119, 4057114

        Gets detailed information about KB4057119 and KB4057114. This works for SQL Server or any other KB.

    .EXAMPLE
        PS C:\> Get-KbUpdate -Name KB4057119, 4057114 -Simple

        A lil faster. Returns, at the very least: Title, Architecture, Language, Hotfix, UpdateId and Link
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name,
        [ValidateSet("x64", "x86", "ia64", "All")]
        [string]$Architecture = "All",
        [switch]$Simple,
        [switch]$EnableException
    )
    begin {
        # Wishing Microsoft offered an RSS feed. Since they don't, we are forced to parse webpages.
        function Get-Info ($Text, $Pattern) {
            if ($Pattern -match "labelTitle") {
                # this should work... not accounting for multiple divs however?
                [regex]::Match($Text, $Pattern + '[\s\S]*?\s*(.*?)\s*<\/div>').Groups[1].Value
            } elseif ($Pattern -match "span ") {
                [regex]::Match($Text, $Pattern + '(.*?)<\/span>').Groups[1].Value
            } else {
                [regex]::Match($Text, $Pattern + "\s?'?(.*?)'?;").Groups[1].Value
            }
        }

        function Get-SuperInfo ($Text, $Pattern) {
            # this works, but may also summon cthulhu
            $span = [regex]::match($Text, $pattern + '[\s\S]*?<div id')

            switch -Wildcard ($span.Value) {
                "*div style*" { $regex = '">\s*(.*?)\s*<\/div>' }
                "*a href*" { $regex = "<div[\s\S]*?'>(.*?)<\/a" }
                default { $regex = '"\s?>\s*(\S+?)\s*<\/div>'}
            }

            [regex]::Matches($span, $regex).ForEach( { $_.Groups[1].Value })
        }

        $baseproperties = "Title",
        "Description",
        "Architecture",
        "Language",
        "Classification",
        "SupportedProducts",
        "MSRCNumber",
        "MSRCSeverity",
        "Hotfix",
        "Size",
        "UpdateId",
        "RebootBehavior",
        "RequestsUserInput",
        "ExclusiveInstall",
        "NetworkRequired",
        "UninstallNotes",
        "UninstallSteps",
        "SupersededBy",
        "Supersedes",
        "LastModified",
        "Link"
    }
    process {
        foreach ($kb in $Name) {
            Write-Progress -Activity "Getting information for $kb" -Id 1
            try {
                # Thanks! https://keithga.wordpress.com/2017/05/21/new-tool-get-the-latest-windows-10-cumulative-updates/
                $kb = $kb.Replace("KB", "").Replace("kb", "").Replace("Kb", "")

                $results = Invoke-TlsWebRequest -Uri "http://www.catalog.update.microsoft.com/Search.aspx?q=KB$kb" -UseBasicParsing -ErrorAction Stop

                $kbids = $results.InputFields |
                    Where-Object { $_.type -eq 'Button' -and $_.Value -eq 'Download' } |
                    Select-Object -ExpandProperty  ID

                if (-not $kbids) {
                    try {
                        $null = Invoke-TlsWebRequest -Uri "https://support.microsoft.com/app/content/api/content/help/en-us/$kb" -UseBasicParsing -ErrorAction Stop
                        Stop-PSFFunction -Message "KB$kb was found but has been removed from the catalog"
                        return
                    } catch {
                       Stop-PSFFunction -Message "No results found for $kb"
                        return
                    }
                }

                Write-PSFMessage -Level Verbose -Message "$kbids"

                $guids = $results.Links |
                    Where-Object ID -match '_link' |
                    Where-Object { $_.OuterHTML -match ( "(?=.*" + ( $Filter -join ")(?=.*" ) + ")" ) } |
                    ForEach-Object { $_.id.replace('_link', '') } |
                    Where-Object { $_ -in $kbids }

                foreach ($guid in $guids) {
                    Write-PSFMessage -Level Verbose -Message "Downloading information for $guid"
                    $post = @{ size = 0; updateID = $guid; uidInfo = $guid } | ConvertTo-Json -Compress
                    $body = @{ updateIDs = "[$post]" }
                    $downloaddialog = Invoke-TlsWebRequest -Uri 'http://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -UseBasicParsing -ErrorAction Stop | Select-Object -ExpandProperty Content


                    $title = Get-Info -Text $downloaddialog -Pattern 'enTitle ='
                    $arch = Get-Info -Text $downloaddialog -Pattern 'architectures ='
                    $longlang = Get-Info -Text $downloaddialog -Pattern 'longLanguages ='
                    $updateid = Get-Info -Text $downloaddialog -Pattern 'updateID ='
                    $ishotfix = Get-Info -Text $downloaddialog -Pattern 'isHotFix ='

                    if ($ishotfix) {
                        $ishotfix = "True"
                    } else {
                        $ishotfix = "False"
                    }
                    if ($longlang -eq "all") {
                        $longlang = "All"
                    }
                    if ($arch -eq "") {
                        $arch = $null
                    }
                    if ($arch -eq "AMD64") {
                        $arch = "x64"
                    }
                    if ($title -match '64-Bit' -and $title -notmatch '32-Bit' -and -not $arch) {
                        $arch = "x64"
                    }
                    if ($title -notmatch '64-Bit' -and $title -match '32-Bit' -and -not $arch) {
                        $arch = "x86"
                    }

                    if ($arch -and $Architecture -ne "All" -and $arch -ne $Architecture) {
                        continue
                    }

                    if (-not $Simple) {
                        $detaildialog = Invoke-TlsWebRequest -Uri "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$updateid" -UseBasicParsing -ErrorAction Stop
                        $description = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_desc">'
                        $lastmodified = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_date">'
                        $size = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_size">'
                        $classification = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_labelClassification_Separator" class="labelTitle">'
                        $supportedproducts = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_labelSupportedProducts_Separator" class="labelTitle">'
                        $msrcnumber = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_labelSecurityBulliten_Separator" class="labelTitle">'
                        $msrcseverity = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_msrcSeverity">'
                        $rebootbehavior = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_rebootBehavior">'
                        $requestuserinput = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_userInput">'
                        $exclusiveinstall = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_installationImpact">'
                        $networkrequired = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_connectivity">'
                        $uninstallnotes = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_labelUninstallNotes_Separator" class="labelTitle">'
                        $uninstallsteps = Get-Info -Text $detaildialog -Pattern '<span id="ScopedViewHandler_labelUninstallSteps_Separator" class="labelTitle">'
                        $supersededby = Get-SuperInfo -Text $detaildialog -Pattern '<div id="supersededbyInfo" TABINDEX="1" >'
                        $supersedes = Get-SuperInfo -Text $detaildialog -Pattern '<div id="supersedesInfo" TABINDEX="1">'

                        $product = $supportedproducts -split ","
                        if ($product.Count -gt 1) {
                            $supportedproducts = @()
                            foreach ($line in $product) {
                                $clean = $line.Trim()
                                if ($clean) { $supportedproducts += $clean }
                            }
                        }
                    }

                    $links = $downloaddialog | Select-String -AllMatches -Pattern "(http[s]?\://download\.windowsupdate\.com\/[^\'\""]*)" | Select-Object -Unique

                    foreach ($link in $links) {
                        $properties = $baseproperties

                        if ($Simple) {
                            $properties = $properties | Where-Object { $PSItem -notin "LastModified", "Description", "Size", "Classification", "SupportedProducts", "MSRCNumber", "MSRCSeverity", "RebootBehavior", "RequestsUserInput", "ExclusiveInstall", "NetworkRequired", "UninstallNotes", "UninstallSteps", "SupersededBy", "Supersedes" }
                        }

                        [pscustomobject]@{
                            Title             = $title
                            Architecture      = $arch
                            Language          = $longlang
                            Hotfix            = $ishotfix
                            Description       = $description
                            LastModified      = $lastmodified
                            Size              = $size
                            Classification    = $classification
                            SupportedProducts = $supportedproducts
                            MSRCNumber        = $msrcnumber
                            MSRCSeverity      = $msrcseverity
                            RebootBehavior    = $rebootbehavior
                            RequestsUserInput = $requestuserinput
                            ExclusiveInstall  = $exclusiveinstall
                            NetworkRequired   = $networkrequired
                            UninstallNotes    = $uninstallnotes
                            UninstallSteps    = $uninstallsteps
                            UpdateId          = $updateid
                            Supersedes        = $supersedes
                            SupersededBy      = $supersededby
                            Link              = $link.matches.value
                        } | Select-DefaultView -Property $properties
                    }
                }
            } catch {
                Stop-PSFFunction -Message "Failure" -ErrorRecord $_ -Continue
            }
            Write-Progress -Activity "Getting information for $kb" -Id 1 -Completed
        }
    }
}