function Invoke-Git
{
    param(
        [Switch]
        $ReturnOutput,

        [Switch]
        $IgnoreError,

        [Switch]
        $SuppressOutput
    )

    Write-Host "Executing 'git $args'"

    $commandOutput = (git $args 2>&1)

    if ($Secrets)
    {
        $commandOutput = Hide-Secrets -InputWithSecret $commandOutput -Secrets $Secrets
    }

    if (!$SuppressOutput)
    {
        $commandOutput | Write-Host
    }

    if (!$IgnoreError -and $LASTEXITCODE) 
    { 
        throw "Error executing 'git $args': $commandOutput" 
    }

    if ($ReturnOutput)
    {
        $commandOutput
    }
}

function Invoke-GitRebase
{
    param(
        [Parameter(mandatory=$true)]
        [String]
        $TargetBranch
    )

    try
    {
        Invoke-Git fetch origin +$($TargetBranch):$($TargetBranch)
        Invoke-Git rebase --preserve-merges $targetBranch
    }
    catch 
    {
        
        Invoke-Git rebase --abort -IgnoreError
        Invoke-Git clean -fd
        throw
    }
}

function Get-NormalizedBranch
{
    param(
        [Parameter(mandatory=$true)]
        [String]
        $branch
    )

    "Normalizing branch '$branch'" | Write-Host

    if ($branch -ilike "refs/heads/*")
    {
        $branch = $branch.Substring(11)
    }

    $branch
}

function Hide-Secrets
{
    param(
        $InputWithSecret,
        $Secrets
    )
    
    foreach ($secret in $Secrets)
    {
        $InputWithSecret = $InputWithSecret -replace $Secret,"*****" 
    }

    $InputWithSecret
}

function Get-CommitWithParents
{
    param(
        [Parameter(mandatory=$true)]
        [String]
        $HeadRef,
        [Parameter(mandatory=$true)]
        [String]
        $TargetRef
    )

    Invoke-Git rev-list --parents "$($TargetRef)..$($HeadRef)" -ReturnOutput 
}

function Test-GitMerge
{
    param(
        [Parameter(valueFromPipeline=$true)]
        $commit
    )

    Begin
    {
        $expectedEnd = $null
        $expectedNext = $null
        $result = $null
    }
    Process
    {
        if (!$commit)
        {
            $result = $false
            return
        }

        $parents = $commit -split " "
        $currentCommit = $parents[0]

        "Validating commit $currentCommit" | Write-Host

        if ($expectedNext -and $expectedNext -ne $currentCommit)
        {
            "Commit $($currentCommit) appears to be out of place" | Write-Warning
            $result = $false
        }

        $expectedNext = $parents | select -last 1

        if ($expectedNext -eq $expectedEnd)
        {
            $expectedEnd = $null
        }

        if ($parents.Length -eq 3)
        {
            if ($expectedEnd)
            {
                "Invalid merge commit $($currentCommit)" | Write-Warning
                $result = $false
            }

            $expectedEnd = $parents[1]
        }

        if ($result -eq $null)
        {
            $result = $true
        }
    }
    End
    {
        if ($result -eq $null)
        {
            "No commits were detected to merge" | Write-Warning
            $result = $false
        }

        if ($expectedEnd)
        {
            "Invalid merge detected" | Write-Warning
            $result = $false
        }
        $result
    }
}

function Exit-IfMatches
{
    param(
        [Parameter(mandatory=$true,valueFromPipeline=$true)]
        $Commit,
        [Parameter(mandatory=$true,position=0)]
        $MatchExpression
    )

    process 
    {
        if ($Commit -imatch $MatchExpression)
        {
            throw "Invalid commit detected. The following commit matches expression '$MatchExpression'.`n$Commit"
        }

        $Commit
    }
}

function Test-CommitDescriptions($Start,$End)
{
    @(Invoke-Git log --pretty=format:%s "$Start..$End" -ReturnOutput) |  
        Throw-IfMatches '^WIP' |
        Throw-IfMatches '^TEMP' |
        Throw-IfMatches '^fixup!' |
        Throw-IfMatches '^!fixup' |
        Throw-IfMatches '^squash!' |
        Throw-IfMatches '^!squash' |
        Throw-IfMatches "^Squashed commit of the following" |
        Throw-IfMatches "^Merge branch '" |
        Throw-IfMatches '#$' 
}


function Test-CommitterName($Start,$End)
{
    @(Invoke-Git log --pretty=format:%an "$Start..$End" -ReturnOutput) | %{
        $names = $_ -split ' '
        
        if (($names | Measure).Count -ne 2)
        {
            throw "Commiter name '$name' appears to be invalid. Commiter name should contain a first and last name with a single space."
        }
    }
}

function Invoke-WithMutex
{
    param(
        [Parameter(mandatory=$true)]
        [String]
        $MutexName,

        [Parameter(mandatory=$true,valueFromPipeline=$true)]
        [ScriptBlock]
        $ScriptBlock,

        [TimeSpan]
        $TimeOut = [TimeSpan]::FromMinutes(15)

    )
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquiredLock = $false

    $acquiredLock = $mutex.WaitOne($TimeOut)

    if ($acquiredLock)
    {
        try
        {
            Invoke-Command -ScriptBlock $ScriptBlock
        }
        finally
        {
            $mutex.ReleaseMutex()
        }
    }

    $acquiredLock
}


function Invoke-GitTest 
{
    param(
        [Parameter(mandatory=$true,position=0)]
        [String]
        $Name,
        [Parameter(mandatory=$true,position=1)]
        [ScriptBlock]
        $TestScript,
        [Switch]
        $ExpectsFailure,
        [Switch]
        $ExpectsException
    )

    $testResult = $null
    $exception = $null

    try
    {
        $testResult =  (& $TestScript)
        $testResult = $true -and $testResult
    }
    catch 
    {
        if ($ExpectsException)
        {
            $testResult = $true
        }
        else
        {
            $exception = $_
        }            
    }

    if ($exception -or $testResult -ne (!$ExpectsFailure))
    {
        
        "FAILED: $Name" | Write-Host -ForegroundColor Red
        
        if ($exception)
        {
            "UNEXPECTED EXCEPTION" | Write-Host -ForegroundColor Red
            $exception | Write-Host -ForegroundColor Red
        }
    }
    else
    {
        "SUCCESSFUL: $Name" | Write-Host -ForegroundColor Green
    }
}

function Exit-OnFailure
{
    param(
        [Parameter(mandatory=$true,valueFromPipeline=$true)]
        $Result
    )

    Process
    {
        if (!$Result)
        {
            throw "Unexpected test failure"
        }
    }
}

function Initialize-Git
{
    git config user.name "Automated Service Account ($($env:USERNAME))"
    git config user.email "$($env:USERNAME)@microsoft.com"
    git config push.default simple
}

function Initialize-GitRemoteWithCredentials
{
    param
    (
        [Parameter(mandatory=$true)]
        [String]
        $GitUserName,

        [Parameter(mandatory=$true)]
        [String]
        $GitAccessToken,

        [Parameter(mandatory=$true)]
        [String]
        $GitRepositoryUrl,

        [String]
        $Remote = "origin"
    )

    git config "remote.$($Remote).url" "https://$($GitUserName):$($GitAccessToken)@$(($GitRepositoryUrl -split "https://" | Out-String).Trim())"
}

function Invoke-GitRebaseAndUpdateRemote
{
    param
    (
        [Parameter(valueFromPipeline=$true)]
        $Pipeline,
        [Parameter(mandatory=$true,valueFromPipelineByPropertyName=$true)]
        [String]
        $TargetBranch,
        [Parameter(mandatory=$true,valueFromPipelineByPropertyName=$true)]
        [String]
        $SourceRef
    )
    
    process
    {
        "Rebasing '$SourceRef' onto target branch '$TargetBranch'" | Write-Host
        Invoke-Git status
        
        $SourceBranch = Get-NormalizedBranch $SourceRef
    
        Invoke-Git checkout --detach -SuppressOutput
        Invoke-Git fetch origin "+$($SourceBranch):$($SourceBranch)"
        Invoke-Git reset --hard $SourceBranch
        Invoke-Git clean -fdx
    
        Invoke-GitRebase $TargetBranch
        Invoke-Git push origin "+HEAD:$($SourceBranch)"
    }
}