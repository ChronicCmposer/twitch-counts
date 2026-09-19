# third_party — vendored sources for twitch-counts-full

`twitch-counts-full` is hand-written ARMv8-a assembly linked against libc
plus three vendored C libraries: **tomlc99** (TOML parsing), the **SQLite
amalgamation** (rollup cache), and **PCRE2-8** (regex).  It builds on two
platforms from the same sources (see `tc_platform.h`):

- **Linux**: statically linked against musl; all C is compiled with the musl
  toolchain so the final binary has zero glibc dependency.
- **macOS arm64**: a Mach-O binary dynamically linked against libSystem
  (Apple ships no static libc); all C is compiled with Apple clang.

Per-platform build products live under `build/<os>/` (`build/linux`,
`build/darwin`), never in the source tree, so a checkout shared between a
Mac and a Linux VM never mixes the two.

## Layout

| Path | What | License | In git? |
|------|------|---------|---------|
| `musl/` | built musl toolchain (install prefix) | MIT | no (build product) |
| `musl-1.2.6/` | musl source tree (fetched by the Makefile bootstrap rule) | MIT | no |
| `musl-1.2.6.tar.gz` | musl release tarball | MIT | no |
| `tomlc99/toml.c`, `tomlc99/toml.h`, `tomlc99/LICENSE` | tomlc99 sources | MIT | **yes** |
| `sqlite3/sqlite3.c`, `sqlite3/sqlite3.h`, `sqlite3ext.h` | SQLite amalgamation | Public Domain | **yes** |
| `pcre2-10.48.tar.gz` | pcre2 release tarball (fetched by the Makefile) | BSD-3-Clause | no |
| `../build/<os>/pcre2-10.48/` | pcre2 source, extracted and built per platform | BSD-3-Clause | no (build product) |
| `../build/<os>/pcre2/lib/libpcre2-8.a` | the static library we link | BSD-3-Clause | no (build product) |
| `sqlite-amalgamation.zip` | SQLite amalgamation zip | Public Domain | no |
| `LICENSE.tomlc99` | MIT text for tomlc99 | MIT | **yes** |

## Sources and versions

- **musl 1.2.6** — <https://musl.libc.org/releases/musl-1.2.6.tar.gz> (MIT)
  Built with:
  ```
  ./configure --prefix=$PWD/../musl --syslibdir=$PWD/../musl/lib
  make -j && make install
  ```
  No root needed.  `--syslibdir` inside the prefix is important: it puts the
  dynamic linker (`ld-musl-aarch64.so.1`) in our own tree so that
  `musl-gcc`'s default (dynamically linked) test binaries are runnable —
  configure scripts such as pcre2's need to execute test programs.  The
  final twitch-counts-full link uses `-static` regardless.
- **tomlc99** (master, fetched 2026-09-18) — <https://github.com/cktan/tomlc99>
  Raw `toml.c` + `toml.h` from master (MIT).  Compiled with
  `musl-gcc -std=c99 -c toml.c -o toml.o`.
- **SQLite amalgamation 3.46.1** (3460100) —
  <https://sqlite.org/2024/sqlite-amalgamation-3460100.zip> (public domain).
  Compiled with `musl-gcc -O2 -DSQLITE_THREADSAFE=1 -c sqlite3.c -o sqlite3.o`.
- **pcre2 10.48** —
  <https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz>
  (BSD-3-Clause).  Extracted into `build/<os>/` and built with the
  platform compiler (`<musl-gcc>` on Linux, `clang` on macOS):
  ```
  ./configure --disable-shared --enable-static CC=<cc>
  make -j libpcre2-8.la
  ```
  We link `build/<os>/pcre2/lib/libpcre2-8.a` (JIT off, Unicode on on both
  platforms; the assembly passes no pcre2 option bits).

## Build commands

From the repository root, `make twitch-counts-full` (or `make all`):
1. on Linux, bootstraps the musl toolchain (`third_party/musl/bin/musl-gcc`)
   on first use — fetching the musl tarball above if it is not already
   present; on macOS the toolchain is Apple clang;
2. fetches the pcre2 tarball if needed and builds `libpcre2-8.a` under
   `build/<os>/` with the platform compiler;
3. compiles the vendored C into `build/<os>/toml.o` and
   `build/<os>/sqlite3.o`;
4. assembles the `tc_*.S` modules (through the C preprocessor) and links:
   ```
   Linux:  $(MUSL_GCC) -static -o build/linux/twitch-counts-full <objects> \
               build/linux/toml.o build/linux/sqlite3.o build/linux/pcre2/lib/libpcre2-8.a
   macOS:  clang -o build/darwin/twitch-counts-full <objects> \
               build/darwin/toml.o build/darwin/sqlite3.o build/darwin/pcre2/lib/libpcre2-8.a
   ```
   and copies the result to `./twitch-counts-full`.

`make third-party` builds only the library objects/archives.

## Notes

- `MUSL_GCC` in the Makefile is `$(abspath third_party/musl/bin/musl-gcc)`.
- The sqlite3/toml `.o` files are build artifacts (git-ignored); only the
  sources are committed.
- On Linux, glibc-built `.a` files on the host (`/usr/lib/aarch64-linux-gnu/…`)
  are NOT usable — everything must be built with the musl toolchain.  On
  macOS, never link the libraries with `-l`: that silently binds Apple's
  older system sqlite (3.51) or pcre2 (10.42), or a Homebrew dylib; the
  Makefile names the static archives by path.
- `make clean` removes `build/` and the root binaries but keeps the musl
  toolchain (rebuilding it takes a few minutes; it is a shared toolchain,
  not a project artifact).  To rebuild the toolchain from scratch:
  `rm -rf third_party/musl && make all`.