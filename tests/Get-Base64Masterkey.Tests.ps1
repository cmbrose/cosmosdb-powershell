Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-Base64Masterkey" {                    
        BeforeAll {
            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_KEY = "MOCK_KEY"
            $MOCK_READONLY_KEY = "MOCK_READONLY_KEY"

            Mock Get-Base64MasterkeyWithoutCaching {
                param($ResourceGroup, $Database, $SubscriptionId, $Readonly)
        
                $ResourceGroup | Should -Be $MOCK_RG | Out-Null
                $Database | Should -Be $MOCK_DB | Out-Null
                $SubscriptionId | Should -Be $MOCK_SUB | Out-Null
                
                if ($Readonly) {
                    $MOCK_READONLY_KEY
                }
                else {
                    $MOCK_KEY
                }
            }
        }

        AfterAll {
            $env:COSMOS_DB_FLAG_ENABLE_READONLY_KEYS = $null
        }

        BeforeEach {
            # This is defined in the main module
            $MASTER_KEY_CACHE = @{}
        }

        It "Only calls the core logic once with caching enabled" {
            Use-CosmosDbReadonlyKeys -Disable
            Use-CosmosDbInternalFlag -EnableCaching $true

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_KEY | Out-Null

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_KEY | Out-Null

            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 1 -Exactly
        }

        It "Should return the readonly key when configured" {    
            Use-CosmosDbReadonlyKeys
            Use-CosmosDbInternalFlag -EnableCaching $true

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_READONLY_KEY | Out-Null

            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 1 -Exactly
        }

        It "Should not use a cached key when switching between readonly and writable" {    
            Use-CosmosDbInternalFlag -EnableCaching $true

            Use-CosmosDbReadonlyKeys -Disable

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_KEY | Out-Null

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_KEY | Out-Null

            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 1 -Exactly

            Use-CosmosDbReadonlyKeys

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_READONLY_KEY | Out-Null
            
            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_READONLY_KEY | Out-Null

            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 2 -Exactly

            Use-CosmosDbReadonlyKeys -Disable

            $key = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key | Should -Be $MOCK_KEY | Out-Null

            # This one should reuse the existing writable key cached value and shouldn't increment the call counter
            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 2 -Exactly
        }
        
        It "Calls the core logic for each call with caching disabled" {  
            Use-CosmosDbReadonlyKeys -Disable 
            Use-CosmosDbInternalFlag -EnableCaching $false

            $key1 = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key1 | Should -Be $MOCK_KEY | Out-Null

            $key2 = Get-Base64Masterkey  -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB
            $key2 | Should -Be $MOCK_KEY | Out-Null

            Assert-MockCalled Get-Base64MasterkeyWithoutCaching -Times 2 -Exactly
        }
    }
}