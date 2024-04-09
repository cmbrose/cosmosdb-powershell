Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-AllCosmosDbRecords" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now) {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "get"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyInvokeCosmosDbApiRequest($verb, $url, $body, $headers, $refreshAuthHeaders, $partitionKey = $MOCK_RECORD_ID) {
                $verb | Should -Be "get"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs"        
                $body | Should -Be $null

                $authHeaders = Invoke-Command -ScriptBlock $refreshAuthHeaders
                    
                $global:capturedNow | Should -Not -Be $null

                $authHeaders.now | Should -Be $global:capturedNow
                $authHeaders.encodedAuthString | Should -Be $MOCK_AUTH_HEADER

                $expectedHeaders = Get-CommonHeaders -isQuery $true
            
                AssertHashtablesEqual $expectedHeaders $headers
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                VerifyGetAuthHeader $ResourceGroup $SubscriptionId $Database $verb $resourceType $resourceUrl $now | Out-Null
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }
        }

        It "Sends correct request" {    
            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers $refreshAuthHeaders | Out-Null
        
                $response
            }

            $result = Get-AllCosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

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
                Content    = "1";
                Headers    = @{};
            }

            $response3 = @{
                StatusCode = 200;
                Content    = "1";
                Headers    = @{};
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers $refreshAuthHeaders | Out-Null
        
                $response1
                $response2
                $response3
            }

            $result = Get-AllCosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result.Count | Should -Be 3
            $result[0] | Should -BeExactly $response1
            $result[1] | Should -BeExactly $response2
            $result[2] | Should -BeExactly $response3

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
        }

        It "Should handle exceptions gracefully" {    
            $response = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers, $refreshAuthHeaders) 
                
                VerifyInvokeCosmosDbApiRequest $verb $url $body $headers $refreshAuthHeaders | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $response)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $response

                $recordResponse
            }

            $result = Get-AllCosmosDbRecords -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION

            $result | Should -BeExactly $recordResponse
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
        }
    }
}