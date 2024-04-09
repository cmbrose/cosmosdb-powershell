Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    BeforeAll {
        Use-CosmosDbInternalFlag -EnableCaching $false
        
        . $PSScriptRoot\Utils.ps1

        $ORIG_PS_EDITION = $PSVersionTable.PSEdition
    }

    AfterAll {
        $PSVersionTable.PSEdition = $ORIG_PS_EDITION
    }

    Describe "Invoke-CosmosDbApiRequestWithContinuation" {
        BeforeEach {
            $ORIG_AUTHORIZATION_HEADER_REFRESH_THRESHOLD = $AUTHORIZATION_HEADER_REFRESH_THRESHOLD
        }
    
        AfterEach {
            $AUTHORIZATION_HEADER_REFRESH_THRESHOLD = $ORIG_AUTHORIZATION_HEADER_REFRESH_THRESHOLD
        }

        It "Handles responses without continuation header" {  
            $PSVersionTable.PSEdition = "Desktop"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_NOW = Get-Time
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock          = "Mock";
                "x-ms-date"   = $MOCK_NOW;
                Authorization = $MOCK_AUTH_STRING;
            }

            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
            }

            $refreshAuthHeaders = {
                return @{
                    now               = $MOCK_NOW;
                    encodedAuthString = $MOCK_AUTH_STRING;
                }
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

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $response
            @($result).Count | Should -Be 1

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Handles responses without continuation header for Powershell 7" {  
            $PSVersionTable.PSEdition = "Core"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_NOW = Get-Time
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock          = "Mock";
                "x-ms-date"   = $MOCK_NOW;
                Authorization = $MOCK_AUTH_STRING;
            }

            $response = @{
                StatusCode = 200;
                Content    = "{}";
                Headers    = @{};
            }

            $refreshAuthHeaders = {
                return @{
                    now               = $MOCK_NOW;
                    encodedAuthString = $MOCK_AUTH_STRING;
                }
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

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $response
            @($result).Count | Should -Be 1

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
        }

        It "Handles continuation response headers" {  
            $PSVersionTable.PSEdition = "Desktop"
            
            $continuationTokens = @($null, "1", "2", "3")

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_NOW = Get-Time
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock          = "Mock";
                "x-ms-date"   = $MOCK_NOW;
                Authorization = $MOCK_AUTH_STRING;
            }

            $refreshAuthHeaders = {
                return @{
                    now               = $MOCK_NOW;
                    encodedAuthString = $MOCK_AUTH_STRING;
                }
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
                    Content    = "$global:idx";
                    Headers    = @{
                        "x-ms-continuation" = $continuationTokens[$global:idx]
                    };
                }

                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count
        }

        It "Handles continuation response headers for Powershell 7" {  
            $continuationTokens = @($null, "100", "200", "300")

            $PSVersionTable.PSEdition = "Core"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_NOW = Get-Time
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock          = "Mock";
                "x-ms-date"   = $MOCK_NOW;
                Authorization = $MOCK_AUTH_STRING;
            }

            $refreshAuthHeaders = {
                return @{
                    now               = $MOCK_NOW;
                    encodedAuthString = $MOCK_AUTH_STRING;
                }
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
                    Content    = "$global:idx";
                    Headers    = @{
                        # The empty here is to trick powershell into no automatically converting the single item array into just a value
                        "x-ms-continuation" = @($continuationTokens[$global:idx], "")
                    };
                }
                
                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count
        }

        It "Clears continuation tokens from headers parameter" {  
            $continuationTokens = @($null, "100")

            $PSVersionTable.PSEdition = "Core"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_NOW = Get-Time
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock          = "Mock";
                "x-ms-date"   = $MOCK_NOW;
                Authorization = $MOCK_AUTH_STRING;
            }

            $refreshAuthHeaders = {
                return @{
                    now               = $MOCK_NOW;
                    encodedAuthString = $MOCK_AUTH_STRING;
                }
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
                    Content    = "$global:idx";
                    Headers    = @{
                        # The empty here is to trick powershell into no automatically converting the single item array into just a value
                        "x-ms-continuation" = @($continuationTokens[$global:idx], "")
                    };
                }
                
                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count
        }

        It "Refreshes auth headers after passing age threshold" {
            # Force each call to refresh
            $AUTHORIZATION_HEADER_REFRESH_THRESHOLD = [System.TimeSpan]::Zero

            $continuationTokens = @($null, "100", "200", "300")

            $PSVersionTable.PSEdition = "Core"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock = "Mock";
            }

            $global:authRefreshCount = 0
            $global:expectedNow = $null

            $refreshAuthHeaders = {
                $global:authRefreshCount += 1
                $global:expectedNow = Get-Time

                return @{
                    now               = $global:expectedNow;
                    encodedAuthString = $MOCK_AUTH_STRING + "_" + $global:authRefreshCount;
                }
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
                
                $headers["Authorization"] | Should -Be ($MOCK_AUTH_STRING + "_" + $global:authRefreshCount) | Out-Null
                $headers.Remove("Authorization")

                $headers["x-ms-date"] | Should -Be $global:expectedNow | Out-Null
                $headers.Remove("x-ms-date")

                AssertHashtablesEqual $MOCK_HEADERS $headers
        
                $response = @{
                    StatusCode = 200;
                    Content    = "$global:idx";
                    Headers    = @{
                        # The empty here is to trick powershell into no automatically converting the single item array into just a value
                        "x-ms-continuation" = @($continuationTokens[$global:idx], "")
                    };
                }
                
                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count

            $global:authRefreshCount | Should -Be $continuationTokens.Count
        }

        It "Does not refresh auth headers before age threshold" {
            # Force each call to refresh
            $AUTHORIZATION_HEADER_REFRESH_THRESHOLD = [System.TimeSpan]::FromHours(1)

            $continuationTokens = @($null, "100", "200", "300")

            $PSVersionTable.PSEdition = "Core"

            $MOCK_VERB = "MOCK_VERB"
            $MOCK_URL = "MOCK_URL"
            $MOCK_AUTH_STRING = "MOCK_AUTH_STRING"
            $MOCK_BODY = @{
                Mock = "Mock"
            }
            $MOCK_HEADERS = @{
                Mock = "Mock";
            }

            $global:authRefreshCount = 0
            $global:expectedNow = $null

            $refreshAuthHeaders = {
                $global:authRefreshCount += 1
                $global:expectedNow = Get-Time

                return @{
                    now               = $global:expectedNow;
                    encodedAuthString = $MOCK_AUTH_STRING + "_" + $global:authRefreshCount;
                }
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
                
                $headers["Authorization"] | Should -Be ($MOCK_AUTH_STRING + "_" + $global:authRefreshCount) | Out-Null
                $headers["x-ms-date"] | Should -Be $global:expectedNow | Out-Null
        
                $response = @{
                    StatusCode = 200;
                    Content    = "$global:idx";
                    Headers    = @{
                        # The empty here is to trick powershell into no automatically converting the single item array into just a value
                        "x-ms-continuation" = @($continuationTokens[$global:idx], "")
                    };
                }
                
                $global:expectedResponses += $response
                $response
            }

            $result = Invoke-CosmosDbApiRequestWithContinuation -Verb $MOCK_VERB -Url $MOCK_URL -Body $MOCK_BODY -Headers $MOCK_HEADERS -RefreshAuthHeaders $refreshAuthHeaders

            $result | Should -BeExactly $global:expectedResponses
            @($result).Count | Should -Be $continuationTokens.Count

            Assert-MockCalled Invoke-CosmosDbApiRequest -Times $continuationTokens.Count

            $global:authRefreshCount | Should -Be 1
        }
    }
}