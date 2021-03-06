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
                Key1 = "Value1";
                Key2 = 2;
                Nested = @{
                    NestedKey1 = "NestedValue1";
                    NestedKey2 = 2;
                } 
            }

            $response = @{
                StatusCode = 200;
                Content = ($content | ConvertTo-Json -Depth 100)
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

        It "Throws not found for 404" {
            $response = @{
                StatusCode = 404;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "Record not found"
        }
        
        It "Throws throttle for 429" {
            $response = @{
                StatusCode = 429;
            }

            { $response | Get-CosmosDbRecordContent } | Should -Throw "Request rate limited"
        }
            
        It "Throws useful error for unknown errors" {
            $errorMessage = "Mock error message"
            $errorResponse = @{
                message = $errorMessage
            } | ConvertTo-Json

            $response = [pscustomobject] @{
                StatusCode = 401;
            }
            $response | Add-Member -memberType ScriptMethod -Name "GetResponseStream" -Value { [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($errorResponse)) } -Force


            { $response | Get-CosmosDbRecordContent } | Should -Throw "Request failed with status code 401 with message`n`n$errorMessage"
        }
    }
}