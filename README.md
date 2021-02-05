# cosmosdb-powershell
Powershell module for Cosmos DB operations

[![GitHub Workflow - CI](https://github.com/cmbrose/cosmosdb-powershell/workflows/CI/badge.svg)](https://github.com/cmbrose/cosmosdb-powershell/actions?workflow=CI)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/cmbrose/cosmosdb-powershell)](https://github.com/cmbrose/cosmosdb-powershell/releases/latest)

## Installation

```powershell
Install-Module cosmos-db
```

## Commands

### Get-CosmosDbRecordContent

Extracts and parses the response `Content` of other commands and handles known error codes (404, 429)

Generally this is pipelined after another command which returns an HTTP response - e.g. `Get-CosmosDbRecord ... | Get-CosmosDbRecordContent`

### Get-CosmosDbRecord

Fetches a single DB record, returns the HTTP response of the lookup

#### Examples

```powershell
$record = Get-CosmosDbRecord ...
| Get-CosmosDbRecordContent
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| RecordId | The resource id | Yes |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |
| PartitionKey | The partition key of the resource | No - defaults to `RecordId`<br/>Must be set if the collection uses a different parition scheme |

### Get-AllCosmosDbRecords

Fetches all DB record, returns the HTTP response. The records will be within the `Documents` property of the result.

#### Examples

```powershell
$records = Get-AllCosmosDbRecords ... 
| Get-CosmosDbRecordContent 
| % Documents
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |

### Search-CosmosDbRecords

Queries the DB, returns the HTTP response. The records will be within the `Documents` property of the result.

Unfortunately, queries like aggregates, `TOP`, and `DISTINCT` are not supported - see the Cosmos DB docs [here](https://docs.microsoft.com/en-us/rest/api/cosmos-db/querying-cosmosdb-resources-using-the-rest-api#queries-that-cannot-be-served-by-gateway).

#### Examples

```powershell
# Basic query with no parameters
$records = Search-CosmosDbRecords -Query "SELECT * FROM c WHERE c.Id in (1, 2, 3)" ...
| Get-CosmosDbRecordContent 
| % Documents

# Basic query with parameters as name value pairs
$parameters = @( 
  @{ name = "@id"; value = "1234" },
  @{ name = "@number"; value = 5678 }
)
$records = Search-CosmosDbRecords -Query "SELECT * FROM c WHERE c.Id = @id and c.Number > @number" -Parameters $parameters ...
| Get-CosmosDbRecordContent 
| % Documents

# Basic query with parameters as hashtable
$parameters = @{
  "@id" = "1234";
  "@number" = 5678;
)
$records = Search-CosmosDbRecords -Query "SELECT * FROM c WHERE c.Id = @id and c.Number > @number" -Parameters $parameters ...
| Get-CosmosDbRecordContent 
| % Documents
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| Query | The query as a string with optional parameters | Yes |
| Parameters | Parameters values used in the query. Accepts an array of `name-value` pairs or a hashtable | No |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |
| DisableExtraFeatures | Disables extra query features required to perform operations like aggregates, `TOP`, or `DISTINCT`. Should be used in case the support for these operations has a bug :smile: See the Cosmos DB docs [here](https://docs.microsoft.com/en-us/rest/api/cosmos-db/querying-cosmosdb-resources-using-the-rest-api#queries-that-cannot-be-served-by-gateway). | No - defaults to false |

### New-CosmosDbRecord

Creates a single DB record, returns the HTTP response of the operation

#### Examples

```powershell
# Add a record
New-CosmosDbRecord -Object $record ...

# Add a record from pipeline
$record | New-CosmosDbRecord ...

# Add a record with a custom PartitionKey
$record | New-CosmosDbRecord -PartitionKey $record.PartitionKey ...

# Add several records with a custom PartitionKey
$recordList | New-CosmosDbRecord -GetPartitionKeyBlock { param($r) $r.PartitionKey } ...

# Copy all records from one collection to another
Get-AllCosmosDbRecords -Collection "Collection1" ...
| Get-CosmosDbRecordContent 
| % Documents 
| New-CosmosDbRecord -Collection "Collection2" ...
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| Object | The record to create | Yes<br/>Accepts value from pipeline |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |
| PartitionKey | The partition key of the resource | No - defaults to `Id`<br/>Must be set if the collection uses a different parition scheme |
| GetPartitionKeyBlock | Callback to get the `PartitionKey` from `Object` - useful in pipelines | No - used only if `PartitionKey` is not set |


### Update-CosmosDbRecord

Updates a single DB record, returns the HTTP response of the operation

The record must exist, if it does not the result is a 404

#### Examples

```powershell
# Update a record
Update-CosmosDbRecord -Object $record ...

# Update a record from pipeline
$record | Update-CosmosDbRecord ...

# Update a record with a custom PartitionKey
$record | Update-CosmosDbRecord -PartitionKey $record.PartitionKey ...

# Update several records with a custom PartitionKey
$recordList | Update-CosmosDbRecord -GetPartitionKeyBlock { param($r) $r.PartitionKey } ...

# Updates all records in a DB
$records = Get-AllCosmosDbRecords ...
| Get-CosmosDbRecordContent 
| % Documents 
$records | foreach { $_.Value = "NewValue" }
$records | Update-CosmosDbRecord ...
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| Object | The record to create | Yes<br/>Accepts value from pipeline |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |
| PartitionKey | The partition key of the resource | No - defaults to `Id`<br/>Must be set if the collection uses a different parition scheme |
| GetPartitionKeyBlock | Callback to get the `PartitionKey` from `Object` - useful in pipelines | No - used only if `PartitionKey` is not set |

### Remove-CosmosDbRecord

Deletes a single DB record, returns the HTTP response of the operation

#### Examples

```powershell
Remove-CosmosDbRecord ...
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| ResourceGroup | Azure Resource Group of the database | Yes |
| Database | The database name | Yes |
| Container | The container name inside the database | Yes |
| Collection | The collection name inside the container | Yes |
| RecordId | The resource id | No - if not set, must supply `RecordId` |
| Object | The record to delete - must minimally have an `id` property | No - if not set, must supply `RecordId`<br/>Accepts value from pipeline |
| SubscriptionId | The Azure Subscription Id | No - defaults to whatever `az` defaults to |
| PartitionKey | The partition key of the resource | No - defaults to `Id`<br/>Must be set if the collection uses a different parition scheme |
| GetPartitionKeyBlock | Callback to get the `PartitionKey` from `Object` - useful in pipelines | No - used only if `PartitionKey` is not set |

### Use-CosmosDbInternalFlag

Enables or disables internal flags in the module, normally should only be used for debugging or dogfooding

#### Examples

```powershell
Use-CosmosDbInternalFlag -EnableFiddlerDebugging $true
```

#### Parameters

| Name | Usage | Required |
| - | - | - |
| EnableFiddlerDebugging | Sets the `az` flag `env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION` which enables `az` commands with a Fiddler proxy | No - default is disabled |
| EnableCaching | Enables caching certain values like DB keys, partition ranges, etc. Improves performance of nearly all operations. | No - default is enabled |
| EnablePartitionKeyRangeSearches | **[Experimental]** Enables filtering `Search` queries to relevant partition ranges instead of a full scan. Improves performance of `Search` commands. | No - default is disabled |
