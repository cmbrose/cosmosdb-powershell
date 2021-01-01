# Release Notes
All notable changes and release history of the "cosmos-db" module will be documented in this file.

## 1.8
* Bugfix for continuation tokens on Powershell version 7+

## 1.7
* Minor interface improvements

## 1.6
* Adds `Use-CosmosDbInternalFlag` command to access some experimental features and debugging helpers
* Fixes support for extra query features in `Search-CosmosDbRecords` for DBs with more than one partition key range
  * Currently all partitions are scanned unless the experimental flag `EnablePartitionKeyRangeSearches` is set via `Use-CosmosDbInternalFlag`
  * Later the flag will become enabled by default to improve the efficiency of all `Search` queries

## 1.5
* Fixes a bug for `New-` and `Update-` commands for payloads with nested objects
  * Was using the default `ConvertTo-Json` to serialize payload which only went 2 levels deep and used empty strings for objects deeper than that

## 1.4
* Fixes incorrectly mandatory parameters to `Search-CosmosDbRecords`

## 1.3
* Renames all `Subscription` parameters to `SubscriptionId`
* Renames all `Id` parameters to `RecordId`
* Adds support for `Get-Help` for commands

## 1.2
* Add support for `Search-CosmosDbRecords` hashtables in addition to name-value pairs
    ```powershell
    Search-CosmosDbRecords -Parameters @{ "@param1" = "value1"; "@param2" = "value2" }
    ```

## 1.1
* Update the module metadata to point to the repo, license, etc

## 1.0
* Initial release