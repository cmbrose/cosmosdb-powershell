Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "New-CosmosDbRecord" {                    
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

                $verb | Should -Be "post"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $actualBody, $expectedBody, $headers, $partitionKey=$MOCK_RECORD_ID)
            {
                $verb | Should -Be "post"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs"        
                    
                $actualBody | Should -BeExactly $expectedBody 

                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -PartitionKey $partitionKey
            
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
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers | Out-Null
        
                $response
            }

            $result = $payload | New-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

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
            }

            $MOCK_PARTITION_KEY = "MOCK_PARTITION_KEY"

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers $MOCK_PARTITION_KEY | Out-Null
        
                $response
            }

            $result = $payload | New-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -PartitionKey $MOCK_PARTITION_KEY

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
            }

            $MOCK_PARTITION_KEY = "MOCK_PARTITION_KEY"
            $MOCK_GET_PARTITION_KEY = { 
                param($obj)

                $obj | Should -BeExactly $payload | Out-Null

                $MOCK_PARTITION_KEY
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payload $headers $MOCK_PARTITION_KEY | Out-Null
        
                $response
            }

            $result = $payload | New-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -GetPartitionKeyBlock $MOCK_GET_PARTITION_KEY

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Sends correct request with custom partition key callback for multiple inputs" {
            $payloads = @(
                @{ id = "1"  };
                @{ id = "2"  };
                @{ id = "3"  };
            )

            $global:idx = 0

            $MOCK_GET_PARTITION_KEY = { 
                param($obj)

                $obj | Should -BeExactly $payloads[$global:idx] | Out-Null

                $obj.id
            }

            $global:expectedResponses = @()

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $payloads[$global:idx] $headers $payloads[$global:idx].id | Out-Null
        
                $global:idx += 1

                $response = @{
                    StatusCode = 200;
                    Content = $global:idx;
                }

                $global:expectedResponses += $response

                $response
            }

            $result = $payloads | New-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -GetPartitionKeyBlock $MOCK_GET_PARTITION_KEY

            $result | Should -BeExactly $global:expectedResponses
            $result.Count | Should -Be $payloads.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $payloads.Count
        }

        It "Should handle exceptions gracefully" {    
            $response = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            $payload = @{
                id = $MOCK_RECORD_ID;
                key1 = "value1";
                key2 = 2;
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

            $result = $payload | New-CosmosDbRecord -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -PartitionKey $MOCK_PARTITION_KEY

            $result | Should -BeExactly $recordResponse
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
        }
    }
}