Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Search-CosmosDbRecords" {                    
        BeforeAll {
            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_QUERY = "MOCK_QUERY"

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
                
                $actualBody.Count | Should -Be 2
                $actualBody.query | Should -Be $expectedBody.query
                $actualBody.parameters | % { 
                    $a = $_
                    $matchedParam = $expectedBody.parameters | where { $_.name -eq $a.name } | select -First 1
                    $matchedParam | Should -Not -BeNullOrEmpty
                    $a.value | Should -Be $matchedParam.value
                 }
                    
                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -isQuery $true -contentType "application/Query+json"
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

        It "Sends correct request with no parameters" {    
            $response = @{
                StatusCode = 200;
                Content = "{}";
                Headers = @{};
            }

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Sends correct request with name-value parameters" {    
            $response = @{
                StatusCode = 200;
                Content = "{}";
                Headers = @{};
            }

            $parameters = @(
                @{ name = "param1"; value = 1; };
                @{ name = "param2"; value = "2"; };
            )

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = $parameters;
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $parameters -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Sends correct request with hashtable parameters" {    
            $response = @{
                StatusCode = 200;
                Content = "{}";
                Headers = @{};
            }

            $nameValueParams = @(
                @{ name = "param1"; value = 1; };
                @{ name = "param2"; value = "2"; };
            )
            $hashtableParams = @{
                param1 = 1;
                param2 = "2"
            }

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = $nameValueParams;
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $hashtableParams -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Returns multiple responses" {
            $response1 = @{
                StatusCode = 200;
                Content = "1";
                Headers = @{};
            }

            $response2 = @{
                StatusCode = 200;
                Content = "1";
                Headers = @{};
            }

            $response3 = @{
                StatusCode = 200;
                Content = "1";
                Headers = @{};
            }

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                $response1
                $response2
                $response3
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -DisableExtraFeatures

            $result.Count | Should -Be 3
            $result[0] | Should -BeExactly $response1
            $result[1] | Should -BeExactly $response2
            $result[2] | Should -BeExactly $response3

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Should handle exceptions gracefully" {    
            $response = [System.Net.HttpWebResponse]@{}

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $response)
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -DisableExtraFeatures

            $result | Should -BeExactly $response
        }
    }
}