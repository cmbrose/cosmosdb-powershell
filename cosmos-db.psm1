$DB_TYPE="dbs" # aka container
$COLLS_TYPE="colls"
$DOCS_TYPE="docs"

$GET_VERB="get"
$POST_VERB="post"
$PUT_VERB="put"
$DELETE_VERB="delete"

$API_VERSION="2018-12-31"

$MASTER_KEY_CACHE = @{}
$SIGNATURE_HASH_CACHE = @{}

Function Get-BaseDatabaseUrl([string]$database)
{
    return "https://$database.documents.azure.com"
}

Function Get-CollectionsUrl([string]$container, [string]$collection)
{
    return "$DB_TYPE/$container/$COLLS_TYPE/$collection"
}

Function Get-DocumentsUrl([string]$container, [string]$collection, [string]$id)
{
    return (Get-CollectionsUrl $container $collection) + "/$DOCS_TYPE/$id"
}

Function Get-Time()
{
    Get-Date ([datetime]::UtcNow) -Format "R"
}

Function Get-Base64Masterkey([string]$resourceGroup, [string]$database, [string]$subscription)
{
    $cacheKey = "$subscription/$resourceGroup/$database"
    $cacheEntry = $MASTER_KEY_CACHE[$cacheKey]

    if ($cacheEntry -and ($cacheEntry.Expiration -gt [datetime]::UtcNow))
    {
        return $cacheEntry.Value
    }

    if ($subscription)
    {
        $masterKey = az cosmosdb keys list --name $database --query primaryMasterKey --output tsv --resource-group $resourceGroup --subscription $subscription
    }
    else
    {
        $masterKey = az cosmosdb keys list --name $database --query primaryMasterKey --output tsv --resource-group $resourceGroup    
    }

    $MASTER_KEY_CACHE[$cacheKey] = @{ Expiration = [datetime]::UtcNow.AddHours(6); Value = $masterKey }

    $masterKey
}

Function Get-Signature([string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now)
{
    ((@($verb, $DOCS_TYPE, $resourceUrl, $now, "") -join "`n") + "`n").ToLower()
}

Function Get-Base64EncryptedSignatureHash([string]$masterKey, [string]$signature)
{
    $cacheKey = "$masterKey/$signature"
    $cacheEntry = $SIGNATURE_HASH_CACHE[$cacheKey]

    if ($cacheEntry -and $cacheEntry.Expiration -gt [datetime]::UtcNow)
    {
        return $cacheEntry.Value
    }

    $keyBytes=[System.Convert]::FromBase64String($masterKey)
    $hasher = New-Object System.Security.Cryptography.HMACSHA256 -Property @{ Key = $keyBytes }
    $sigBinary=[System.Text.Encoding]::UTF8.GetBytes($signature)
    $hashBytes=$hasher.ComputeHash($sigBinary)
    $base64Hash=[System.Convert]::ToBase64String($hashBytes)

    $SIGNATURE_HASH_CACHE[$cacheKey] = @{ Expiration = [datetime]::UtcNow.AddHours(1); Value = $base64Hash }

    $base64Hash
}

Function Get-EncodedAuthString([string]$signatureHash)
{
    $authString="type=master&ver=1.0&sig=$signatureHash"
    [uri]::EscapeDataString($authString)
}

Function Get-AuthorizationHeader([string]$resourceGroup, [string]$subscription, [string]$database, [string]$verb, [string]$resourceType, [string]$resourceUrl, [string]$now)
{            
    $masterKey=Get-Base64Masterkey -resourceGroup $resourceGroup -database $database -subscription $subscription
        
    $signature=Get-Signature -verb $verb -resourceType $resourceType -resourceUrl $resourceUrl -now $now

    $signatureHash=Get-Base64EncryptedSignatureHash -masterKey $masterKey -signature $signature

    Get-EncodedAuthString -signatureHash $signatureHash
}

Function Get-CommonHeaders([string]$now, [string]$encodedAuthString, [string]$contentType="application/json", [bool]$isQuery=$false, [string]$partitionKey=$null)
{
    $headers = @{ 
        "x-ms-date"=$now;
        "x-ms-version" = $API_VERSION;
        "Authorization" = $encodedAuthString;
        "Cache-Control" = "No-Cache";
        "Content-Type" = $contentType;
    }

    if ($isQuery)
    {
        $headers[ "x-ms-documentdb-isquery"] = "true"
    }

    if ($partitionKey)
    {
        $headers["x-ms-documentdb-partitionkey"] = "[`"$requestPartitionKey`"]"
    }

    $headers
}

Function Get-RequestErrorDetails($response)
{
    $result = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($result)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $reader.ReadToEnd();
}

Function Invoke-WebRequestWithContinuation([string]$verb, [string]$url, $headers, $body=$null)
{
    process
    {
        $response = Invoke-WebRequest -Method $verb -Uri $url -Body $body -Headers $headers
        $response

        while ($response.Headers["x-ms-continuation"])
        {
            $headers["x-ms-continuation"] = $response.Headers["x-ms-continuation"];

            $response = Invoke-WebRequest -Method $verb -Uri $url -Body $body -Headers $headers
            $response
        }   
    }
}

Function Get-CosmosDbRecord([string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$id, [string]$subscription="", [string]$partitionKey="")
{
    begin
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $documentUrl=Get-DocumentsUrl $container $collection $id

        $url="$baseUrl/$documentUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now

        $requestPartitionKey = if ($partitionKey) { $partitionKey } else { $id }
    }
    process
    {
        try 
        {
            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -partitionKey $requestPartitionKey -isQuery $true

            Invoke-WebRequest -Method $GET_VERB -Uri $url -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function Get-AllCosmosDbRecords([string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$subscription="")
{
    begin
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $collectionsUrl=Get-CollectionsUrl $container $collection
        $docsUrl="$collectionsUrl/$DOCS_TYPE"

        $url="$baseUrl/$docsUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $GET_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process
    {
        $tmp=$ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try 
        {
            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true

            Invoke-WebRequestWithContinuation -verb $GET_VERB -url $url -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
        $ProgressPreference=$tmp
    }
}

Function Search-CosmosDbRecords([string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$query, $parameters=@(), [string]$subscription="", [switch]$disableExtraFeatures=$false)
{
    begin
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $collectionsUrl=Get-CollectionsUrl $container $collection
        $docsUrl="$collectionsUrl/$DOCS_TYPE"

        $url="$baseUrl/$docsUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process
    {
        if (!$disableExtraFeatures)
        {
            return Search-CosmosDbRecordsWithExtraFeatures -resourceGroup $resourceGroup -database $database -container $container -collection $collection -query $query -parameters $parameters -subscription $subscription
        }

        try 
        {
            $body = @{
                query = $query;
                parameters = $parameters;
            } | ConvertTo-Json

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true -contentType "application/query+json"
            $headers["x-ms-documentdb-query-enablecrosspartition"] = "true"

            Invoke-WebRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function Search-CosmosDbRecordsWithExtraFeatures([string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$query, $parameters, [string]$subscription)
{
    begin
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $collectionsUrl=Get-CollectionsUrl $container $collection
        $docsUrl="$collectionsUrl/$DOCS_TYPE"

        $url="$baseUrl/$docsUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process
    {
        try 
        {
            $body = @{
                query = $query;
                parameters = $parameters;
            } | ConvertTo-Json

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -isQuery $true -contentType "application/query+json"
            $headers += @{
                "x-ms-documentdb-query-enablecrosspartition" = "true";
                "x-ms-cosmos-supported-query-features" = "NonValueAggregate, Aggregate, Distinct, MultipleOrderBy, OffsetAndLimit, OrderBy, Top, CompositeAggregate, GroupBy, MultipleAggregates";
                "x-ms-documentdb-query-enable-scan" = "true";
                "x-ms-documentdb-query-parallelizecrosspartitionquery" = "true";
                "x-ms-cosmos-is-query-plan-request" = "True";
            }

            $response=Invoke-WebRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers | Get-CosmosDbRecordContent

            $headers += @{
                "x-ms-documentdb-partitionkeyrangeid" = "0";
            }

            $headers.Remove("x-ms-cosmos-is-query-plan-request")

            $rewrittenQuery = $response.QueryInfo.RewrittenQuery
            $body = @{
                query = if ($rewrittenQuery) { $rewrittenQuery } else { $query };
            } | ConvertTo-Json

            Invoke-WebRequestWithContinuation -verb $POST_VERB -url $url -Body $body -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function New-CosmosDbRecord([parameter(ValueFromPipeline)]$object, [string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$subscription="", [string]$partitionKey="", $getPartitionKeyBlock=$null)
{
    begin 
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $collectionsUrl=Get-CollectionsUrl $container $collection
        $docsUrl="$collectionsUrl/$DOCS_TYPE"

        $url="$baseUrl/$docsUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $POST_VERB -resourceType $DOCS_TYPE -resourceUrl $collectionsUrl -now $now
    }
    process
    {
        try 
        {
            $requestPartitionKey = if ($partitionKey) { $partitionKey } elseif ($getPartitionKeyBlock) { Invoke-Command -ScriptBlock $getPartitionKeyBlock -ArgumentList $object } else { $object.Id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -partitionKey $requestPartitionKey

            $body = $object | ConvertTo-Json

            Invoke-WebRequest -Method $POST_VERB -Uri $url -Body $body -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function Update-CosmosDbRecord([parameter(ValueFromPipeline)]$object, [string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$subscription="", [string]$partitionKey="", $getPartitionKeyBlock=$null)
{
    begin 
    {
        $baseUrl=Get-BaseDatabaseUrl $database
    }
    process
    {
        try 
        {
            $documentUrl=Get-DocumentsUrl $container $collection $object.id

            $url="$baseUrl/$documentUrl"
    
            $now=Get-Time
            
            $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $PUT_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now
            
            $requestPartitionKey = if ($partitionKey) { $partitionKey } elseif ($getPartitionKeyBlock) { Invoke-Command -ScriptBlock $getPartitionKeyBlock -ArgumentList $object } else { $object.Id }

            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -partitionKey $requestPartitionKey

            $body = $object | ConvertTo-Json

            Invoke-WebRequest -Method $PUT_VERB -Uri $url -Body $body -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function Remove-CosmosDbRecord([string]$resourceGroup, [string]$database, [string]$container, [string]$collection, [string]$id, [string]$subscription="", [string]$partitionKey="")
{
    begin
    {
        $baseUrl=Get-BaseDatabaseUrl $database
        $documentUrl=Get-DocumentsUrl $container $collection $id

        $url="$baseUrl/$documentUrl"

        $now=Get-Time

        $encodedAuthString=Get-AuthorizationHeader -resourceGroup $resourceGroup -subscription $subscription -database $database -verb $DELETE_VERB -resourceType $DOCS_TYPE -resourceUrl $documentUrl -now $now

        $requestPartitionKey = if ($partitionKey) { $partitionKey } else { $id }
    }
    process
    {
        try 
        {
            $headers = Get-CommonHeaders -now $now -encodedAuthString $encodedAuthString -partitionKey $requestPartitionKey

            Invoke-WebRequest -Method $DELETE_VERB -Uri $url -Headers $headers
        }
        catch [System.Net.WebException] 
        {
            $_.Exception.Response
        }
    }
}

Function Get-CosmosDbRecordContent([parameter(ValueFromPipeline)]$recordResponse)
{   
    process
    {
        $code=[int]$recordResponse.StatusCode
        if ($code -lt 300)
        {
            $recordResponse.Content | ConvertFrom-Json
        }
        elseif ($code -eq 404)
        {
            throw "Record not found"
        }
        elseif ($code -eq 429)
        {
            throw "Request rate limited"
        }
        else
        {
            $message = Get-RequestErrorDetails $recordResponse | ConvertFrom-Json | % Message
            throw "Request failed with status code $code with message`n`n$message"
        }
    }
}

Export-ModuleMember -Function "Get-CosmosDbRecord"
Export-ModuleMember -Function "Get-AllCosmosDbRecords"

Export-ModuleMember -Function "Search-CosmosDbRecords"

Export-ModuleMember -Function "New-CosmosDbRecord"

Export-ModuleMember -Function "Update-CosmosDbRecord"

Export-ModuleMember -Function "Remove-CosmosDbRecord"

Export-ModuleMember -Function "Get-CosmosDbRecordContent"
