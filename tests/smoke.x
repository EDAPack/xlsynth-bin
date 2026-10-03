// xlsynth-bin smoke-test fixture. Kept dslx_fmt-clean: the smoke test asserts
// the formatter is a fixed point on it.
import std;

pub fn add_sat(a: u8, b: u8) -> u8 {
    let (overflow, sum) = std::uadd_with_overflow<u32:8>(a, b);
    if overflow { u8:255 } else { sum }
}

#[test]
fn add_sat_test() {
    assert_eq(add_sat(u8:1, u8:2), u8:3);
    assert_eq(add_sat(u8:200, u8:100), u8:255);
}

#[quickcheck]
fn add_sat_never_wraps(a: u8, b: u8) -> bool { add_sat(a, b) >= a }
