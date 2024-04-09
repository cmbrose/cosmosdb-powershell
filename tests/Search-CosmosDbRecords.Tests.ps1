Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Search-CosmosDbRecords" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false
            
            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_QUERY = "MOCK_QUERY"

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now) {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "post"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $actualBody, $expectedBody, $headers, $refreshAuthHeaders, $partitionKey = $MOCK_RECORD_ID) {
                $verb | Should -Be "post"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs"        
                
                $actualBody.Count | Should -Be 2
                $actualBody.query | Should -Be $expectedBody.query
                $actualBody.parameters.count | Should -Be $expectedBody.parameters.count
                
                $expectedBody.parameters | % { 
                    $e = $_
                    $matchedParam = $actualBody.parameters | where { $_.name -eq $e.name } | select -First 1
                    $matchedParam | Should -Not -BeNullOrEmpty -Because ("the expected query params contained a pair named {0}" -f $e.name)
                    $matchedParam.value | Should -Be $e.value -Because ("of the expected query param value for {0}" -f $e.name)
                }
                    
                $authHeaders = Invoke-Command -ScriptBlock $refreshAuthHeaders
                    
                $global:capturedNow | Should -Not -Be $null

                $authHeaders.now | Should -Be $global:capturedNow
                $authHeaders.encodedAuthString | Should -Be $MOCK_AUTH_HEADER

                $expectedHeaders = Get-CommonHeaders -isQuery $true -contentType "application/Query+json"
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
                Content    = "{}";
                Headers    = @{};
            }

            $expectedBody = @{
                query      = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers $refreshAuthHeaders | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Sends correct request with name-value parameters" {    
            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
            }

            $parameters = @(
                @{ name = "param1"; value = 1; };
                @{ name = "param2"; value = "2"; };
            )

            $expectedBody = @{
                query      = $MOCK_QUERY;
                parameters = $parameters;
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers $refreshAuthHeaders | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $parameters -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Sends correct request with hashtable parameters" {    
            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
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
                query      = $MOCK_QUERY;
                parameters = $nameValueParams;
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers $refreshAuthHeaders | Out-Null
        
                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $hashtableParams -DisableExtraFeatures

            $result | Should -BeExactly $response

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Returns multiple responses" {
            $response1 = @{
                StatusCode = 200;
                Content    = "1";
                Headers    = @{};
            }

            $response2 = @{
                StatusCode = 200;
                Content    = "2";
                Headers    = @{};
            }

            $response3 = @{
                StatusCode = 200;
                Content    = "3";
                Headers    = @{};
            }

            $expectedBody = @{
                query      = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers $refreshAuthHeaders | Out-Null
        
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

            $recordResponse = [PSCustomObject]@{}

            $expectedBody = @{
                query      = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $expectedBody $headers $refreshAuthHeaders | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $response)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $response

                $recordResponse
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -DisableExtraFeatures

            $result | Should -BeExactly $recordResponse
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
        }

        It "Uses extra features by default" {    
            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
            }

            $mockParameters = @(@{
                    name  = "Mock";
                    value = "MOCK";
                })

            Mock Search-CosmosDbRecordsWithExtraFeatures {
                param($ResourceGroup, $Database, $Container, $Collection, $Query, $Parameters, $SubscriptionId) 
                
                $ResourceGroup | Should -Be $MOCK_RG | Out-Null
                $Database | Should -Be $MOCK_DB | Out-Null
                $Container | Should -Be $MOCK_CONTAINER | Out-Null
                $Collection | Should -Be $MOCK_COLLECTION | Out-Null
                $Query | Should -Be $MOCK_QUERY | Out-Null
                $SubscriptionId | Should -Be $MOCK_SUB | Out-Null

                AssertArraysEqual $mockParameters $Parameters

                $response
            }

            $result = Search-CosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $mockParameters

            $result | Should -BeExactly $response

            Assert-MockCalled Search-CosmosDbRecordsWithExtraFeatures -Times 1
        }
    }
}