Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-AadToken" {                    
        BeforeAll {
            $MOCK_TOKEN = @{
                accessToken = "MOCK_TOKEN"
                expires_on  = [System.DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
            }

            Mock Get-AadTokenWithoutCaching {
                return $MOCK_TOKEN
            }
        }

        BeforeEach {
            # This is defined in the main module
            $AAD_TOKEN_CACHE = @{}
        }

        It "Only calls the core logic once with caching enabled" {
            Use-CosmosDbInternalFlag -EnableCaching $true

            $key = Get-AadToken
            $key | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            $key = Get-AadToken
            $key | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            Assert-MockCalled Get-AadTokenWithoutCaching -Times 1 -Exactly
        }

        It "Calls the core logic for each call with caching disabled" {  
            Use-CosmosDbInternalFlag -EnableCaching $false

            $key1 = Get-AadToken
            $key1 | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            $key2 = Get-AadToken
            $key2 | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            Assert-MockCalled Get-AadTokenWithoutCaching -Times 2 -Exactly
        }

        It "Respects token expiration" {
            Use-CosmosDbInternalFlag -EnableCaching $true

            $MOCK_TOKEN = @{
                accessToken = "MOCK_TOKEN"
                expires_on  = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }

            Mock Get-AadTokenWithoutCaching {
                return $MOCK_TOKEN
            }

            $key1 = Get-AadToken
            $key1 | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            $key2 = Get-AadToken
            $key2 | Should -Be $MOCK_TOKEN.accessToken | Out-Null

            Assert-MockCalled Get-AadTokenWithoutCaching -Times 2 -Exactly
        }
    }
}