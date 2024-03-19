Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-PartitionKeyRangesOrError" {     
        BeforeEach {
            Use-CosmosDbInternalFlag -EnableCaching $false
        }

        BeforeAll {
            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_RECORD_ID = "MOCK_RECORD_ID"

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now) {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "get"
                $resourceType | Should -Be "pkranges"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $body, $headers, $partitionKey = $MOCK_RECORD_ID) {
                $verb | Should -Be "get"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/pkranges"        
                $body | Should -Be $null
                    
                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER
                $expectedHeaders["x-ms-documentdb-query-enablecrosspartition"] = "true"

                AssertHashtablesEqual $expectedHeaders $headers
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                VerifyGetAuthHeader $ResourceGroup $SubscriptionId $Database $verb $resourceType $resourceUrl $now | Out-Null
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }
        }

        It "Sends correct request and returns ranges" {  
            $expectedRanges = @(
                @{ minInclusive = ""; maxExclusive = "aa"; id = 1 };
                @{ minInclusive = "aa"; maxExclusive = "cc"; id = 2 };
            )

            $response = @{
                StatusCode = 200;
                Content    = (@{ partitionKeyRanges = $expectedRanges } | ConvertTo-Json -Depth 100)
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                $response
            }

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result.ErrorRecord | Should -BeNull
            AssertArraysEqual $expectedRanges $result.Ranges
        }

        It "Handles cached results properly" {
            Use-CosmosDbInternalFlag -EnableCaching $true
            $PARTITION_KEY_RANGE_CACHE = @{}

            $expectedRanges = @(
                @{ minInclusive = ""; maxExclusive = "aa"; id = 1 };
                @{ minInclusive = "aa"; maxExclusive = "cc"; id = 2 };
            )

            $response = @{
                StatusCode = 200;
                Content    = (@{ partitionKeyRanges = $expectedRanges } | ConvertTo-Json -Depth 100)
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                $response
            }

            $null = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $urlKey = "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/pkranges" 
            $cache = Get-CacheValue -Key $urlKey -Cache $PARTITION_KEY_RANGE_CACHE

            $cache.ErrorRecord | Should -BeNull
            AssertArraysEqual $expectedRanges $cache.Ranges

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1

            $result.ErrorRecord | Should -BeNull
            AssertArraysEqual $expectedRanges $result.Ranges
        }

        It "Handles continuations correctly" {
            Use-CosmosDbInternalFlag -EnableCaching $true
            $PARTITION_KEY_RANGE_CACHE = @{}

            $expectedRanges1 = @(
                @{ minInclusive = ""; maxExclusive = "aa"; id = 1 };
                @{ minInclusive = "aa"; maxExclusive = "cc"; id = 2 };
            )
            $expectedRanges2 = @(
                @{ minInclusive = "cc"; maxExclusive = "dd"; id = 1 };
                @{ minInclusive = "dd"; maxExclusive = "ee"; id = 2 };
            )
            $expectedRanges3 = @(
                @{ minInclusive = "ee"; maxExclusive = "gg"; id = 1 };
                @{ minInclusive = "gg"; maxExclusive = "hh"; id = 2 };
            )

            $response1 = @{
                StatusCode = 200;
                Content    = (@{ partitionKeyRanges = $expectedRanges1 } | ConvertTo-Json -Depth 100)
            }
            $response2 = @{
                StatusCode = 200;
                Content    = (@{ partitionKeyRanges = $expectedRanges2 } | ConvertTo-Json -Depth 100)
            }
            $response3 = @{
                StatusCode = 200;
                Content    = (@{ partitionKeyRanges = $expectedRanges3 } | ConvertTo-Json -Depth 100)
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                $response1
                $response2
                $response3
            }

            $_ = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $urlKey = "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/pkranges" 
            $cache = Get-CacheValue -Key $urlKey -Cache $PARTITION_KEY_RANGE_CACHE

            $allExpectedRanges = $expectedRanges1 + $expectedRanges2 + $expectedRanges3

            $cache.ErrorRecord | Should -BeNull
            AssertArraysEqual $allExpectedRanges $cache.Ranges

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1

            $result.ErrorRecord | Should -BeNull
            AssertArraysEqual $allExpectedRanges $result.Ranges
        }

        It "Should handle exceptions gracefully" {    
            $exception = [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, [System.Net.HttpWebResponse]@{})

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                throw $exception
            }

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result.Ranges | Should -BeNull
            $result.ErrorRecord.Exception | Should -BeExactly $exception
        }
    }
}