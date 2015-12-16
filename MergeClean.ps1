# There are no decorations on the parameters here due to VSO bugs at the moment
param(
    $SourceRef = $($Env:BUILD_SOURCEVERSION),
    $TargetBranch = "master",
    $CommitId = $null,
    $RunTests = $false,
    $PushOnSuccess = $false,
    $DeleteSourceOnSuccess = $false,
    $VerifyCommitDescriptions = $false,
    $GitUserName = "Unused",
    $GitAccessToken = $($Env:SYSTEM_ACCESSTOKEN)
)

# Build.VNext treats all parameters as strings, so we convert them to the types we actually want.
#
# Note that this means that $false will produce an error.
$RunTests = [bool]::Parse($RunTests)
$PushOnSuccess = [bool]::Parse($PushOnSuccess)
$VerifyCommitDescriptions = [bool]::Parse($VerifyCommitDescriptions)
$DeleteSourceOnSuccess = [bool]::Parse($DeleteSourceOnSuccess)
$Secrets = @()
$ScriptDir = (Split-Path $MyInvocation.MyCommand.Path)

function Execute-Script
{
    param
    (
        [Parameter(mandatory=$true)]
        [String]
        $TargetBranch,
        [Parameter(mandatory=$true)]
        [String]
        $SourceRef
    )

    "Merging '$SourceRef' into target branch '$TargetBranch'" | Write-Host
    Invoke-Git status

    git config user.name "Automated Service Account ($($env:USERNAME))"
    git config user.email "$($env:USERNAME)@microsoft.com"
    git config push.default simple
    
    try
    {
        # There is likely a better way to do this, but for now this works
        if ($GitUserName -and $GitAccessToken)
        {
            $Secrets += @($GitAccessToken)
            git config remote.origin.url "https://$($GitUserName):$($GitAccessToken)@$(($env:BUILD_REPOSITORY_URI -split "https://" | Out-String).Trim())"
        }
   
        $SourceBranch = Get-NormalizedBranch $SourceRef

        if ($SourceBranch.Length -eq 40)
        {
            $CommitId = $SourceBranch
        }

        if ($CommitId)
        {
            Invoke-Git reset --hard $CommitId
        }
        else
        {
            Invoke-Git checkout --detach -SuppressOutput
            Invoke-Git fetch origin "+$($SourceBranch):$($SourceBranch)"
            Invoke-Git checkout $SourceBranch
        }
        Invoke-Git clean -fdx

        if ($DeleteSourceOnSuccess -and ($SourceBranch -ieq "master"))
        {
            throw "master is not supported as a source reference when deleting"
        }

        if ($VerifyCommitDescriptions) {
            Invoke-Git fetch origin +$($TargetBranch):$($TargetBranch)
            VerifyCommitDescriptions $TargetBranch "HEAD"
            VerifyCommiterName $TargetBranch "HEAD"
        }

        $result = Invoke-WithMutex -MutexName "GitMergeLock" -ScriptBlock {
            Git-Rebase $TargetBranch
        
            "Validating preserved merges are clean and allowed" | Write-Host
            if (!((Get-CommitWithParents -TargetRef $TargetBranch -HeadRef "HEAD") | Test-GitMerge))
            {
                throw "Invalid merge detected"
            }

            $headRef = (Invoke-Git rev-parse HEAD -ReturnOutput)
            Invoke-Git checkout -q $TargetBranch
            Invoke-Git merge --ff-only $headRef

            if ($PushOnSuccess) {
                Invoke-Git push origin "$($TargetBranch):$($TargetBranch)"
                if ($DeleteSourceOnSuccess)
                {
                    Invoke-Git push origin ":$($SourceRef)"
                }
            }
        }

        if (!$result)
        {
            throw "Failed to merge sources. Timed out waiting in the queue"
        }
    }
    finally
    {
        git config --unset remote.origin.url
    }
}

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
        $commandOutput = Remove-Secrets -InputWithSecret $commandOutput -Secrets $Secrets
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

function Git-Rebase
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

function Remove-Secrets
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

function Throw-IfMatches
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

function VerifyCommitDescriptions($Start,$End)
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


function VerifyCommiterName($Start,$End)
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


function Run-Test 
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

function Throw-OnFailure
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

if ($RunTests)
{
    # Add useful tests here for your repo. These are examples from a previous repo
    # TODO: Push commits to this repo that demonstrate invalid commits

    #Run-Test "Clean FF Merge" { (Get-CommitWithParents -HeadRef a89303f45d0cccb02bda249ca0fbcb5ad6f57bfd -TargetRef 6985f240bfe1ae91e573c5acf320066024e15b70) | Test-GitMerge }
    #Run-Test "Invalid merge" { (Get-CommitWithParents -HeadRef ac0a736281b62c89623d84d0ab41c9aab10a68f0 -TargetRef 3e8ca9043c0ec3a29b86ea35dd9f8ca0a56e3512 ) | Test-GitMerge } -ExpectsFailure
    #Run-Test "Invalid merge" { (Get-CommitWithParents -HeadRef 11f0ca4539fe76fab1cddf3db544cca72a33ea03 -TargetRef 4d170584624076762dffb95603cb9bf77c0ae2e5 ) | Test-GitMerge } -ExpectsFailure
    #Run-Test "Already up to date" { (Get-CommitWithParents -HeadRef 4d170584624076762dffb95603cb9bf77c0ae2e5 -TargetRef 4d170584624076762dffb95603cb9bf77c0ae2e5) | Test-GitMerge } -ExpectsFailure 
    #
    #Run-Test "Happy path Get-BadCommitDescriptions" { VerifyCommitDescriptions aef7b01 6af856c } 
    #Run-Test "Squashed commit of the following:" { VerifyCommitDescriptions a4117 57695b3  | Out-Null } -ExpectsException
    #Run-Test "Merge Branch" { VerifyCommitDescriptions 9f3b5 3fcb63 | Out-Null } -ExpectsException
    #
    #Run-Test "Clean names" { VerifyCommiterName b1b371d a1fd1f0; $true }
    #Run-Test "Invalid single name" { VerifyCommiterName a9a2129 dca8d65 | Out-Null } -ExpectsException
    #Run-Test "Invalid multi name" { VerifyCommiterName 9cf7e90 7643763 | Out-Null } -ExpectsException
    
}
else
{
    Execute-Script -TargetBranch $TargetBranch -SourceRef $SourceRef
}

#VSO HACK
$Global:LastExitCode = 0