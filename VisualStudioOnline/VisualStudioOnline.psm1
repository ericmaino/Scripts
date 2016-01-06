function Get-AuthorizationHeader
{
    param(
        [Parameter(mandatory=$true)]$AccessToken
    )

    $basicAuth = ("unused:{1}" -f $cred.UserName,$AccessToken)
    $basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth)
    $basicAuth = [System.Convert]::ToBase64String($basicAuth)

    @{Authorization=("Basic {0}" -f $basicAuth)}
}


function Get-MSEng
{
    param(
        [Parameter(mandatory=$true)]$Account,
        [Parameter(mandatory=$true)]$Url,
        [Parameter(mandatory=$true)][Hashtable]$AuthorizationHeader,
        $Version = $null
    )

    [Hashtable]$headers = @{
        Accept	= "application/json";
    } 
    
    if ($version)
    {
        $headers.Accept += ";api-version=$version"
    }

    $headers += $AuthorizationHeader

    $url = "https://$($Account).visualstudio.com/DefaultCollection/$url"
    $url | Write-Verbose

    try
    {
        (Invoke-WebRequest -Uri $url -Headers $headers).Content | ConvertFrom-Json
    }
    catch
    {
        "Failed $url" | Write-Warning
        throw
    }
}

function Get-ActivePullRequests
{
    param(
        [Parameter(mandatory=$true)]$Account,
        [Parameter(mandatory=$true)][Hashtable]$AuthorizationHeader,
        [Parameter(mandatory=$true)]$RepositoryId
    )

    (Get-MSEng -Account $Account -AuthorizationHeader $AuthorizationHeader -Version "1.0" -Url "_apis/git/repositories/$($RepositoryId)/pullrequests?status=Active").value
}












