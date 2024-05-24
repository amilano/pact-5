## dec
Use `dec` to cast an integer `x` to a decimal value.

### Basic syntax

To cast an integer `x` to a decimal value, use the following syntax:

`(dec X)`

### Arguments

Use the following argument to specify the integer `x` for the `dec` Pact function.

| Argument | Type | Description |
| --- | --- | --- |
| `x` | `integer` | Specifies the integer to cast to a decimal value. |

### Return values

The `dec` function returns the specified integer `x` as a decimal value.

### Example

The following example demonstrates the `dec` function:

```pact
pact> (dec 3)
3.0
```

In this example, `(dec 3)` is used to cast the integer `3` to a decimal value. The function returns `3.0` as a decimal. This can be useful when you need to work with decimal values in Pact but have integer inputs.
