Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Update-CosmosDbRecord" {                    
        BeforeEach {
            Use-CosmosDbInternalFlag -EnableCaching $false
            
            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_RECORD_ID = "MOCK_RECORD_ID"
            $MOCK_ETAG = "MOCK_ETAG"

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now, $expectedId=$MOCK_RECORD_ID)
            {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "put"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$expectedId"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $actualBody, $expectedBody, $headers, $expectedId=$MOCK_RECORD_ID, $expectedPartitionKey=$null, $enforceOptimisticConcurrency=$true)
            {
                $verb | Should -Be "put"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$expectedId"        
                    
                $actualBody | Should -BeExactly $expectedBody 

                $global:capturedNow | Should -Not -Be $null

                $expectedPartitionKey = if ($expectedPartitionKey) { $expectedPartitionKey } else { $expectedId }
                
                if ($EnforceOptimisticConcurrency) {
                    $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -PartitionKey $expectedPartitionKey -Etag $MOCK_ETAG
                } else {
                    $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -PartitionKey $expectedPartitionKey
                }
                AssertHashtablesEqual $expectedHeaders $headers
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                VerifyGetAuthHeader $ResourceGroup $SubscriptionId $Database $verb $resourceType $resourceUrl $now | Out-Null
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }
        }

        It "Sends correct request with default partition key" {            
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
                "_etag" = $MOCK_ETAG;
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers | Out-Null
        
                $response
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Sends correct request with custom explicit partition key" {
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
                "_etag" = $MOCK_ETAG;
            }

            $MOCK_PARTITION_KEY = "MOCK_PARTITION_KEY"

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers -ExpectedPartitionKey $MOCK_PARTITION_KEY | Out-Null
        
                $response
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -PartitionKey $MOCK_PARTITION_KEY

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Sends correct request with custom partition key callback" {
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
                "_etag" = $MOCK_ETAG;
            }

            $MOCK_PARTITION_KEY = "MOCK_PARTITION_KEY"
            $MOCK_GET_PARTITION_KEY = { 
                param($obj)

                $obj | Should -BeExactly $payload | Out-Null

                $MOCK_PARTITION_KEY
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers -ExpectedPartitionKey $MOCK_PARTITION_KEY | Out-Null
        
                $response
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -GetPartitionKeyBlock $MOCK_GET_PARTITION_KEY

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Optimistic concurrency can be disabled" {
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
                "_etag" = $MOCK_ETAG;
            }

            $MOCK_PARTITION_KEY = "MOCK_PARTITION_KEY"
            $MOCK_GET_PARTITION_KEY = { 
                param($obj)

                $obj | Should -BeExactly $payload | Out-Null

                $MOCK_PARTITION_KEY
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers -ExpectedPartitionKey $MOCK_PARTITION_KEY -EnforceOptimisticConcurrency $false | Out-Null
        
                $response
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -GetPartitionKeyBlock $MOCK_GET_PARTITION_KEY -EnforceOptimisticConcurrency $false

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Sends correct request with custom partition key callback for multiple inputs" {
            $payloads = @(
                @{ id = "1"; "_etag" = $MOCK_ETAG };
                @{ id = "2"; "_etag" = $MOCK_ETAG };
                @{ id = "3"; "_etag" = $MOCK_ETAG };
            )

            $global:idx = 0

            $MOCK_GET_PARTITION_KEY = { 
                param($obj)

                $obj | Should -BeExactly $payloads[$global:idx] | Out-Null

                $obj.id
            }

            $global:expectedResponses = @()

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                VerifyGetAuthHeader $ResourceGroup $SubscriptionId $Database $verb $resourceType $resourceUrl $now -ExpectedId $payloads[$global:idx].id | Out-Null
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payloads[$global:idx] $headers -ExpectedId $payloads[$global:idx].id | Out-Null
        
                $global:idx += 1

                $response = @{
                    StatusCode = 200;
                    Content = $global:idx;
                }

                $global:expectedResponses += $response

                $response
            }

            $result = $payloads | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -GetPartitionKeyBlock $MOCK_GET_PARTITION_KEY

            $result | Should -BeExactly $global:expectedResponses
            $result.Count | Should -Be $payloads.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $payloads.Count
            Assert-MockCalled Get-AuthorizationHeader -Times $payloads.Count
        }
        
        It "Url encodes the record id in the API url" {    
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $testRecordId = "MOCK/RECORD/ID"
            $expectedApiRecordId = [uri]::EscapeDataString($testRecordId)
            $expectedAuthHeaderRecordId = $testRecordId # The id in the auth header should not be encoded

            $payload = @{
                id = $testRecordId;
                "_etag" = $MOCK_ETAG;
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 

                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers -expectedId $expectedApiRecordId -expectedPartitionKey $testRecordId | Out-Null
        
                $response
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$expectedAuthHeaderRecordId"
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Get-AuthorizationHeader -Times 1
        }

        It "Should handle exceptions gracefully" {    
            $response = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
                "_etag" = $MOCK_ETAG;
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $response)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $response

                $recordResponse
            }

            $result = $payload | Update-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -PartitionKey $MOCK_PARTITION_KEY

            $result | Should -BeExactly $recordResponse
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }
    }
}