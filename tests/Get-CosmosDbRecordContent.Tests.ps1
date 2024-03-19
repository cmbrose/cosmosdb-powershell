Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-CosmosDbRecordContent" {
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            . $PSScriptRoot\Utils.ps1
        }

        It "Returns the Content of a successful response" {
            $content = @{ 
                Key1   = "Value1";
                Key2   = 2;
                Nested = @{
                    NestedKey1 = "NestedValue1";
                    NestedKey2 = 2;
                } 
            }

            $response = @{
                StatusCode = 200;
                Content    = ($content | ConvertTo-Json -Depth 100)
            }

            $result = $response | Get-CosmosDbRecordContent

            AssertHashtablesEqual $content ($result | PSObjectToHashtable)   
        }

        It "Returns nothing for a response with no content" {
            $response = @{
                StatusCode = 200;
            }

            $result = $response | Get-CosmosDbRecordContent

            $result | Should -Be $null
        }

        It "Throws unauthorized for 401" {
            Use-CosmosDbReadonlyKeys -Disable

            $response = [pscustomobject] @{
                StatusCode = 401;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(401) Unauthorized"
        }

        It "Throws unauthorized for 401 with a message about readonly keys" {
            Use-CosmosDbReadonlyKeys

            $response = [pscustomobject] @{
                StatusCode = 401;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(401) Unauthorized (used a readonly key)"
        }

        It "Throws not found for 404 - DB not found" {
            $response = @{
                StatusCode = 404;
                Content    = (@{
                        Message = "{`"Errors`":[`"Owner resource does not exist`"]}"
                    } | ConvertTo-Json)
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(404) Database does not exist"
        }
        
        It "Throws not found for 404" {
            $response = @{
                StatusCode = 404;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(404) Record not found"
        }

        It "Throws conflict for 412" {
            Use-CosmosDbReadonlyKeys

            $response = [pscustomobject] @{
                StatusCode = 412;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(412) Conflict"
        }

        It "Throws throttle for 429" {
            $response = @{
                StatusCode = 429;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "(429) Request rate limited"
        }
            
        It "Throws useful error for unknown errors" {
            $errorMessage = "Mock error message"

            $response = [pscustomobject] @{
                StatusCode = 1234;
                Content    = ( @{ Message = $errorMessage; } | ConvertTo-Json);
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "Request failed with status code 1234 with message`n`n$errorMessage"
        }
    }
}