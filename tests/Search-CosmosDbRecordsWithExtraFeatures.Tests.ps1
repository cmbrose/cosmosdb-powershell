Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Search-CosmosDbRecordsWithExtraFeatures" {                    
        BeforeAll {
            Use-CosmosDbInternalFlag -EnablePartitionKeyRangeSearches $false

            . $PSScriptRoot\Utils.ps1    

            $global:capturedNow = $null

            $MOCK_SUB = "MOCK_SUB"
            $MOCK_RG = "MOCK_RG"
            $MOCK_DB = "MOCK_DB"
            $MOCK_CONTAINER = "MOCK_CONTAINER"
            $MOCK_COLLECTION = "MOCK_COLLECTION"
            $MOCK_QUERY = "MOCK_QUERY"

            $MOCK_EMPTY_QUERY_PLAN = [hashtable]@{
                QueryInfo = @{
                    RewrittenQuery = ""
                };
                QueryRanges = @(
                    @{ min = ""; max = "ff" };
                )
            }

            $MOCK_PARTITION_RANGES = @(
                @{ minInclusive = ""; maxExclusive = "aa"; id = 1 };
                @{ minInclusive = "aa"; maxExclusive = "cc"; id = 2 };
                @{ minInclusive = "cc"; maxExclusive = "ee"; id = 3 };
                @{ minInclusive = "ee"; maxExclusive = "ff"; id = 4 };
            )

            $MOCK_AUTH_HEADER = "MockAuthHeader"

            Function VerifyGetAuthHeader($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
            {
                $ResourceGroup | Should -Be $MOCK_RG
                $SubscriptionId | Should -Be $MOCK_SUB

                $verb | Should -Be "post"
                $resourceType | Should -Be "docs"
                $resourceUrl | Should -Be "dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION"
            }

            Function VerifyQueryPlanApiRequest($verb, $url, $actualBody, $expectedBody, $headers)
            {
                $verb | Should -Be "post"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs"        
                
                $actualBody.Count | Should -Be 2
                $actualBody.query | Should -Be $expectedBody.query
                $actualBody.parameters.count | Should -Be $expectedBody.parameters.count
                
                $expectedBody.parameters | % { 
                    $e = $_
                    $matchedParam = $actualBody.parameters | where { $_.name -eq $e.name } | select -First 1
                    $matchedParam | Should -Not -BeNullOrEmpty -Because ("the expected query params contained a pair named {0}" -f $e.name)
                    $matchedParam.value | Should -Be $e.value -Because ("of the expected query param value for {0}" -f $e.name)
                }
                    
                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -isQuery $true -contentType "application/Query+json"
                $expectedHeaders += @{
                    "x-ms-documentdb-query-enablecrosspartition" = "true";
                    "x-ms-cosmos-supported-query-features" = "NonValueAggregate, Aggregate, Distinct, MultipleOrderBy, OffsetAndLimit, OrderBy, Top, CompositeAggregate, GroupBy, MultipleAggregates";
                    "x-ms-documentdb-query-enable-scan" = "true";
                    "x-ms-documentdb-query-parallelizecrosspartitionquery" = "true";
                    "x-ms-cosmos-is-query-plan-request" = "True";
                }

                AssertHashtablesEqual $expectedHeaders $headers
            }

            Function VerifyQueryApiRequest($verb, $url, $actualBody, $expectedBody, $headers, $expectedPartitionRangeId, $expectedContinuationToken)
            {
                $verb | Should -Be "post"
                $url | Should -Be "https://$MOCK_DB.documents.azure.com/dbs/$MOCK_CONTAINER/colls/$MOCK_COLLECTION/docs"        
                
                $actualBody.Count | Should -Be 2
                $actualBody.query | Should -Be $expectedBody.query
                $actualBody.parameters.count | Should -Be $expectedBody.parameters.count
                
                $expectedBody.parameters | % { 
                    $e = $_
                    $matchedParam = $actualBody.parameters | where { $_.name -eq $e.name } | select -First 1
                    $matchedParam | Should -Not -BeNullOrEmpty -Because ("the expected query params contained a pair named {0}" -f $e.name)
                    $matchedParam.value | Should -Be $e.value -Because ("of the expected query param value for {0}" -f $e.name)
                }
                    
                $global:capturedNow | Should -Not -Be $null

                $expectedHeaders = Get-CommonHeaders -now $global:capturedNow -encodedAuthString $MOCK_AUTH_HEADER -isQuery $true -contentType "application/Query+json"
                $expectedHeaders += @{
                    "x-ms-documentdb-query-enablecrosspartition" = "true";
                    "x-ms-cosmos-supported-query-features" = "NonValueAggregate, Aggregate, Distinct, MultipleOrderBy, OffsetAndLimit, OrderBy, Top, CompositeAggregate, GroupBy, MultipleAggregates";
                    "x-ms-documentdb-query-enable-scan" = "true";
                    "x-ms-documentdb-query-parallelizecrosspartitionquery" = "true";
                    "x-ms-documentdb-partitionkeyrangeid" = $expectedPartitionRangeId;
                    "x-ms-continuation" = $expectedContinuationToken;
                }

                AssertHashtablesEqual $expectedHeaders $headers
            }

            Mock Get-AuthorizationHeader {
                param($ResourceGroup, $SubscriptionId, $Database, $verb, $resourceType, $resourceUrl, $now)
        
                VerifyGetAuthHeader $ResourceGroup $SubscriptionId $Database $verb $resourceType $resourceUrl $now | Out-Null
        
                $global:capturedNow = $now
        
                $MOCK_AUTH_HEADER
            }

            Mock Get-PartitionKeyRangesOrError {
                param($ResourceGroup, $Database, $Container, $Collection, $SubscriptionId)

                $ResourceGroup | Should -Be $MOCK_RG | Out-Null
                $Database | Should -Be $MOCK_DB | Out-Null
                $Container | Should -Be $MOCK_CONTAINER | Out-Null
                $Collection | Should -Be $MOCK_COLLECTION | Out-Null
                $SubscriptionId | Should -Be $MOCK_SUB | Out-Null

                @{ Ranges = $MOCK_PARTITION_RANGES }
            }
        }

        It "Sends correct request with no parameters and basic query plan" {    
            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            $global:expectedResponses = @()
            $global:partitionIdx = 0

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                @{ Content = ($MOCK_EMPTY_QUERY_PLAN | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $MOCK_PARTITION_RANGES[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $expectedPartitionId | Out-Null

                $response = @{
                    StatusCode = 200;
                    Content = "$global:partitionIdx";
                    Headers = @{};
                }

                $global:expectedResponses += $response
                $global:partitionIdx += 1

                $response
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $MOCK_PARTITION_RANGES.Count
        }

        It "Sends correct request with name-value parameters" {    
            $parameters = @(
                @{ name = "param1"; value = 1; };
                @{ name = "param2"; value = "2"; };
            )

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = $parameters;
            }

            $global:expectedResponses = @()
            $global:partitionIdx = 0

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                @{ Content = ($MOCK_EMPTY_QUERY_PLAN | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $MOCK_PARTITION_RANGES[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $expectedPartitionId | Out-Null

                $response = @{
                    StatusCode = 200;
                    Content = "$global:partitionIdx";
                    Headers = @{};
                }

                $global:expectedResponses += $response
                $global:partitionIdx += 1

                $response
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $parameters

            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $MOCK_PARTITION_RANGES.Count
        }

        It "Sends correct request with hashtable parameters" {    
            $nameValueParams = @(
                @{ name = "param1"; value = 1; };
                @{ name = "param2"; value = "2"; };
            )
            $hashtableParams = @{
                param1 = 1;
                param2 = "2"
            }

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = $nameValueParams;
            }

            $global:expectedResponses = @()
            $global:partitionIdx = 0

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                @{ Content = ($MOCK_EMPTY_QUERY_PLAN | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $MOCK_PARTITION_RANGES[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $expectedPartitionId | Out-Null

                $response = @{
                    StatusCode = 200;
                    Content = "$global:partitionIdx";
                    Headers = @{};
                }

                $global:expectedResponses += $response
                $global:partitionIdx += 1

                $response
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY -Parameters $hashtableParams

            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $MOCK_PARTITION_RANGES.Count
        }

        It "Sends rewritten query" {    
            $queryPlan = $MOCK_EMPTY_QUERY_PLAN.Clone()
            $queryPlan.QueryInfo = $queryPlan.QueryInfo.Clone()
            $queryPlan.QueryInfo.RewrittenQuery = "MOCK_REWRITTEN_QUERY"

            $expectedQueryPlanBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            $expectedQueryBody = @{
                query = $queryPlan.QueryInfo.RewrittenQuery;
                parameters = @();
            }

            $global:expectedResponses = @()
            $global:partitionIdx = 0

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedQueryPlanBody $headers | Out-Null
        
                @{ Content = ($queryPlan | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $MOCK_PARTITION_RANGES[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedQueryBody $headers $expectedPartitionId | Out-Null

                $response = @{
                    StatusCode = 200;
                    Content = "$global:partitionIdx";
                    Headers = @{};
                }

                $global:expectedResponses += $response
                $global:partitionIdx += 1

                $response
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $MOCK_PARTITION_RANGES.Count
        }

        It "Returns multiple responses" {
            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            $global:partitionIdx = 0
            $global:expectedResponses = @()

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                @{ Content = ($MOCK_EMPTY_QUERY_PLAN | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $MOCK_PARTITION_RANGES[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $expectedPartitionId | Out-Null

                $responses = @(
                    @{
                        StatusCode = 200;
                        Content = "$global:partitionIdx-1";
                        Headers = @{};
                    };
                    @{
                        StatusCode = 200;
                        Content = "$global:partitionIdx-2";
                        Headers = @{};
                    };
                    @{
                        StatusCode = 200;
                        Content = "$global:partitionIdx-3";
                        Headers = @{};
                    };
                )

                $global:partitionIdx += 1
                $global:expectedResponses += $responses

                $responses
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result.Count | Should -Be (3 * $MOCK_PARTITION_RANGES.Count)
            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $MOCK_PARTITION_RANGES.Count
        }

        It "Should handle errors in partition key range request gracefully" {    
            $errorResponse = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            Mock Get-PartitionKeyRangesOrError {
                param($ResourceGroup, $Database, $Container, $Collection, $SubscriptionId)

                $ResourceGroup | Should -Be $MOCK_RG | Out-Null
                $Database | Should -Be $MOCK_DB | Out-Null
                $Container | Should -Be $MOCK_CONTAINER | Out-Null
                $Collection | Should -Be $MOCK_COLLECTION | Out-Null
                $SubscriptionId | Should -Be $MOCK_SUB | Out-Null
        
                return @{ ErrorRecord = @{ Exception = [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $errorResponse) } }
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $errorResponse

                $recordResponse
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $recordResponse

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
        }

        It "Should handle exceptions in query plan request gracefully" {    
            $errorResponse = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $errorResponse)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $errorResponse

                $recordResponse
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $recordResponse

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1     
        }

        It "Should handle exceptions in query requests gracefully" {    
            $errorResponse = [System.Net.HttpWebResponse]@{}

            $recordResponse = [PSCustomObject]@{}

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            $mockQueryPlan = @{
                QueryInfo = @{
                    RewrittenQuery = ""
                };
                QueryRanges = @(
                    @{ min = ""; max = "ff" };
                )
            }

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                $mockQueryPlan
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $MOCK_PARTITION_RANGES[0].id | Out-Null
        
                throw [System.Net.WebException]::new("", $null, [System.Net.WebExceptionStatus]::UnknownError, $errorResponse)
            }

            Mock Get-ExceptionResponseOrThrow {
                param($err)

                $err.Exception.Response | Should -BeExactly $errorResponse

                $recordResponse
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $recordResponse

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times 1
            Assert-MockCalled Get-ExceptionResponseOrThrow -Times 1
        }

        It "Sends correct request with filtered ranges (experimental)" {   
            Use-CosmosDbInternalFlag -EnablePartitionKeyRangeSearches $true
 
            $queryPlan = $MOCK_EMPTY_QUERY_PLAN.Clone()
            $queryPlan.QueryRanges = @(
                { min = "aa"; max = "bb" }
            )

            $expectedBody = @{
                query = $MOCK_QUERY;
                parameters = @();
            }

            $filteredPartitionRanges = @(
                @{ id = "3"; };
                @{ id = "4"; };
            )

            $global:expectedResponses = @()
            $global:partitionIdx = 0

            Mock Invoke-CosmosDbApiRequest {
                param($verb, $url, $body, $headers) 
                
                VerifyQueryPlanApiRequest $verb $url $body $expectedBody $headers | Out-Null
        
                @{ Content = ($MOCK_EMPTY_QUERY_PLAN | ConvertTo-Json) }
            }

            Mock Invoke-CosmosDbApiRequestWithContinuation {
                param($verb, $url, $body, $headers) 
                
                $expectedPartitionId = $filteredPartitionRanges[$global:partitionIdx].id 
                VerifyQueryApiRequest $verb $url $body $expectedBody $headers $expectedPartitionId | Out-Null

                $response = @{
                    StatusCode = 200;
                    Content = "$global:partitionIdx";
                    Headers = @{};
                }

                $global:expectedResponses += $response
                $global:partitionIdx += 1

                $response
            }

            Mock Get-FilteredPartitionKeyRangesForQuery {
                param($allRanges, $queryRanges)

                AssertArraysEqual $MOCK_PARTITION_RANGES $allRanges
                AssertArraysEqual $MOCK_EMPTY_QUERY_PLAN.QueryRanges $queryRanges

                $filteredPartitionRanges
            }

            $result = Search-CosmosDbRecordsWithExtraFeatures -ResourceGroup $MOCK_RG -SubscriptionId $MOCK_SUB -Database $MOCK_DB -Container $MOCK_CONTAINER -Collection $MOCK_COLLECTION -Query $MOCK_QUERY

            $result | Should -BeExactly $global:expectedResponses

            Assert-MockCalled Get-PartitionKeyRangesOrError -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequest -Times 1
            Assert-MockCalled Get-FilteredPartitionKeyRangesForQuery -Times 1
            Assert-MockCalled Invoke-CosmosDbApiRequestWithContinuation -Times $filteredPartitionRanges.Count
        }
    }
}