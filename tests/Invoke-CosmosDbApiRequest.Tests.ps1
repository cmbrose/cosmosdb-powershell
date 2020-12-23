Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    BeforeAll {
        . $PSScriptRoot\Utils.ps1
    }

    Describe "Invoke-CosmosDbApiRequest" {
        It "Correctly uses verb, url, and headers" {                
            $verb = "get"
            $url = [Uri]"https://mock.com"
            $content = @{}
            $headers = @{
                "x-ms-header-1" = "value1";
                "x-ms-header-2" = "value2";
            }
            
            Mock Invoke-WebRequest { 
                param($Method, $Uri, $Body, $Headers) 
                
                $Method | Should -Be $verb
                $Uri | Should -Be $url
                AssertHashtablesEqual $headers $Headers
            }

            Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $content -Headers $headers

            Assert-MockCalled Invoke-WebRequest -Scope It -Times 1
        }

        It "Correctly serializes content" {                
            $verb = "get"
            $url = [Uri]"https://mock.com"
            $content = @{ 
                Key1 = "Value1";
                Key2 = 2;
                Nested = @{
                    Key1 = "Value1";
                    Key2 = 2;
                } 
            }
            $headers = @{}
            
            Mock Invoke-WebRequest { 
                param($Method, $Uri, $Body, $Headers) 
                AssertHashtablesEqual $content ($Body | ConvertFrom-Json | PSObjectToHashtable)
            }

            Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $content -Headers $headers

            Assert-MockCalled Invoke-WebRequest -Scope It -Times 1
        }

        It "Correctly serializes highly nested content" {                
            $verb = "get"
            $url = [Uri]"https://mock.com"
            $content = @{ 
                Key1 = "Value1";
                Key2 = 2;
                Nested = @{
                    Key1 = "Value1";
                    Key2 = 2;
                    Nested = @{
                        Key1 = "Value1";
                        Key2 = 2;
                        Nested = @{
                            Key1 = "Value1";
                            Key2 = 2;
                            Nested = @{
                                Key1 = "Value1";
                                Key2 = 2;
                                Nested = @{
                                    Key1 = "Value1";
                                    Key2 = 2;
                                } 
                            } 
                        }
                    } 
                } 
            }
            $headers = @{}
            
            Mock Invoke-WebRequest { 
                param($Method, $Uri, $Body, $Headers) 
                AssertHashtablesEqual $content ($Body | ConvertFrom-Json | PSObjectToHashtable)
            }

            Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Body $content -Headers $headers

            Assert-MockCalled Invoke-WebRequest -Scope It -Times 1
        }

        It "Sends null body if not set" {                
            $verb = "get"
            $url = [Uri]"https://mock.com"
            $headers = @{}
            
            Mock Invoke-WebRequest { 
                param($Method, $Uri, $Body, $Headers) 

                $Body | Should -Be $null
            }

            Invoke-CosmosDbApiRequest -Verb $verb -Url $url -Headers $headers

            Assert-MockCalled Invoke-WebRequest -Scope It -Times 1
        }
    }
}