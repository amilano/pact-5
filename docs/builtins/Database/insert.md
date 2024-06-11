## insert

Use `insert` to write an entry in a specified `table` for a given `key` of `object` data.
This operation fails if data already exists for the specified key.

### Basic syntax

To insert data into a table for a specified key, use the following syntax:

`(insert table key object)`

### Arguments

Use the following arguments to specify the table, key, and object data you want to insert using the `insert` Pact function.

| Argument | Type | Description |
| --- | --- | --- |
| `table` | `table<{row}>` | Specifies the table where the entry will be written. |
| `key` | `string` | Specifies the key for which the data will be inserted. |
| `object` | `object<{row}>` | Specifies the object data to be inserted for the specified key. |

### Return value

The `insert` function returns a string indicating the success or an exception on failure of the operation.

### Examples

The following example demonstrates the use of `insert` to insert data into the `accounts` table:

```pact
(insert accounts id { "balance": 0.0, "note": "Created account." })
```

In this example, data with the specified object is inserted into the `accounts` table for the given `id` key. If successful, it returns a string indicating success; otherwise, it fails if data already exists for the specified key.
