# DSLX primer

Just enough DSLX to read and write small designs. The full language reference
is at https://google.github.io/xls/dslx_reference/.

## Types

| DSLX | Meaning |
|---|---|
| `u8`, `u32`, `uN[13]` | unsigned bit vectors |
| `s8`, `sN[13]` | signed bit vectors |
| `bool` | `u1` |
| `u8[4]` | array of 4 × u8 |
| `(u8, bool)` | tuple |
| `struct Point { x: u32, y: u32 }` | struct |
| `enum Op : u2 { ADD = 0, SUB = 1 }` | enum with explicit width |

Literals carry their type: `u8:255`, `s4:-1`, `u32:0x1f`, `true`.

## Functions

```dslx
import std;

pub fn add_sat(a: u8, b: u8) -> u8 {
    let (overflow, sum) = std::uadd_with_overflow<u32:8>(a, b);
    if overflow { u8:255 } else { sum }
}
```

- The last expression is the return value. There is no `return`.
- `if` is an expression and needs an `else`.
- `pub` makes a function importable from other modules.
- Parametric functions: `fn f<N: u32>(x: uN[N]) -> uN[N]`. Instantiate
  explicitly with `f<u32:8>(…)`, or let the argument types infer `N`.

## Loops

`for` is a bounded fold with an explicit accumulator, not a mutable loop:

```dslx
fn popcount8(x: u8) -> u4 {
    for (i, acc): (u32, u4) in u32:0..u32:8 {
        acc + (((x >> i) as u1) as u4)
    }(u4:0)
}
```

The trailing `(u4:0)` is the accumulator's initial value. Bounds must be
compile-time constants: hardware has no unbounded loops.

## Tests and properties

```dslx
#[test]
fn add_sat_test() {
    assert_eq(add_sat(u8:1, u8:2), u8:3);
}

#[quickcheck]
fn add_sat_never_wraps(a: u8, b: u8) -> bool { add_sat(a, b) >= a }
```

- `#[test]` runs under `dslx_interpreter_main`.
- `#[quickcheck]` is a property over **all** inputs. `prove_quickcheck_main`
  proves it with an SMT solver, or returns a counterexample.

## Modules

- `import std;`, then `std::clog2(x)`, `std::max(a, b)`, … for the stdlib.
- `import my_pkg.utils;` resolves `my_pkg/utils.x` relative to the
  `--dslx_path` roots.
- The stdlib modules shipped with xlsynth-bin are the files in
  `$DSLX_STDLIB_PATH` (`std.x`, `apfloat.x`, `float32.x`, `bfloat16.x`, …).
  Read them for exact signatures.

## Procs

Stateful, channel-based designs (`proc`) also exist. They need
`--generator=pipeline` and more setup; see the upstream reference before
writing one.
