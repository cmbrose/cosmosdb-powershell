$DB_TYPE = "dbs" # aka Container
$COLLS_TYPE = "colls"
$DOCS_TYPE = "docs"
$PARTITIONKEYRANGE_TYPE = "pkranges"

$GET_VERB = "get"
$POST_VERB = "post"
$PUT_VERB = "put"
$DELETE_VERB = "delete"

$API_VERSION = "2018-12-31"

$MASTER_KEY_CACHE = @{}
$SIGNATURE_HASH_CACHE = @{}
$PARTITION_KEY_RANGE_CACHE = @{}

Function Get-BaseDatabaseUrl([string]$Database) {
    return "https://$Database.documents.azure.com"
}

Function Get-CollectionsUrl([string]$Container, [string]$Collection) {
    return "$DB_TYPE/$Container/$COLLS_TYPE/$Collection"
}

Function Get-DocumentsUrl([string]$Container, [string]$Collection, [string]$RecordId) {
    return (Get-CollectionsUrl $Container $Collection) + "/$DOCS_TYPE/$RecordId"
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

Function Set-CacheValue([string]$key, $value, [hashtable]$cache, [int]$expirationHours) {
    $cache[$key] = @{ 
        Expiration = [datetime]::UtcNow.AddHours($expirationHours);
        Value      = $value 
    }
}

Function Get-Base64Masterkey([string]$ResourceGroup, [string]$Database, [string]$SubscriptionId) {
    $cacheKey = "$SubscriptionId/$ResourceGroup/$Database"
    $cacheResult = Get-CacheValue -Key $cacheKey -Cache $MASTER_KEY_CACHE
    if ($cacheResult) {
        return $cacheResult
    }

    if ($SubscriptionId) {
        $masterKey = az cosmosdb keys list --name $Database --query primaryMasterKey --output tsv --resource-group $ResourceGroup --subscription $SubscriptionId
    }
    else {
        $masterKey = az cosmosdb keys list --name $Database --query primaryMasterKey --output tsv --resource-group $ResourceGroup    
    }

    Set-CacheValue -Key $cacheKey -Value $masterKey -Cache $MASTER_KEY_CACHE -ExpirationHours 6

    $masterKey
}

Function Get-Signature([string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now) {
    ((@($verb, $resourceType, $resourceUrl, $now, "") -join "`n") + "`n").ToLower()
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

Function Get-EncodedAuthString([string]$signatureHash) {
    $authString = "type=master&ver=1.0&sig=$signatureHash"
    [uri]::EscapeDataString($authString)
}

Function Get-AuthorizationHeader([string]$ResourceGroup, [string]$SubscriptionId, [string]$Database, [string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now) {            
    $masterKey = Get-Base64Masterkey -ResourceGroup $ResourceGroup -Database $Database -SubscriptionId $SubscriptionId
        
    $signature = Get-Signature -verb $verb -resourceType $resourceType -resourceUrl $resourceUrl -now $now

    $signatureHash = Get-Base64EncryptedSignatureHash -masterKey $masterKey -signature $signature

    Get-EncodedAuthString -signatureHash $signatureHash
}

Function Get-CommonHeaders([string]$now, [string]$encodedAuthString, [string]$contentType = "application/json", [bool]$isQuery = $false, [string]$PartitionKey = $null) {
    $headers = @{ 
        "x-ms-date"     = $now;
        "x-ms-version"  = $API_VERSION;
        "Authorization" = $encodedAuthString;
        "Cache-Control" = "No-Cache";
        "Content-Type"  = $contentType;
    }

    if ($isQuery) {
        $headers["x-ms-documentdb-isquery"] = "true"
    }

    if ($PartitionKey) {
        $headers["x-ms-documentdb-partitionkey"] = "[`"$PartitionKey`"]"
    }

    $headers
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

Function Get-RequestErrorDetails($response) {
    $result = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($result)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $reader.ReadToEnd();
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

Function Invoke-CosmosDbApiRequestWithContinuation([string]$verb, [string]$url, $headers, $body = $null) {
    process {
        $response = Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $body -Headers $headers
        $response

        $continuationToken = Get-ContinuationToken $response
        while ($continuationToken) {
            $headers["x-ms-continuation"] = $continuationToken

            $response = Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $body -Headers $headers
            $response

            $continuationToken = Get-ContinuationToken $response
        }   
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

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $PARTITIONKEYRANGE_TYPE -resourceUrl $collectionsUrl -now $now

        $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey
        $headers["x-ms-documentdb-query-enablecrosspartition"] = "true"

        $response = Invoke-CosmosDbApiRequest -Verb $GET_VERB -Url $url -Headers $headers | Get-CosmosDbRecordContent

        $ranges = $response.partitionKeyRanges

        Set-CacheValue -Key $cacheKey -Value $ranges -Cache $PARTITION_KEY_RANGE_CACHE -ExpirationHours 6

        $ranges
    } 
    catch [System.Net.WebException] {
        $_.Exception
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
    [parameter(Mandatory = $false)][string]$PartitionKey = "") {
    begin {
        $baseUrl = Get-BaseDatabaseUrl $Database
        $documentUrl = Get-DocumentsUrl $Container $Collection $RecordId

        $url = "$baseUrl/$documentUrl"

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now

        $requestPartitionKey = if ($PartitionKey) { $PartitionKey } else { $RecordId }
    }
    process {
        try {
            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey -isQuery $true

            Invoke-CosmosDbApiRequest -Verb $GET_VERB -Url $url -Headers $headers
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
        }
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
    [parameter(Mandatory = $false)][string]$SubscriptionId = "") {
    begin {
        $baseUrl = Get-BaseDatabaseUrl $Database
        $collectionsUrl = Get-CollectionsUrl $Container $Collection
        $docsUrl = "$collectionsUrl/$DOCS_TYPE"

        $url = "$baseUrl/$docsUrl"

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process {
        $tmp = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true

            Invoke-CosmosDbApiRequestWithContinuation -verb $GET_VERB -url $url -Headers $headers
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
        }
        $ProgressPreference = $tmp
    }
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
    [parameter(Mandatory = $false)][switch]$DisableExtraFeatures = $false) {
    begin {
        $Parameters = @(Get-QueryParametersAsNameValuePairs $Parameters)

        $baseUrl = Get-BaseDatabaseUrl $Database
        $collectionsUrl = Get-CollectionsUrl $Container $Collection
        $docsUrl = "$collectionsUrl/$DOCS_TYPE"

        $url = "$baseUrl/$docsUrl"

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process {
        if (!$DisableExtraFeatures) {
            return Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $ResourceGroup -Database $Database -Container $Container -Collection $Collection -Query $Query -Parameters $Parameters -SubscriptionId $SubscriptionId
        }

        try {
            $body = @{
                query      = $Query;
                parameters = $Parameters;
            }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true -contentType "application/Query+json"
            $headers["x-ms-documentdb-query-enablecrosspartition"] = "true"

            Invoke-CosmosDbApiRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
        }
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
    begin {
        $Parameters = @(Get-QueryParametersAsNameValuePairs $Parameters)

        $baseUrl = Get-BaseDatabaseUrl $Database
        $collectionsUrl = Get-CollectionsUrl $Container $Collection
        $docsUrl = "$collectionsUrl/$DOCS_TYPE"

        $url = "$baseUrl/$docsUrl"

        $now = Get-Time

        $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now

        $allPartitionKeyRangesOrError = Get-PartitionKeyRangesOrError -ResourceGroup $ResourceGroup -Database $Database -Container $Container -Collection $Collection -SubscriptionId $SubscriptionId
    }
    process {
        try {
            if ($allPartitionKeyRangesOrError -is [System.Net.WebException]) {
                throw $allPartitionKeyRangesOrError
            }

            $body = @{
                query      = $Query;
                parameters = $Parameters;
            }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true -contentType "application/Query+json"
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
                Get-FilteredPartitionKeyRangesForQuery -AllRanges $allPartitionKeyRangesOrError -QueryRanges $queryPlan.QueryRanges
            }
            else {
                $allPartitionKeyRangesOrError
            }

            foreach ($partitionKeyRange in $partitionKeyRanges) {
                $headers["x-ms-documentdb-partitionkeyrangeid"] = $partitionKeyRange.id

                Invoke-CosmosDbApiRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers
            }
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
        }
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
        catch [System.Net.WebException] {
            $_.Exception.Response
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
        [parameter(Mandatory = $false, ParameterSetName = "ParttionKeyCallback")]$GetPartitionKeyBlock = $null
    )

    begin {
        $baseUrl = Get-BaseDatabaseUrl $Database
    }
    process {
        try {
            $documentUrl = Get-DocumentsUrl $Container $Collection $Object.id

            $url = "$baseUrl/$documentUrl"
    
            $now = Get-Time
            
            $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $PUT_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now
            
            $requestPartitionKey = if ($PartitionKey) { $PartitionKey } elseif ($GetPartitionKeyBlock) { Invoke-Command -ScriptBlock $GetPartitionKeyBlock -ArgumentList $Object } else { $Object.Id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey

            Invoke-CosmosDbApiRequest -Verb $PUT_VERB -Url $url -Body $Object -Headers $headers
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
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
        $baseUrl = Get-BaseDatabaseUrl $Database        
    }
    process {
        try {
            $id = if ($RecordId) { $RecordId } else { $Object.id }

            $documentUrl = Get-DocumentsUrl $Container $Collection $id

            $url = "$baseUrl/$documentUrl"

            $now = Get-Time

            $encodedAuthString = Get-AuthorizationHeader -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -Database $Database -verb $DELETE_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now
            
            $requestPartitionKey = if ($PartitionKey) { $PartitionKey } elseif ($GetPartitionKeyBlock) { Invoke-Command -ScriptBlock $GetPartitionKeyBlock -ArgumentList $Object } else { $id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -PartitionKey $requestPartitionKey

            Invoke-CosmosDbApiRequest -Verb $DELETE_VERB -Url $url -Headers $headers
        }
        catch [System.Net.WebException] {
            $_.Exception.Response
        }
    }
}

Function Get-CosmosDbRecordContent([parameter(ValueFromPipeline)]$RecordResponse) {   
    process {
        $code = [int]$RecordResponse.StatusCode
        if ($code -lt 300) {
            if ($RecordResponse.Content) {
                $RecordResponse.Content | ConvertFrom-Json
            }
            else {
                $null
            }
        }
        elseif ($code -eq 404) {
            throw "Record not found"
        }
        elseif ($code -eq 429) {
            throw "Request rate limited"
        }
        else {
            $message = Get-RequestErrorDetails $RecordResponse | ConvertFrom-Json | % Message
            throw "Request failed with status code $code with message`n`n$message"
        }
    }
}

Function Use-CosmosDbInternalFlag
(
    $enableFiddlerDebugging = $null,
    $enableCaching = $null,
    $enablePartitionKeyRangeSearches = $null
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
}

Export-ModuleMember -Function "Get-CosmosDbRecord"
Export-ModuleMember -Function "Get-AllCosmosDbRecords"

Export-ModuleMember -Function "Search-CosmosDbRecords"

Export-ModuleMember -Function "New-CosmosDbRecord"

Export-ModuleMember -Function "Update-CosmosDbRecord"

Export-ModuleMember -Function "Remove-CosmosDbRecord"

Export-ModuleMember -Function "Get-CosmosDbRecordContent"

Export-ModuleMember -Function "Use-CosmosDbInternalFlag"