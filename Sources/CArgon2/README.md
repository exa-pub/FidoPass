# CArgon2

The Argon2 reference implementation, vendored from
https://github.com/P-H-C/phc-winner-argon2 at commit `f57e61e19229e23c4445b85494dbf7c07de721cb`
(2021-06-25), unmodified. Licensed CC0-1.0 or Apache-2.0 at your option — see `LICENSE`.

Only the portable `ref.c` back end is included (`opt.c` is x86 SIMD), and the build defines
`ARGON2_NO_THREADS`: FidoPass always runs argon2id with a single lane, so `thread.c` is not
needed. `import CArgon2` is allowed in exactly one file, `FidoPassCore/Support/Argon2.swift`.
