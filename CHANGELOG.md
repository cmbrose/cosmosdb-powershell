# Release Notes
All notable changes and release history of the "cosmos-db" module will be documented in this file.

## 1.18
* Fixes a bug in commands like `Search-CosmosDbRecords` and `Get-AllCosmosDbRecords` which might run for long enough that their auth tokens expire and aren't refreshed. Auth tokens will now be refreshed every 10 min as these commands run.
* Adds a `-enableAuthHeaderReuse` flag to `Use-CosmosDbInternalFlag` which disables the 10 minute refresh period and forces auth header refreshes for every API call.

## 1.17
* Fixes `Search-CosmosDbRecords` for partition key range uses where the PK range fetch call didn't use continuation tokens and might miss some results.

## 1.16
* Adds support for readonly keys via `Use-CosmosDbReadonlyKeys`

## 1.15
* Adds support for optimistic concurrency (enabled by default) to `Update-CosmosDbRecord`

## 1.14
* Fixes a bug where record ids were not encoded in the API calls which broke Get-, Remove-, and Update- for records with ids that contained characters such as `'/'`

## 1.13
* Consistent handling of request errors in PS7 vs. PS5
* Gives a better error message if the database doesn't exist

## 1.10
* Fixes a bug that caused 401s with ids that contained uppercase characters

## 1.9
* Add support for pipelined objects in `Remove-CosmosDbRecord`
* Add optional `GetPartitionKeyBlock` argument to `Remove-CosmosDbRecord`

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