Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    BeforeAll {        
        $ORIG_PS_EDITION = $PSVersionTable.PSEdition
    }

    AfterAll {
        $PSVersionTable.PSEdition = $ORIG_PS_EDITION
    }

    Describe "Get-ExceptionResponseOrThrow" {
        It "Handles Desktop" {
            $PSVersionTable.PSEdition = "Desktop"

            $errorMessage = "Mock error message"
            $errorResponse = @{
                message = $errorMessage
            } | ConvertTo-Json

            $response = [pscustomobject] @{
                StatusCode = 401;
            }
            $response | Add-Member -memberType ScriptMethod -Name "GetResponseStream" -Value { [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($errorResponse)) } -Force

            $errorRecord = [PSCustomObject]@{
                Exception = [PSCustomObject]@{
                    Response = $response
                }
            }

            $result = Get-ExceptionResponseOrThrow $errorRecord

            $result.StatusCode | Should -Be $response.StatusCode
            $result.Content | Should -Be $errorResponse
            $result.RawResponse | Should -BeExactly $response
        }

        It "Handles Core" {
            $PSVersionTable.PSEdition = "Core"

            $errorMessage = "Mock error message"
            $errorResponse = @{
                message = $errorMessage
            } | ConvertTo-Json

            $response = [pscustomobject] @{
                StatusCode = 401;
            }
            $response | Add-Member -memberType ScriptMethod -Name "GetResponseStream" -Value { throw "Should not be called" } -Force

            $errorRecord = [PSCustomObject]@{
                Exception = [PSCustomObject]@{
                    Response = $response
                };
                ErrorDetails = [PSCustomObject]@{
                    Message = $errorResponse
                }
            }

            $result = Get-ExceptionResponseOrThrow $errorRecord

            $result.StatusCode | Should -Be $response.StatusCode
            $result.Content | Should -Be $errorResponse
            $result.RawResponse | Should -BeExactly $response
        }

        It "Handles non-http errors" {
            $PSVersionTable.PSEdition = "Core"

            $errorRecord = [PSCustomObject]@{
                Exception = [Exception]@{}
            }

            $didThrow = $false
            try {
                Get-ExceptionResponseOrThrow $errorRecord
            } catch {
                $_.Exception | Should -BeExactly $errorRecord.Exception
                $didThrow = $true
            }

            $didThrow | Should -Be $true
        }
    }
}