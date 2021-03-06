Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-PartitionKeyRangesOrError" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_RECORD_ID = "MOCK_RECORD_ID"

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
            {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "get"
                $resourceType | Should -Be "pkranges"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $body, $headers, $partitionKey=$MOCK_RECORD_ID)
            {
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
                Content = (@{ partitionKeyRanges = $expectedRanges } | ConvertTo-Json -Depth 100)
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                $response
            }

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            AssertArraysEqual $expectedRanges $result
        }

        It "Should handle exceptions gracefully" {    
            $exception = [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, [System.Net.HttpWebResponse]@{})

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                throw $exception
            }

            $result = Get-PartitionKeyRangesOrError -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result | Should -BeExactly $exception
        }
    }
}