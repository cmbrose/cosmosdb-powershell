$DB_TYPE = "dbs" # aka Container
$COLLS_TYPE = "colls"
$DOCS_TYPE = "docs"
$PARTITIONKEYRANGE_TYPE = "pkranges"

$GET_VERB = "get"
$POST_VERB = "post"
$PUT_VERB = "put"
$DELETE_VERB = "delete"

$API_VERSION = "2018-12-31"

# Authorization headers are valid for 15 minutes
# https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key#specifying-the-date-header
$AUTHORIZATION_HEADER_REFRESH_THRESHOLD = [System.TimeSpan]::FromMinutes(10);

$MASTER_KEY_CACHE = @{}
$AAD_TOKEN_CACHE = @{}
$SIGNATURE_HASH_CACHE = @{}
$PARTITION_KEY_RANGE_CACHE = @{}

Function Get-BaseDatabaseUrl([string]$Database) {
    return "https://$Database.documents.azure.com"
}

Function Get-CollectionsUrl([string]$Container, [string]$Collection) {
    return "$DB_TYPE/$Container/$COLLS_TYPE/$Collection"
}

# Returns an object with the properties ApiUrl and ResourceUrl.
# - ApiUrl uses an escaped version of the RecordId to support having characters such as '/' in the record Id and should be used as the API url (e.g. Invoke-WebRequest)
# - ResourceUrl uses the raw RecordId and should be used in the auth header (e.g. Get-AuthorizationHeader)
Function Get-DocumentsUrl([string]$Container, [string]$Collection, [string]$RecordId) {
    $collectionsUrl = Get-CollectionsUrl $Container $Collection
    $encodedRecordId = [uri]::EscapeDataString($RecordId)

    return @{
        ApiUrl      = "$collectionsUrl/$DOCS_TYPE/$encodedRecordId";
        ResourceUrl = "$collectionsUrl/$DOCS_TYPE/$RecordId";
    }
}

Function Get-Time() {
    Get-Date ([datetime]::UtcNow) -Format "R"
}

Function Get-CacheValue([string]$key, [hashtable]$cache) {
    if ($env:COSMOS_DB_FLAG_ENABLE_CACHING -eq 0) {
        return $null
    }

    $cacheEntry = $cache[$key]

    if ($cacheEntry -and ($cacheEntry.Expiration -gt [datetime]::UtcNow)) {
        return $cacheEntry.Value
    }

    return $null
}

Function Set-CacheValue([string]$key, $value, [hashtable]$cache, [int]$expirationHours, [int]$expirationMinutes) {
    $cache[$key] = @{ 
        Expiration = [datetime]::UtcNow.AddHours($expirationHours).AddMinutes($expirationMinutes);
        Value      = $value 
    }
}

Function RequireWriteableKey() {
    # Entra Id auth does not support read only tokens (because it's just handled by RBAC).
    # So if the user requested to be in read only mode, we have to manage it ourselves.

    $readonlyEnabled = $env:COSMOS_DB_FLAG_ENABLE_READONLY_KEYS -eq 1
    if ($readonlyEnabled) {
        throw "Operation not allowed in readonly mode"
    }
}

Function Get-Base64Masterkey([string]$ResourceGroup, [string]$Database, [string]$SubscriptionId) {
    $readonly = $env:COSMOS_DB_FLAG_ENABLE_READONLY_KEYS -eq 1

    $cacheKey = "$SubscriptionId/$ResourceGroup/$Database/$readonly"
    $cacheResult = Get-CacheValue -Key $cacheKey -Cache $MASTER_KEY_CACHE
    if ($cacheResult) {
        return $cacheResult
    }

    $masterKey = Get-Base64MasterkeyWithoutCaching -ResourceGroup $ResourceGroup -Database $Database -SubscriptionId $SubscriptionId -Readonly $readonly

    Set-CacheValue -Key $cacheKey -Value $masterKey -Cache $MASTER_KEY_CACHE -ExpirationHours 6

    $masterKey
}

# This is just to support testing caching with Get-Base64Masterkey and isn't meant to be used directly
Function Get-Base64MasterkeyWithoutCaching([string]$ResourceGroup, [string]$Database, [string]$SubscriptionId, [bool]$Readonly) {
    $query = if ($readonly) {
        "primaryReadonlyMasterKey"
    }
    else {
        "primaryMasterKey"
    }

    if ($SubscriptionId) {
        $masterKey = az cosmosdb keys list --name $Database --query $query --output tsv --resource-group $ResourceGroup --subscription $SubscriptionId
    }
    else {
        $masterKey = az cosmosdb keys list --name $Database --query $query --output tsv --resource-group $ResourceGroup
    }

    $masterKey
}

Function Get-AADToken([string]$ResourceGroup, [string]$Database, [string]$SubscriptionId) {
    $cacheKey = "aadtoken"
    $cacheResult = Get-CacheValue -Key $cacheKey -Cache $AAD_TOKEN_CACHE
    if ($cacheResult) {
        return $cacheResult
    }

    $oauth = Get-AADTokenWithoutCaching
    $token = $oauth.AccessToken

    $expirationUtcTimestamp = $oauth.expires_on
    $expiration = [System.DateTimeOffset]::FromUnixTimeSeconds($expirationUtcTimestamp).DateTime
    $remainingTime = $expiration - [System.DateTime]::UtcNow
    $cacheExpirationMinutes = ($remainingTime - $AUTHORIZATION_HEADER_REFRESH_THRESHOLD).Minutes

    Set-CacheValue -Key $cacheKey -Value $token -Cache $AAD_TOKEN_CACHE -ExpirationMinutes $cacheExpirationMinutes

    $token
}

# This is just to support testing caching with Get-AADToken and isn't meant to be used directly
Function Get-AADTokenWithoutCaching() {
    az account get-access-token --resource "https://cosmos.azure.com" | ConvertFrom-Json
}

Function Get-Signature([string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now) {
    $parts = @(
        $verb.ToLower(),
        $resourceType.ToLower(),
        $resourceUrl,
        $now.ToLower(),
        ""
    )
    (($parts -join "`n") + "`n")
}

Function Get-Base64EncryptedSignatureHash([string]$masterKey, [string]$signature) {
    $cacheKey = "$masterKey/$signature"
    $cacheResult = Get-CacheValue -Key $cacheKey -Cache $SIGNATURE_HASH_CACHE
    if ($cacheResult) {
        return $cacheResult
    }

    $keyBytes = [System.Convert]::FromBase64String($masterKey)
    $hasher = New-Object System.Security.Cryptography.HMACSHA256 -Property @{ Key = $keyBytes }
    $sigBinary = [System.Text.Encoding]::UTF8.GetBytes($signature)
    $hashBytes = $hasher.ComputeHash($sigBinary)
    $base64Hash = [System.Convert]::ToBase64String($hashBytes)

    Set-CacheValue -Key $cacheKey -Value $base64Hash -Cache $SIGNATURE_HASH_CACHE -ExpirationHours 1

    $base64Hash
}

Function Get-EncodedAuthString([string]$signatureHash, [string]$type) {
    $authString = "type=$type&ver=1.0&sig=$signatureHash"
    [uri]::EscapeDataString($authString)
}

Function Get-AuthorizationHeader([string]$ResourceGroup, [string]$SubscriptionId, [string]$Database, [string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now) {            
    if ($env:COSMOS_DB_FLAG_ENABLE_MASTER_KEY_AUTH -eq 1) {
        $masterKey = Get-Base64Masterkey -ResourceGroup $ResourceGroup -Database $Database -SubscriptionId $SubscriptionId
        
        $signature = Get-Signature -verb $verb -resourceType $resourceType -resourceUrl $resourceUrl -now $now
    
        $signatureHash = Get-Base64EncryptedSignatureHash -masterKey $masterKey -signature $signature
    
        return Get-EncodedAuthString -signatureHash $signatureHash -type "master"
    }

    $token = Get-AADToken

    return Get-EncodedAuthString -signatureHash $token -type "aad"
}

Function Get-CommonHeaders([string]$now, [string]$encodedAuthString, [string]$contentType = "application/json", [bool]$isQuery = $false, [string]$PartitionKey = $null, [string]$Etag = $null) {
    $headers = @{ 
        "x-ms-version"  = $API_VERSION;
        "Cache-Control" = "No-Cache";
        "Content-Type"  = $contentType;
    }

    Set-AuthHeaders -headers $headers -now $now -encodedAuthString $encodedAuthString

    if ($isQuery) {
        $headers["x-ms-documentdb-isquery"] = "true"
    }

    if ($PartitionKey) {
        $headers["x-ms-documentdb-partitionkey"] = "[`"$PartitionKey`"]"
    }
	
    if ($Etag) {
        $headers["If-Match"] = $Etag
    }

    $headers
}

Function Set-AuthHeaders($headers, [string]$now, [string]$encodedAuthString) {
    if ($now) {
        $headers["x-ms-date"] = $now
    }

    if ($encodedAuthString) {
        $headers["Authorization"] = $encodedAuthString
    }
}

Function Get-QueryParametersAsNameValuePairs($obj) {
    if (!$obj) {
        return @()
    }

    if ($obj -is [array]) {
        return $obj
    }

    if ($obj -is [hashtable]) {
        return $obj.Keys | % { $nvs = @() } { $nvs += @{ name = $_; value = $obj.$_ } } { $nvs }
    }

    $type = $obj.GetType()
    throw "Cannot convert type $type to Name-Value pairs"
}

Function Get-ExceptionResponseOrThrow($err) {
    # Because PS Desktop and Core use different exception types for HTTP errors, it's hard to extract the content is a consistent
    # manner. Instead, this is used on exceptions to just pull out the details which are most useful (those needed by Get-CosmosDbRecordContent)
    # into a consistent wrapper object. The raw HTTP response object is included for debugging, but will be inconsistently typed
    # based on the platform. As more fields are needed, they can been pulled out into the wrapper.

    if ($err.Exception.Response) {
        $msg = @{
            StatusCode  = $err.Exception.Response.StatusCode;
            RawResponse = $err.Exception.Response;
        }

        if ($PSVersionTable.PSEdition -eq "Core") {
            # In PS Core, the body is eaten and put into this message
            # See: https://stackoverflow.com/questions/18771424/how-to-get-powershell-invoke-restmethod-to-return-body-of-http-500-code-response
            $msg.Content = $err.ErrorDetails.Message
        }
        else {
            # In Desktop we can re-read the content stream
            $result = $err.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($result)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()

            $msg.Content = $reader.ReadToEnd()
        }

        return [PSCustomObject]$msg
    }
    else {
        throw $err.Exception
    }
}

Function Invoke-CosmosDbApiRequest([string]$verb, [string]$url, $headers, $body = $null) {
    if ($body) {
        $body = $body | ConvertTo-Json -Depth 100
    }

    Invoke-WebRequest -Method $verb -Uri $url -Body $body -Headers $headers
}

Function Get-ContinuationToken($response) {
    $value = $response.Headers["x-ms-continuation"]

    if ($PSVersionTable.PSEdition -eq "Core") {
        if (-not $value) {
            return $null
        }

        # Headers were changed to arrays in version 7
        # https://docs.microsoft.com/en-us/powershell/scripting/whats-new/breaking-changes-ps6?view=powershell-7.1#changes-to-web-cmdlets
        $value[0]
    }
    else {
        $value
    }
}

Function Invoke-CosmosDbApiRequestWithContinuation([string]$verb, [string]$url, $headers, [ScriptBlock]$refreshAuthHeaders, $body = $null) {
    # Remove in case the headers are reused between multiple calls to this function
    $headers.Remove("x-ms-continuation");

    $authHeaders = Invoke-Command -ScriptBlock $refreshAuthHeaders
    Set-AuthHeaders -headers $headers -now $authHeaders.now -encodedAuthString $authHeaders.encodedAuthString

    $response = Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $body -Headers $headers
    $response

    $continuationToken = Get-ContinuationToken $response
    while ($continuationToken) {
        $headers["x-ms-continuation"] = $continuationToken

        $authHeaderReuseDisabled = $env:COSMOS_DB_FLAG_ENABLE_AUTH_HEADER_REUSE -eq 0
        $authHeaderExpired = [System.DateTimeOffset]::Parse($authHeaders.now) + $AUTHORIZATION_HEADER_REFRESH_THRESHOLD -lt [System.DateTime]::UtcNow
        
        if ($authHeaderReuseDisabled -or $authHeaderExpired) {
            $authHeaders = Invoke-Command -ScriptBlock $refreshAuthHeaders
            Set-AuthHeaders -headers $headers -now $authHeaders.now -encodedAuthString $authHeaders.encodedAuthString
        }

        $response = Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $body -Headers $headers
        $response

        $continuationToken = Get-ContinuationToken $response
    }
}

Function Get-PartitionKeyRangesOrError
(
    [parameter(Mandatory = $true)][string]$ResourceGroup,
    [parameter(Mandatory = $true)][string]$Database, 
    [parameter(Mandatory = $true)][string]$Container,
    [parameter(Mandatory = $true)][string]$Collection,
    [parameter(Mandatory = $true)][string]$SubscriptionId
) {
    try {
        $baseUrl = Get-BaseDatabaseUrl $Database
        $collectionsUrl = Get-CollectionsUrl $Container $Collection
        $pkRangeUrl = "$collectionsUrl/$PARTITIONKEYRANGE_TYPE"

        $url = "$baseUrl/$pkRangeUrl"

        $cacheKey = $url
        $cacheResult = Get-CacheValue -Key $cacheKey -Cache $PARTITION_KEY_RANGE_CACHE
        if ($cacheResult) {
            return $cacheResult
        }

        $refreshAuthHeaders = {
            $now = Get-Time
            $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $PARTITIONKEYRANGE_TYPE -resourceUrl $collectionsUrl -now $now

            return @{ now = $now; encodedAuthString = $encodedAuthString }
        }
        
        $headers = Get-CommonHeaders -PartitionKey $requestPartitionKey
        $headers["x-ms-documentdb-query-enablecrosspartition"] = "true"

        $response = Invoke-CosmosDbApiRequestWithContinuation -Verb $GET_VERB -Url $url -Headers $headers -RefreshAuthHeaders $refreshAuthHeaders | Get-CosmosDbRecordContent

        $ranges = $response.partitionKeyRanges

        $result = @{ Ranges = $ranges }

        Set-CacheValue -Key $cacheKey -Value $result -Cache $PARTITION_KEY_RANGE_CACHE -ExpirationHours 6

        $result
    } 
    catch {
        @{ ErrorRecord = $_ }
    } 
}

Function Get-FilteredPartitionKeyRangesForQuery($allRanges, $queryRanges) {
    $allRanges | where-object { 
        $partitionMin = $_.minInclusive
        $partitionMax = $_.maxExclusive

        $queryRanges | where-object {
            $queryMin = $_.min
            $queryMax = $_.max

            !(($partitionMax -le $queryMin) -or ($partitionMin -gt $queryMax))
        }
    }
}

<#
.SYNOPSIS
    Fetches a single DB record, returns the HTTP response of the lookup
    
.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER RecordId
    The record's id
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.
.PARAMETER PartitionKey
    [Optional] The record's partition key. Default is `RecordId`. Required if using a custom partition strategy.

.EXAMPLE
    $> Get-CosmosDbRecord ...

    StatusCode        : 200
    StatusDescription : OK
    Content           : { ... }
    RawContent        : ...
    Forms             : {}
    Headers           : { ... }
    Images            : {}
    InputFields       : {}
    Links             : {}
    ParsedHtml        : mshtml.HTMLDocumentClass
    RawContentLength  : 1234
.EXAMPLE
    $> Get-CosmosDbRecord ... | Get-CosmosDbRecordContent

    id   : 12345
    key1 : value1
    key2 : value2
.EXAMPLE
    $> Get-CosmosDbRecord ... | Get-CosmosDbRecordContent | ConvertTo-Json

    {
        "id": 12345,
        "key1", "value1",
        "key2": "value2"
    }
#>
Function Get-CosmosDbRecord(
    [parameter(Mandatory = $true)][string]$ResourceGroup,
    [parameter(Mandatory = $true)][string]$Database, 
    [parameter(Mandatory = $true)][string]$Container,
    [parameter(Mandatory = $true)][string]$Collection, 
    [parameter(Mandatory = $true)][string]$RecordId, 
    [parameter(Mandatory = $false)][string]$SubscriptionId = "", 
    [parameter(Mandatory = $false)][string]$PartitionKey = ""
) {
    $baseUrl = Get-BaseDatabaseUrl $Database
    $documentUrls = Get-DocumentsUrl $Container $Collection $RecordId

    $url = "$baseUrl/$($documentUrls.ApiUrl)"

    $now = Get-Time

    $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrls.ResourceUrl -now $now

    $requestPartitionKey = if ($PartitionKey) { $PartitionKey } else { $RecordId }

    try {
        $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey -isQuery $true

        Invoke-CosmosDbApiRequest -Verb $GET_VERB -Url $url -Headers $headers
    }
    catch {
        Get-ExceptionResponseOrThrow $_
    } 
}

<#
.SYNOPSIS
    Fetches all DB record, returns the HTTP response. The records will be within the Documents property of the result.

.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.

.EXAMPLE
    $> Get-AllCosmosDbRecords ...

    StatusCode        : 200
    StatusDescription : OK
    Content           : { ... }
    RawContent        : ...
    Forms             : {}
    Headers           : { ... }
    Images            : {}
    InputFields       : {}
    Links             : {}
    ParsedHtml        : mshtml.HTMLDocumentClass
    RawContentLength  : 1234
.EXAMPLE
    $> Get-AllCosmosDbRecords ... | Get-CosmosDbRecordContent

    id   : 1
    ...

    id   : 2
    ...
.EXAMPLE
    $> Get-AllCosmosDbRecords ... | Get-CosmosDbRecordContent | ConvertTo-Json

    [
        { "id": 1, ... },
        { "id": 2, ... },
    ]
#>
Function Get-AllCosmosDbRecords(
    [parameter(Mandatory = $true)][string]$ResourceGroup, 
    [parameter(Mandatory = $true)][string]$Database, 
    [parameter(Mandatory = $true)][string]$Container, 
    [parameter(Mandatory = $true)][string]$Collection, 
    [parameter(Mandatory = $false)][string]$SubscriptionId = ""
) {
    $baseUrl = Get-BaseDatabaseUrl $Database
    $collectionsUrl = Get-CollectionsUrl $Container $Collection
    $docsUrl = "$collectionsUrl/$DOCS_TYPE"

    $url = "$baseUrl/$docsUrl"

    $refreshAuthHeaders = {
        $now = Get-Time
        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now

        return @{ now = $now; encodedAuthString = $encodedAuthString }
    }

    $tmp = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $headers = Get-CommonHeaders -isQuery $true

        Invoke-CosmosDbApiRequestWithContinuation -verb $GET_VERB -url $url -Headers $headers -RefreshAuthHeaders $refreshAuthHeaders
    }
    catch {
        Get-ExceptionResponseOrThrow $_
    } 
    $ProgressPreference = $tmp
}

<#
.SYNOPSIS
    Queries the DB, returns the HTTP response. The records will be within the Documents property of the result.

.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER Query
    The query as a string with optional parameters
.PARAMETER Parameters
    [Optional] Parameters values used in the query. Accepts an array of name-value pairs or a hashtable.
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.
.PARAMETER DisableExtraFeatures
    Disables extra query features required to perform operations like aggregates, TOP, or DISTINCT. Should be used in case the support for these operations has a bug 😄. Default is false (extra features enabled).

.EXAMPLE
    $> Search-CosmosDbRecords -Query "select * from c where c.id in (1, 2)"
    | Get-CosmosDbRecordContent 
    | ConvertTo-Json

    [
        { "id": 1, ... },
        { "id": 2, ... },
    ]
.EXAMPLE
    $> Search-CosmosDbRecords -Query "select * from c where c.id = @id" -Parameters @(@{ name = "@id"; value = 1 })
    | Get-CosmosDbRecordContent 
    | ConvertTo-Json

    { "id": 1, ... },
.EXAMPLE
    $> Search-CosmosDbRecords -Query "select * from c where c.id = @id" -Parameters @{ "@id" = 1 }
    | Get-CosmosDbRecordContent 
    | ConvertTo-Json

    { "id": 1, ... },
.EXAMPLE
    $> Search-CosmosDbRecords -Query "select count(1) as cnt, c.key from c group by c.key"
    | Get-CosmosDbRecordContent 
    | % Payload
    | ConvertTo-Json

    [
        {
            "cnt": {
                "item":  1234
            },
            "key": "key1"
        },
        {
            "cnt": {
                "item":  5678
            },
            "key": "key2"
        }
    ]
#>
Function Search-CosmosDbRecords(
    [parameter(Mandatory = $true)][string]$ResourceGroup, 
    [parameter(Mandatory = $true)][string]$Database, 
    [parameter(Mandatory = $true)][string]$Container, 
    [parameter(Mandatory = $true)][string]$Collection,
    [parameter(Mandatory = $true)][string]$Query,
    [parameter(Mandatory = $false)]$Parameters = $null,
    [parameter(Mandatory = $false)][string]$SubscriptionId = "",
    [parameter(Mandatory = $false)][switch]$DisableExtraFeatures = $false
) {
    $Parameters = @(Get-QueryParametersAsNameValuePairs $Parameters)

    if (!$DisableExtraFeatures) {
        return Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $ResourceGroup -Database $Database -Container $Container -Collection $Collection -Query $Query -Parameters $Parameters -SubscriptionId $SubscriptionId
    }

    $baseUrl = Get-BaseDatabaseUrl $Database
    $collectionsUrl = Get-CollectionsUrl $Container $Collection
    $docsUrl = "$collectionsUrl/$DOCS_TYPE"

    $url = "$baseUrl/$docsUrl"

    $refreshAuthHeaders = {
        $now = Get-Time
        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now

        return @{ now = $now; encodedAuthString = $encodedAuthString }
    }

    try {
        $body = @{
            query      = $Query;
            parameters = $Parameters;
        }

        $headers = Get-CommonHeaders -isQuery $true -contentType "application/Query+json"
        $headers["x-ms-documentdb-query-enablecrosspartition"] = "true"

        Invoke-CosmosDbApiRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers -RefreshAuthHeaders $refreshAuthHeaders
    }
    catch {
        Get-ExceptionResponseOrThrow $_
    }
}

Function Search-CosmosDbRecordsWithExtraFeatures
(
    [string]$ResourceGroup,
    [string]$Database, 
    [string]$Container, 
    [string]$Collection, 
    [string]$Query, 
    $Parameters, 
    [string]$SubscriptionId
) {
    $Parameters = @(Get-QueryParametersAsNameValuePairs $Parameters)

    $baseUrl = Get-BaseDatabaseUrl $Database
    $collectionsUrl = Get-CollectionsUrl $Container $Collection
    $docsUrl = "$collectionsUrl/$DOCS_TYPE"

    $url = "$baseUrl/$docsUrl"

    $allPartitionKeyRangesOrError = Get-PartitionKeyRangesOrError -ResourceGroup $ResourceGroup -Database $Database -Container $Container -Collection $Collection -SubscriptionId $SubscriptionId

    if ($allPartitionKeyRangesOrError.ErrorRecord) {
        return Get-ExceptionResponseOrThrow $allPartitionKeyRangesOrError.ErrorRecord
    }

    $refreshAuthHeaders = {
        $now = Get-Time
        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now

        return @{ now = $now; encodedAuthString = $encodedAuthString }
    }
    
    try {
        $ranges = $allPartitionKeyRangesOrError.Ranges

        $body = @{
            query      = $Query;
            parameters = $Parameters;
        }

        $authHeaders = Invoke-Command -ScriptBlock $refreshAuthHeaders
        $headers = Get-CommonHeaders -now $authHeaders.now -encodedAuthString $authHeaders.encodedAuthString -isQuery $true -contentType "application/Query+json"
        $headers += @{
            "x-ms-documentdb-query-enablecrosspartition"           = "true";
            "x-ms-cosmos-supported-query-features"                 = "NonValueAggregate, Aggregate, Distinct, MultipleOrderBy, OffsetAndLimit, OrderBy, Top, CompositeAggregate, GroupBy, MultipleAggregates";
            "x-ms-documentdb-query-enable-scan"                    = "true";
            "x-ms-documentdb-query-parallelizecrosspartitionquery" = "true";
            "x-ms-cosmos-is-query-plan-request"                    = "True";
        }

        $queryPlan = Invoke-CosmosDbApiRequest -verb $POST_VERB -url $url -Body $body -Headers $headers | Get-CosmosDbRecordContent
        
        $rewrittenQuery = $queryPlan.QueryInfo.RewrittenQuery
        $searchQuery = if ($rewrittenQuery) { $rewrittenQuery } else { $Query };

        $body = @{
            query      = $searchQuery;
            parameters = $Parameters;
        }

        $headers.Remove("x-ms-cosmos-is-query-plan-request")

        $partitionKeyRanges = 
        if ($env:COSMOS_DB_FLAG_ENABLE_PARTITION_KEY_RANGE_SEARCHES -eq 1) {
            Get-FilteredPartitionKeyRangesForQuery -AllRanges $ranges -QueryRanges $queryPlan.QueryRanges
        }
        else {
            $ranges
        }

        foreach ($partitionKeyRange in $partitionKeyRanges) {
            $headers["x-ms-documentdb-partitionkeyrangeid"] = $partitionKeyRange.id

            Invoke-CosmosDbApiRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers -RefreshAuthHeaders $refreshAuthHeaders
        }
    }
    catch {
        Get-ExceptionResponseOrThrow $_
    } 
}

<#
.SYNOPSIS
    Creates a single DB record, returns the HTTP response of the operation
    
.PARAMETER Object
    Azure Resource Group of the database
.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.
.PARAMETER PartitionKey
    [Optional] The record's partition key. Default is the `id` property of `Object`. Required if using a custom partition strategy.
.PARAMETER GetPartitionKeyBlock
    [Optional] Callback to get the partition key from the input object. Default is the `id` property of `Object`. Required if using a custom partition strategy.

.EXAMPLE
    $> New-CosmosDbRecord -Object @{ id = 1234; key = value } ...

    StatusCode        : 201
    StatusDescription : Created
    Content           : { ... }
    RawContent        : ...
    Forms             : {}
    Headers           : { ... }
    Images            : {}
    InputFields       : {}
    Links             : {}
    ParsedHtml        : mshtml.HTMLDocumentClass
    RawContentLength  : 257
.EXAMPLE
    $> New-CosmosDbRecord -Object @{ id = 1234; key = value } ...

    id  : 1234
    key : value
.EXAMPLE
    $> $record | New-CosmosDbRecord -PartitionKey $record.PartitionKey ...
.EXAMPLE
    $> $recordList | New-CosmosDbRecord -GetPartitionKeyBlock { param($r) $r.PartitionKey } ...
#>
Function New-CosmosDbRecord { 
    [CmdletBinding(DefaultParameterSetName = 'ExplicitPartitionKey')]
    param
    (
        [parameter(ValueFromPipeline = $true, Mandatory = $true)]$Object,
        [parameter(Mandatory = $true)][string]$ResourceGroup, 
        [parameter(Mandatory = $true)][string]$Database, 
        [parameter(Mandatory = $true)][string]$Container, 
        [parameter(Mandatory = $true)][string]$Collection, 
        [parameter(Mandatory = $false)][string]$SubscriptionId = "", 
        [parameter(Mandatory = $false, ParameterSetName = "ExplicitPartitionKey")][string]$PartitionKey = "", 
        [parameter(Mandatory = $false, ParameterSetName = "ParttionKeyCallback")]$GetPartitionKeyBlock = $null
    )

    begin {
        RequireWriteableKey

        $baseUrl = Get-BaseDatabaseUrl $Database
        $collectionsUrl = Get-CollectionsUrl $Container $Collection
        $docsUrl = "$collectionsUrl/$DOCS_TYPE"

        $url = "$baseUrl/$docsUrl"

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process {
        try {
            $requestPartitionKey = if ($PartitionKey) { $PartitionKey } elseif ($GetPartitionKeyBlock) { Invoke-Command -ScriptBlock $GetPartitionKeyBlock -ArgumentList $Object } else { $Object.Id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey

            Invoke-CosmosDbApiRequest -Verb $POST_VERB -Url $url -Body $Object -Headers $headers
        }
        catch {
            Get-ExceptionResponseOrThrow $_
        } 
    }
}

<#
.SYNOPSIS
    Updates a single DB record, returns the HTTP response of the operation
    
.PARAMETER Object
    The input record
.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.
.PARAMETER PartitionKey
    [Optional] The record's partition key. Default is the `id` property of `Object`. Required if using a custom partition strategy.
.PARAMETER GetPartitionKeyBlock
    [Optional] Callback to get the partition key from the input object. Default is the `id` property of `Object`. Required if using a custom partition strategy.
.PARAMETER EnforceOptimisticConcurrency
    [Optional] Boolean specifying whether to enforce optimistic concurrency. Default is $true.

.EXAMPLE
    $> Update-CosmosDbRecord -Object @{ id = 1234; key = value } ...

    StatusCode        : 200
    StatusDescription : Ok
    Content           : { ... }
    RawContent        : ...
    Forms             : {}
    Headers           : { ... }
    Images            : {}
    InputFields       : {}
    Links             : {}
    ParsedHtml        : mshtml.HTMLDocumentClass
    RawContentLength  : 271
.EXAMPLE
    $> Update-CosmosDbRecord -Object @{ id = 1234; key = value } ... | Get-CosmosDbRecordContent

    id  : 1234
    key : value
.EXAMPLE
    $> $record | Update-CosmosDbRecord -PartitionKey $record.PartitionKey ...
.EXAMPLE
    $> $recordList | Update-CosmosDbRecord -GetPartitionKeyBlock { param($r) $r.PartitionKey } ...
#>
Function Update-CosmosDbRecord {
    [CmdletBinding(DefaultParameterSetName = 'ExplicitPartitionKey')]
    param
    (
        [parameter(ValueFromPipeline = $true, Mandatory = $true)]$Object,
        [parameter(Mandatory = $true)][string]$ResourceGroup, 
        [parameter(Mandatory = $true)][string]$Database, 
        [parameter(Mandatory = $true)][string]$Container, 
        [parameter(Mandatory = $true)][string]$Collection, 
        [parameter(Mandatory = $false)][string]$SubscriptionId = "", 
        [parameter(Mandatory = $false, ParameterSetName = "ExplicitPartitionKey")][string]$PartitionKey = "", 
        [parameter(Mandatory = $false, ParameterSetName = "ParttionKeyCallback")]$GetPartitionKeyBlock = $null,
        [parameter(Mandatory = $false)][bool]$EnforceOptimisticConcurrency = $true
    )

    begin {
        RequireWriteableKey

        $baseUrl = Get-BaseDatabaseUrl $Database
    }
    process {
        try {
            $documentUrls = Get-DocumentsUrl $Container $Collection $Object.id

            $url = "$baseUrl/$($documentUrls.ApiUrl)"
    
            $now = Get-Time
            
            $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $PUT_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrls.ResourceUrl -now $now
            
            $requestPartitionKey = if ($PartitionKey) { $PartitionKey } elseif ($GetPartitionKeyBlock) { Invoke-Command -ScriptBlock $GetPartitionKeyBlock -ArgumentList $Object } else { $Object.Id }

            if ($EnforceOptimisticConcurrency) {
                $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey -Etag $Object._etag
            }
            else {
                $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey
            }

            Invoke-CosmosDbApiRequest -Verb $PUT_VERB -Url $url -Body $Object -Headers $headers
        }
        catch {
            Get-ExceptionResponseOrThrow $_
        } 
    }
}

<#
.SYNOPSIS
    Deletes a single DB record, returns the HTTP response of the lookup
    
.PARAMETER ResourceGroup
    Azure Resource Group of the database
.PARAMETER Database
    The database name
.PARAMETER Container
    The container name inside the database
.PARAMETER Collection
    The collection name inside the container
.PARAMETER RecordId
    The record's id
.PARAMETER Object
    [Optional] The input record to extract the id from if `RecordId` is not set.
.PARAMETER SubscriptionId
    [Optional] The Azure Subscription Id. Default is the same as `az`.
.PARAMETER PartitionKey
    [Optional] The record's partition key. Default is the `id` property of `Object`. Required if using a custom partition strategy.
.PARAMETER GetPartitionKeyBlock
    [Optional] Callback to get the partition key from the input object. Default is the `id` property of `Object`. Required if using a custom partition strategy.

.EXAMPLE
    $> Remove-CosmosDbRecord ...

    StatusCode        : 204
    StatusDescription : No Content
    Content           :
    RawContent        : ...
    Forms             : {}
    Headers           : { ... }
    Images            : {}
    InputFields       : {}
    Links             : {}
    ParsedHtml        : mshtml.HTMLDocumentClass
    RawContentLength  : 0
#>
Function Remove-CosmosDbRecord {
    [CmdletBinding(DefaultParameterSetName = 'DefaultPartitionKey_ExplicitRecordId')]
    param
    (
        [parameter(Mandatory = $true)][string]$ResourceGroup,
        [parameter(Mandatory = $true)][string]$Database, 
        [parameter(Mandatory = $true)][string]$Container,
        [parameter(Mandatory = $true)][string]$Collection, 
        [parameter(Mandatory = $false)][string]$SubscriptionId = "", 

        [parameter(Mandatory = $true, ParameterSetName = "DefaultPartitionKey_ExplicitRecordId")]
        [parameter(Mandatory = $true, ParameterSetName = "ExplicitPartitionKey_ExplicitRecordId")]
        [parameter(Mandatory = $true, ParameterSetName = "CallbackPartitionKey_ExplicitRecordId")]
        [string]$RecordId,

        [parameter(ValueFromPipeline = $true, Mandatory = $true, ParameterSetName = "DefaultPartitionKey_ObjectRecordId")]
        [parameter(ValueFromPipeline = $true, Mandatory = $true, ParameterSetName = "ExplicitPartitionKey_ObjectRecordId")]
        [parameter(ValueFromPipeline = $true, Mandatory = $true, ParameterSetName = "CallbackPartitionKey_ObjectRecordId")]
        $Object,
                
        [parameter(Mandatory = $true, ParameterSetName = "ExplicitPartitionKey_ExplicitRecordId")]
        [parameter(Mandatory = $true, ParameterSetName = "ExplicitPartitionKey_ObjectRecordId")]
        [string]$PartitionKey = "", 
        
        [parameter(Mandatory = $true, ParameterSetName = "CallbackPartitionKey_ObjectRecordId")]
        $GetPartitionKeyBlock = $null
    )

    begin {
        RequireWriteableKey

        $baseUrl = Get-BaseDatabaseUrl $Database        
    }
    process {
        try {
            $id = if ($RecordId) { $RecordId } else { $Object.id }

            $documentUrls = Get-DocumentsUrl $Container $Collection $id

            $url = "$baseUrl/$($documentUrls.ApiUrl)"

            $now = Get-Time

            $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $DELETE_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrls.ResourceUrl -now $now
            
            $requestPartitionKey = if ($PartitionKey) { $PartitionKey } elseif ($GetPartitionKeyBlock) { Invoke-Command -ScriptBlock $GetPartitionKeyBlock -ArgumentList $Object } else { $id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey

            Invoke-CosmosDbApiRequest -Verb $DELETE_VERB -Url $url -Headers $headers
        }
        catch {
            Get-ExceptionResponseOrThrow $_
        } 
    }
}

Function Get-CosmosDbRecordContent([parameter(ValueFromPipeline)]$RecordResponse) {   
    process {
        $code = [int]$RecordResponse.StatusCode
        $content = 
        if ($RecordResponse.Content) {
            $RecordResponse.Content | ConvertFrom-Json
        }
        else {
            $null
        }

        if ($code -lt 300) {
            if ($RecordResponse.Content) {
                $content
            }
            else {
                $null
            }
        }
        elseif ($code -eq 401) {
            if ($env:COSMOS_DB_FLAG_ENABLE_READONLY_KEYS -eq 1) {
                throw "(401) Unauthorized (used a readonly key)"
            }
            throw "(401) Unauthorized"
        }
        elseif ($code -eq 404) {
            if ($content.Message -like "*Owner resource does not exist*") {
                throw "(404) Database does not exist"
            }

            throw "(404) Record not found"
        }
        elseif ($code -eq 412) {
            throw "(412) Conflict"
        }
        elseif ($code -eq 429) {
            throw "(429) Request rate limited"
        }
        else {
            $message = $content.Message
            throw "Request failed with status code $code with message`n`n$message"
        }
    }
}

Function Use-CosmosDbInternalFlag
(
    $enableFiddlerDebugging = $null,
    $enableCaching = $null,
    $enablePartitionKeyRangeSearches = $null,
    $enableAuthHeaderReuse = $null,
    $enableMasterKeyAuth = $null
) {
    if ($null -ne $enableFiddlerDebugging) {
        $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = if ($enableFiddlerDebugging) { 1 } else { 0 }
    }

    if ($null -ne $enableCaching) {
        $env:COSMOS_DB_FLAG_ENABLE_CACHING = if ($enableCaching) { 1 } else { 0 }
    }

    if ($null -ne $enablePartitionKeyRangeSearches) {
        $env:COSMOS_DB_FLAG_ENABLE_PARTITION_KEY_RANGE_SEARCHES = if ($enablePartitionKeyRangeSearches) { 1 } else { 0 }
    }

    if ($null -ne $enableAuthHeaderReuse) {
        $env:COSMOS_DB_FLAG_ENABLE_AUTH_HEADER_REUSE = if ($enableAuthHeaderReuse) { 1 } else { 0 }
    }

    if ($null -ne $enableMasterKeyAuth) {
        $env:COSMOS_DB_FLAG_ENABLE_MASTER_KEY_AUTH = if ($enableMasterKeyAuth) { 1 } else { 0 }
    }
}

Function Use-CosmosDbReadonlyKeys
(
    [switch]$Disable
) {
    $env:COSMOS_DB_FLAG_ENABLE_READONLY_KEYS = if ($Disable) { 0 } else { 1 }
}


Export-ModuleMember -Function "Get-CosmosDbRecord"
Export-ModuleMember -Function "Get-AllCosmosDbRecords"

Export-ModuleMember -Function "Search-CosmosDbRecords"

Export-ModuleMember -Function "New-CosmosDbRecord"

Export-ModuleMember -Function "Update-CosmosDbRecord"

Export-ModuleMember -Function "Remove-CosmosDbRecord"

Export-ModuleMember -Function "Get-CosmosDbRecordContent"

Export-ModuleMember -Function "Use-CosmosDbReadonlyKeys"

Export-ModuleMember -Function "Use-CosmosDbInternalFlag"
