param(
    [Parameter(mandatory=$true)]$Account,
    [Parameter(mandatory=$true)]$AccessToken,
    [Parameter(mandatory=$true)]$RepositoryId,
    $GitRepositoryUrl = $env:BUILD_REPOSITORY_URI
)

$dir = (Split-Path $MyInvocation.MyCommand.Path)
Import-Module "$(Join-Path $dir "VisualStudioOnline")"
Import-Module "$(Join-Path $dir "GitCommon")"

try
{
    Initialize-Git
    $remoteUrl = (Invoke-Git config remote.origin.url -ReturnOutput)
    Initialize-GitRemoteWithCredentials -GitUserName "Unused" -GitAccessToken $AccessToken -GitRepositoryUrl $GitRepositoryUrl
    
    $AuthHeader = (Get-AuthorizationHeader -AccessToken $AccessToken)
    
    (Get-ActivePullRequests -Account $Account -AuthorizationHeader $AuthHeader -RepositoryId $RepositoryId) | %{
        [PSCustomObject]@{
            SourceRef = ($_.sourceRefName -replace "refs/heads/","");
            TargetBranch = ($_.targetRefName -replace "refs/heads/","");
        }
    } | Invoke-GitRebaseAndUpdateRemote
}
finally
{
    Invoke-Git config remote.origin.url "$($remoteUrl)"
}    
