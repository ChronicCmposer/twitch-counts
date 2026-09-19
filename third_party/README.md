# third_party — vendored sources for twitch-counts-full

`twitch-counts-full` is hand-written ARMv8-a assembly statically linked
against musl libc plus three vendored C libraries: **tomlc99** (TOML
parsing), the **SQLite amalgamation** (rollup cache), and **PCRE2-8**
(regex).  All C is compiled with the musl toolchain so the final binary has
zero glibc dependency.

## Layout

| Path | What | License | In git? |
|------|------|---------|---------|
| `musl/` | built musl toolchain (install prefix) | MIT | no (build product) |
| `musl-1.2.6/` | musl source tree (fetched by the Makefile bootstrap rule) | MIT | no |
| `musl-1.2.6.tar.gz` | musl release tarball | MIT | no |
| `tomlc99/toml.c`, `tomlc99/toml.h`, `tomlc99/LICENSE` | tomlc99 sources | MIT | **yes** |
| `sqlite3/sqlite3.c`, `sqlite3/sqlite3.h`, `sqlite3ext.h` | SQLite amalgamation | Public Domain | **yes** |
| `pcre2-10.48/` | pcre2 source tree (fetched by the Makefile bootstrap rule) | BSD-3-Clause | no |
| `pcre2/install/` | built pcre2 (install prefix, contains `lib/libpcre2-8.a`) | BSD-3-Clause | no (build product) |
| `pcre2-10.48.tar.gz` | pcre2 release tarball | BSD-3-Clause | no |
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
  (BSD-3-Clause).  Built with:
  ```
  ./configure --prefix=$PWD/../pcre2/install --disable-shared --enable-static CC=<musl-gcc>
  make -j && make install
  ```
  We link `pcre2/install/lib/libpcre2-8.a`.

## Build commands

From the repository root, `make all`:
1. bootstraps the musl toolchain (`third_party/musl/bin/musl-gcc`) on first
   use — fetching the musl tarball above if it is not already present;
2. fetches and builds pcre2-10.48 the same way;
3. compiles the vendored C with `$(MUSL_GCC)`;
4. links with:
   ```
   $(MUSL_GCC) -static -o twitch-counts-full tc_entry.o \
       third_party/tomlc99/toml.o third_party/sqlite3/sqlite3.o \
       third_party/pcre2/install/lib/libpcre2-8.a
   ```

`make third-party` builds only the library objects/archives.

## Notes for later phases

- `MUSL_GCC` in the Makefile is `$(abspath third_party/musl/bin/musl-gcc)`.
- The sqlite3/toml `.o` files are build artifacts (git-ignored); only the
  sources are committed.
- glibc-built `.a` files on this host (`/usr/lib/aarch64-linux-gnu/…`) are
  NOT usable — everything must be built with the musl toolchain.
- `libpcre2-8.a` lives at `third_party/pcre2/install/lib/libpcre2-8.a`.
- `make clean` removes binaries, object files and `pcre2/install/` but keeps
  the musl toolchain (rebuilding it takes a few minutes; it is a shared
  toolchain, not a project artifact).  To rebuild the toolchain from
  scratch: `rm -rf third_party/musl && make all`.