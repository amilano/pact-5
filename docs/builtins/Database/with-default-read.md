## with-default-read
The `with-default-read` special form is used to read a row from a specified table for a given key and bind columns according to provided bindings. If the row is not found, it reads columns from defaults, an object with matching key names.

### Basic syntax

To read a row from a `TABLE` with `DEFAULTs` values and bind columns according to provided `BINDINGS`, use the following syntax:

`(with-default-read TABLE KEY DEFAULTS BINDINGS)`

### Arguments

Use the following arguments to specify the table, key, defaults, bindings, and body for execution using the `with-default-read` Pact special form.

| Argument | Type | Description |
| --- | --- | --- |
| `TABLE` | `table:<{row}>` | Specifies the table from which to read the row. |
| `KEY` | `string` | Specifies the key for which to read the row. |
| `DEFAULTS` | `object:<{row}>` | Specifies the defaults object containing values for missing columns. |
| `BINDINGS` | `binding:<{row}>` | Specifies the bindings for columns to be bound. |
| `BODY` | `<a>` | Specifies the subsequent body statements to be executed. |

### Return value

The `with-default-read` special form returns the result of executing the provided body statements.

### Examples

The following example demonstrates the usage of the `with-default-read` special form within a Pact script. It reads a row from the `accounts` table for the specified key, using default values if the row is not found, and binds the 'balance' and 'ccy' columns for further processing:

```pact
(with-default-read accounts id { "balance": 0, "ccy": "USD" } { "balance":= bal, "ccy":= ccy }
  (format "Balance for {} is {} {}" [id bal ccy]))
```

This example illustrates how to use the `with-default-read` special form to handle missing rows from a table and provide default values for further operations in Pact, ensuring consistent behavior when accessing data.
