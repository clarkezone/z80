[![Language](https://img.shields.io/badge/language-Swift-orange.svg)](https://swift.org)
<!-- [![codecov](https://codecov.io/gh/timsneath/z80/branch/main/graph/badge.svg?token=zr4wE5pmay)](https://codecov.io/gh/timsneath/z80) -->

A fully functional Zilog Z80 microprocessor emulator written in Swift.
Originally intended for use with Cambridge, a ZX Spectrum emulator
(<https://github.com/timsneath/cambridge>).

The Swift version of the emulator passes the comprehensive FUSE test
suite, which contains 1356 tests that evaluate the correctness of both
documented and undocumented instructions. It also passes `ZEXDOC`
(sometimes referred to as `zexlax` test suite).

Not all undocumented registers or flags are implemented (e.g. the `W` register
is not implemented).

The emulator itself is licensed under the MIT license (see LICENSE).
