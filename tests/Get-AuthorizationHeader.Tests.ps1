Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-AuthorizationHeader" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_RESOURCE_URL = "MOCK_RESOURCE_URL"
            $MOCK_RESOURCE_TYPE = "MOCK_RESOURCE_TYPE"
            $MOCK_VERB = "MOCK_VERB"
            $MOCK_NOW = "MOCK_NOW"
            $MOCK_AAD_TOKEN = "MOCK_AAD_TOKEN"

            $MOCK_MASTER_KEY_BYTES = [System.Text.Encoding]::UTF8.GetBytes('gVkYp3s6v9y$B&E)H@MbQeThWmZq4t7w')

            Mock Get-Base64Masterkey {
                param($ResourceGroup, $Database, $SubscriptionId)
        
                $ResourceGroup | Should -Be $MOCK_RG | Out-Null
                $Database | Should -Be $MOCK_DB | Out-Null
                $SubscriptionId | Should -Be $MOCK_SUB | Out-Null
                
                [System.Convert]::ToBase64String($MOCK_MASTER_KEY_BYTES)
            }

            Mock Get-AADToken {
                return $MOCK_AAD_TOKEN
            }
        }

        AfterEach {
            $env:COSMOS_DB_FLAG_ENABLE_MASTER_KEY_AUTH = $null
        }

        It "Returns the correct signature hashed with the master key" {
            Use-CosmosDbInternalFlag -enableMasterKeyAuth $true

            $result = Get-AuthorizationHeader -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Verb $MOCK_VERB -ResourceType $MOCK_RESOURCE_TYPE -ResourceUrl $MOCK_RESOURCE_URL -Now $MOCK_NOW

            $expectedSignature = "$($MOCK_VERB.ToLower())`n$($MOCK_RESOURCE_TYPE.ToLower())`n$MOCK_RESOURCE_URL`n$($MOCK_NOW.ToLower())`n`n"

            $hasher = New-Object System.Security.Cryptography.HMACSHA256 -Property @{ Key = $MOCK_MASTER_KEY_BYTES }
            $sigBinary = [System.Text.Encoding]::UTF8.GetBytes($expectedSignature)
            $hashBytes = $hasher.ComputeHash($sigBinary)
            $expectedBase64Hash = [System.Convert]::ToBase64String($hashBytes)
            
            $expectedHeader = [uri]::EscapeDataString("type=master&ver=1.0&sig=$expectedBase64Hash")

            $result | Should -Be $expectedHeader

            Assert-MockCalled Get-Base64Masterkey -Times 1
        }

        It "Returns the correct signature with for entra id auth" {           
            $result = Get-AuthorizationHeader -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Verb $MOCK_VERB -ResourceType $MOCK_RESOURCE_TYPE -ResourceUrl $MOCK_RESOURCE_URL -Now $MOCK_NOW
            
            $expectedHeader = [uri]::EscapeDataString("type=aad&ver=1.0&sig=$MOCK_AAD_TOKEN")

            $result | Should -Be $expectedHeader

            Assert-MockCalled Get-AADToken -Times 1
        }
    }
}