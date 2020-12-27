Get-Module cosmos-db | Remove-Module -Force
Import-Module $PSScriptRoot\..\cosmos-db\cosmos-db.psm1 -Force

InModuleScope cosmos-db {
    Describe "Get-FilteredPartitionKeyRangesForQuery" {
        BeforeAll {
            Use-CosmosDbInternalFlag -EnableCaching $false

            . $PSScriptRoot\Utils.ps1

            Function DefaultAllPartitionRanges()
            {
                @(
                    @{ minInclusive = "";   maxExclusive = "aa"; id = 1 };
                    @{ minInclusive = "aa"; maxExclusive = "cc"; id = 2 };
                    @{ minInclusive = "cc"; maxExclusive = "ee"; id = 3 };
                    @{ minInclusive = "ee"; maxExclusive = "ff"; id = 4 };
                )
            }
        }

        It "Returns all ranges for a full range request" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = ""; max = "ff"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            AssertArraysEqual $allRanges $result
        }

        It "Returns correct partition for point on border" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = "aa"; max = "aa"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be "2"
        }

        It "Returns correct partitions for single range across partitions" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = "bb"; max = "dd"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be @(2, 3)
        }

        It "Returns correct partitions for multiple point ranges" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = "bb"; max = "bb"; };
                @{ min = "dd"; max = "dd"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be @(2, 3)
        }

        It "Returns correct partitions for multiple disjoint ranges" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = "bb"; max = "dd"; };
                @{ min = "ee"; max = "ff"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be @(2, 3, 4)
        }

        It "Returns correct partitions for single range withing partition" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = "aa"; max = "ab"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be 2
        }

        It "Returns unique partitions for overlapping partitions" {
            $allRanges = DefaultAllPartitionRanges
            $queryRanges = @(
                @{ min = ""; max = "cc"; };
                @{ min = "bb"; max = "dd"; };
            )

            $result = Get-FilteredPartitionKeyRangesForQuery $allRanges $queryRanges

            $result.id | Should -Be (1, 2, 3)
        }
    }
}