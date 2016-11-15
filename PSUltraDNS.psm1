Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Management.Automation;
using System.Net.Http;
using System.Text;
using System.Web;

namespace PSUltraDns
{
    public class Client
    {
        private Connection _connection;

        public Client()
        {
            _connection = new Connection();
        }

        public Client(PSCredential credential)
        {
            _connection = new Connection(credential);
        }

        public DateTime Expiration;
        public Connection Connection
        {
            get { return _connection; }
        }
        public bool IsValid
        {
            get { return TestSession(); }
        }

        private bool TestSession()
        {
            return (null != this.Connection.DefaultRequestHeaders.Authorization) &&
                    (DateTime.Now < this.Expiration);
        }
    }

    public class Connection : HttpClient
    {
        public Connection()
        {
            new HttpClient();
        }

        public Connection(PSCredential credential)
        {
            this.Credential = credential;
            new HttpClient();
        }

        public string RefreshToken;
        public PSCredential Credential;

        public HttpResponseMessage InvokeJsonPostRequest(string uri, string jsonContent)
        {
            StringContent content = new StringContent(jsonContent, Encoding.UTF8, "application/json");
            return this.PostAsync(uri, content).GetAwaiter().GetResult();
        }

        public HttpResponseMessage InvokeFormPostRequest(string uri, Hashtable body)
        {
            var dict = new Dictionary<string, string>(body.Count);
            foreach (DictionaryEntry pair in body)
            {
                dict.Add(pair.Key.ToString(), pair.Value.ToString());
            }
            var content = new FormUrlEncodedContent(dict);
            return this.PostAsync(uri, content).GetAwaiter().GetResult();
        }

        public HttpResponseMessage InvokeGetRequest(string uri, Hashtable body = null)
        {
            if (null != body)
            {
                var query = HttpUtility.ParseQueryString(string.Empty);
                IDictionaryEnumerator enumerator = body.GetEnumerator();
                while (enumerator.MoveNext())
                {
                    query[enumerator.Key.ToString()] = enumerator.Value.ToString();
                }
                string queryString = query.ToString();
                uri += "?" + queryString;
            }
            return this.GetAsync(uri).GetAwaiter().GetResult();
        }
    }
    
    public class UltraDnsError
    {
        public int ErrorCode;
        public string ErrorMessage;
    }
    
    public class Zone
    {
        public string AccountName;
        public string DnsSecStatus;
        public DateTime LastModifiedDateTime;
        public string Name;
        public string Owner;
        public int ResourceRecordCount;
        public string Status;
        public string Type;
        public Connection Connection;
    }

    public class RRSet
    {
        public string OwnerName;
        public string[] RData;
        public string RRType;
        public int Ttl;
    }
}
"@ -ReferencedAssemblies @('System.Net.Http', 'System.Web')
###
### Public Functions
###
function New-UltraDnsClient
{
    [CmdletBinding()]
    param
    (
        [Parameter( Mandatory=$true )]
        [System.Management.Automation.Credential()]
        [object]$Credential,

        [Parameter( Mandatory=$false )]
        [ValidateSet( 'restapi.ultradns.com', 'test-restapi.ultradns.com' )]
        [ValidateNotNull()]
        [string]$ApiHost = 'restapi.ultradns.com',

        [Parameter( Mandatory=$false )]
        [int]$ApiVersion = 2
    )

    $session = New-Object PSUltraDns.Client($Credential)
    $session.Connection.BaseAddress = "https://${ApiHost}/v${ApiVersion}/"
    SetAccessToken -Method 'Get' -Session $session
    $session | 
        Add-Member -MemberType ScriptMethod -Name Zone    -Value $ZoneMethod    -PassThru |
        Add-Member -MemberType ScriptMethod -Name Refresh -Value $RefreshMethod 
    $session.psobject.Copy()
    Remove-Variable $session -Force -ErrorAction SilentlyContinue
    [GC]::Collect()
}


### 
### Private Methods
##3 
function SetAccessToken([string]$Method, [PSUltraDns.Client]$Session)
{
    $uri = "authorization/token"
    switch ($method)
    {
        'Get'
        {  
            $credential = $Session.Connection.Credential.GetNetworkCredential()
            $body = @{
                grant_type = 'password'
                username   = $credential.UserName
                password   = $credential.Password
            }
            Remove-Variable -Name credential -Force
        }
        'Refresh'
        {
            $body = @{
                grant_type    = 'refresh_token'
                refresh_token = $Session.Connection.RefreshToken
            }
        }
    }

    $response = $Session.Connection.InvokeFormPostRequest($uri, $body)
    $content  = ParseHttpResponse($response)
    $Session.Expiration = (Get-Date).AddSeconds($content.expiresIn)
    $Session.Connection.RefreshToken = $content.refreshToken

    if ($Session.Connection.DefaultRequestHeaders.Authorization)
    {
        [void]$Session.Connection.DefaultRequestHeaders.Remove('Authorization')
    }
    $Session.Connection.DefaultRequestHeaders.Add('Authorization', "$($content.tokenType) $($content.accessToken)")
}

function ParseHttpResponse([System.Net.Http.HttpResponseMessage]$Response)
{
    $content = $Response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    if (-not $Response.IsSuccessStatusCode)
    {
        $err = ConvertObject -NewType PSUltraDns.UltraDnsError -From $content
        if ($content.error_description)
        {
            #### Login error
            throw New-Object InvalidOperationException($content.error_description)
        }
        else
        {
            #### Invalid result
            Write-Verbose "$($content.errorCode): $($content.errorMessage)"
            return
        }
    }
    
    $content
}

#### HACK!! for now...
function ConvertObject([string]$NewType, [object]$From)
{
    if ($From -isnot [pscustomobject])
    {
        $From = [pscustomobject]$From
        if ($From -isnot [pscustomobject])
        {
            throw New-Object InvalidCastException(
                "Unable to cast parameter From, of type '$($From.GetType().Name)', " +
                "to type '$NewType'."
            )
        }
    }
    $newTypeObject = New-Object $NewType
    foreach($property in $newTypeObject.PSObject.Properties.Name)
    {
        $newTypeObject.$property = $From.$property
    }
    $newTypeObject
}


###
### Hybrid Class Methods
###
#### Until JSON parsing in working in C#
#### Can't beat ConvertTo-Json/ConvertFrom-Json
$RefreshMethod = {
    if (-not ($this.IsValid) -and [String]::IsNullOrEmpty($this.Connection.RefreshToken))
    {
        throw New-Object System.ArgumentNullException (
            'The Refresh method can only be called with a valid RefreshToken.'
        )
    }
    SetAccessToken -Method 'Refresh' -Session $this
}

$ZoneMethod = {
    param 
    (
        [Parameter( Mandatory=$false )]
        [string]$ZoneName
    )
    $uri  = if ($ZoneName)
    {
        #### Return specific Zone details
        $memberName = 'properties'
        "zones/${ZoneName}"
    }
    else
    {
        #### Return all zones 
        $memberName = 'zones'
        "zones"
    }

    $response = $this.Connection.InvokeGetRequest($uri)
    $zones = (ParseHttpResponse($response)).$memberName
    if ($memberName -eq 'zones')
    {
        #### Zone Collection
        $zones = $zones.properties
    }

    foreach ($zoneResponse in $zones)
    {
        $newTypeObject = ConvertObject -NewType PSUltraDns.Zone -From $zoneResponse
        $newTypeObject.Connection = $this.Connection
        $newTypeObject | 
            Add-Member -MemberType ScriptMethod -Name CreateRRSet -Value $CreateRRSetMethod -PassThru |
            Add-Member -MemberType ScriptMethod -Name RRSet       -Value $RRSetMethod       -PassThru
    }
}

$RRSetMethod = { 
    param 
    (
        [Parameter( Mandatory=$false )]
        [ValidateSet('ANY', 'A', 'CNAME')]
        [string]$Type = 'ANY',
        
        [Parameter( Mandatory=$false )]
        [hashtable]$Options
    )

    $uri      = "zones/$($this.Name)/rrsets/${Type}"
    $response = $this.Connection.InvokeGetRequest($uri, $Options)
    $rrsets = (ParseHttpResponse($response)).rrsets
    foreach ($rrset in $rrsets)
    {
        ConvertObject -NewType PSUltraDns.RRSet -From $rrset
    }
}

$CreateRRSetMethod = {
    param 
    (
        [Parameter( Mandatory=$true )]
        [ValidateSet('A', 'CNAME')]
        [string]$Type,

        [Parameter( Mandatory=$true )]
        [string]$Owner,

        [Parameter( Mandatory=$true )]
        [string[]]$RData,

        [Parameter( Mandatory=$false )]
        [ValidateScript({ 
            if ($_ -lt 0)
            {
                throw New-Object ArgumentOutOfRangeException(
                    'Ttl', 
                    $_, 
                    'Value must be an unsigned number, with a minimum value of 0, and a maximum value of 2147483647'
                )
            } 
            return $true
        })]
        [int]$Ttl        
    )

    $uri = "zones/$($this.name)/rrsets/${Type}/${Owner}"
    $body = @{
        ttl   = $Ttl
        rdata = $RData
    }
    $json = $body | ConvertTo-Json
    $response = $this.Connection.InvokeJsonPostRequest($uri, $json)
    $message  = (ParseHttpResponse($response)).message
    if ($message -eq 'Successful')
    {
        $response = $this.Connection.InvokeGetRequest($uri, $Options)
        $rrsets = (ParseHttpResponse($response)).rrsets
        foreach ($rrset in $rrsets)
        {
            ConvertObject -NewType PSUltraDns.RRSet -From $rrset
        }
    }
}
