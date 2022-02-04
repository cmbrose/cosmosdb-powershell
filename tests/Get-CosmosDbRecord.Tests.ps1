Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-CosmosDbRecord" {                    
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

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now) {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "get"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$MOCK_RECORD_ID"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $body, $headers, $apiUriRecordId=$MOCK_RECORD_ID, $partitionKey=$MOCK_RECORD_ID) {
                $verb | Should -Be "get"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$apiUriRecordId"        
                $body | Should -Be $null
                    
                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -PartitionKey $partitionKey -isQuery $true
            
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

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                $response
            }

            $result = Get-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -RecordId $MOCK_RECORD_ID

            $result | Should -BeExactly $response
        }

        It "Sends correct request with custom partition key" {    
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $partitionKey = "MOCK_PARTITION_KEY"

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers -partitionKey $partitionKey | Out-Null
        
                $response
            }

            $result = Get-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -RecordId $MOCK_RECORD_ID -PartitionKey $partitionKey

            $result | Should -BeExactly $response
        }

        It "Url encodes the record id in the API url" {    
            $response = @{
                StatusCode = 200;
                Content = "{}"
            }

            $testRecordId = "MOCK/RECORD/ID"
            $expectedApiRecordId = [uri]::EscapeDataString($testRecordId)
            $expectedAuthHeaderRecordId = $testRecordId # The id in the auth header should not be encoded

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers -apiUriRecordId $expectedApiRecordId -partitionKey $testRecordId | Out-Null
        
                $response
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs/$expectedAuthHeaderRecordId"
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }

            $result = Get-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -RecordId $testRecordId

            $result | Should -BeExactly $response
        }

        It "Should handle exceptions gracefully" {    
            $response = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $response)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $response

                $recordResponse
            }

            $result = Get-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -RecordId $MOCK_RECORD_ID

            $result | Should -BeExactly $recordResponse
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1        
        }
    }
}