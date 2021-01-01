Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-AuthorizationHeader" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            . $PSScriptRoot\Utils.ps1
        }

        It "Returns the correct headers for default values" {    
            $result = Get-CommonHeaders -Now "MOCK_NOW" -EncodedAuthString "MOCK_AUTH_STRING"

            AssertHashtablesEqual @{
                "x-ms-date" = "MOCK_NOW";
                "x-ms-version" = "2018-12-31";
                "Authorization" = "MOCK_AUTH_STRING";                
                "Cache-Control" = "No-Cache";
                "Content-Type" = "application/json";
            } $result
        }

        It "Includes optional headers when set" {    
            $result = Get-CommonHeaders -Now "MOCK_NOW" -EncodedAuthString "MOCK_AUTH_STRING" -ContentType "MOCK_CONTENT_TYPE" -IsQuery $true -PartitionKey "MOCK_PARTITION_KEY"

            AssertHashtablesEqual @{
                "x-ms-date" = "MOCK_NOW";
                "x-ms-version" = "2018-12-31";
                "Authorization" = "MOCK_AUTH_STRING";                
                "Cache-Control" = "No-Cache";
                "Content-Type" = "MOCK_CONTENT_TYPE";
                "x-ms-documentdb-isquery" = "true";
                "x-ms-documentdb-partitionkey" = "[`"MOCK_PARTITION_KEY`"]";
            } $result
        }
    }
}