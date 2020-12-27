Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    BeforeAll {
        Use-CosmosDbInternalFlag -EnableCaching $false
        
        . $PSScriptRoot\Utils.ps1
    }

    Describe "Invoke-CosmosDbApiRequestWithContinuation" {
        It "Handles responses without continuation header" {  
            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock = "Mock";
            }

            $response = @{
                StatusCode = 200;
                Content = "{}";
                Headers = @{};
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 

                $headers["x-ms-continuation"] | Should -BeNullOrEmpty |  Out-Null

                $verb | Should -Be $MOCK_VERB | Out-Null
                $url | Should -Be $MOCK_URL | Out-Null
                $body | Should -Be $MOCK_BODY | Out-Null
                $headers | Should -Be $MOCK_HEADERS | Out-Null    

                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS

            $result | Should -BeExactly $response
            @($result).Count | Should -Be 1

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Handles continuation response headers" {  
            $continuationTokens = @($null, "1", "2", "3")

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock = "Mock";
            }

            $global:idx = 0
            $global:expectedResponses = @()

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers)             

                $verb | Should -Be $MOCK_VERB | Out-Null
                $url | Should -Be $MOCK_URL | Out-Null
                $body | Should -Be $MOCK_BODY | Out-Null

                $headers["x-ms-continuation"] | Should -Be $continuationTokens[$global:idx] | Out-Null
                $global:idx = $global:idx + 1
                $headers.Remove("x-ms-continuation")
                AssertHashtablesEqual $MOCK_HEADERS $headers
        
                $response = @{
                    StatusCode = 200;
                    Content = "$global:idx";
                    Headers = @{
                        "x-ms-continuation" = $continuationTokens[$global:idx]
                    };
                }

                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count
        }
    }
}