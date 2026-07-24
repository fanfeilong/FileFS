# FileFS

FileFS: Implement a virtual file system within a single file.

## Layout

```
.
├── bench/      # Cross-language full-API benchmark harness + matrix
├── c/          # C implementation (original)
├── cpp/        # Pure C++20 port
├── dotnet/     # Pure C# / .NET port
├── go/         # Pure-Go port
├── java/       # Pure Java 21 port
├── kotlin/     # Pure Kotlin/JVM port
├── lua/        # Pure Lua 5.4 port
├── moonbit/    # Pure MoonBit port
├── nodejs/     # Pure JavaScript ESM port
├── python/     # Python package (CPython bindings to c/)
├── rust/       # Pure-Rust port
├── swift/      # Pure Swift port
├── wasm/       # WebAssembly (Zig) + JS glue (in-memory image)
├── zig/        # Pure-Zig port
├── LICENSE
└── README.md
```

## C

```bash
cd c
make
./demo
```

See [c/README.md](c/README.md).

## C++

```bash
cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build -j
ctest --test-dir cpp/build --output-on-failure
```

See [cpp/README.md](cpp/README.md).

## .NET

```bash
cd dotnet
dotnet test
```

See [dotnet/README.md](dotnet/README.md).

## Go

```bash
cd go
go build -o demo ./cmd/demo
./demo
```

See [go/README.md](go/README.md).

## Java

```bash
mvn -f java/pom.xml test
```

See [java/README.md](java/README.md).

## Kotlin

```bash
cd kotlin
./build.sh
```

See [kotlin/README.md](kotlin/README.md).

## Lua

```bash
cd lua
lua5.4 tests/run_tests.lua
```

See [lua/README.md](lua/README.md).

## MoonBit

```bash
cd moonbit
moon test
```

See [moonbit/README.md](moonbit/README.md).

## Node.js

```bash
cd nodejs
npm test
```

See [nodejs/README.md](nodejs/README.md).

## Python

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python -m unittest discover -s tests -v
```

See [python/README.md](python/README.md).

## Rust

```bash
cd rust
cargo test
```

See [rust/README.md](rust/README.md).

## Swift

```bash
cd swift
swift test
```

See [swift/README.md](swift/README.md).

## WebAssembly

```bash
cd wasm
zig build
npm test
```

In-memory FileFS image for browser/Node via Zig `wasm32-freestanding` + JS glue.  
See [wasm/README.md](wasm/README.md).

## Zig

```bash
cd zig
zig build test
```

See [zig/README.md](zig/README.md).

Host language ports share the same on-disk format (512-byte blocks, magic `78 11 45 14`).  
The Wasm port uses the same block layout in an in-memory image suitable for browsers.

## Performance matrix

<!-- BENCH_MATRIX_BEGIN -->

Cross-language full-API microbenchmarks (`ns/op`, lower is better).
Workload: `filefs-full-api` · iterations=20 · payload=4096 bytes.
Cell colors are **row-relative** (green = faster for that API among measured ports, red = slower).

![FileFS benchmark matrix](bench/matrix.svg)

<details><summary>Numeric matrix (HTML)</summary>

<table>
<thead><tr>
<th bgcolor="#2c3e50"><font color="#ecf0f1">API \ Lang</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">c</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">go</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">lua</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">nodejs</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">python</font></th>
<th bgcolor="#2c3e50"><font color="#ecf0f1">rust</font></th>
</tr></thead><tbody>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">mkfs</font></th>
<td bgcolor="#e67e22" title="c / mkfs: 560156 ns/op" align="right"><code>560.2µs</code></td>
<td bgcolor="#c0392b" title="go / mkfs: 846767 ns/op" align="right"><code>846.8µs</code></td>
<td bgcolor="#1b7f4e" title="lua / mkfs: 97000 ns/op" align="right"><code>97.0µs</code></td>
<td bgcolor="#f5b041" title="nodejs / mkfs: 246001 ns/op" align="right"><code>246.0µs</code></td>
<td bgcolor="#c7e89a" title="python / mkfs: 227997 ns/op" align="right"><code>228.0µs</code></td>
<td bgcolor="#57a773" title="rust / mkfs: 222264 ns/op" align="right"><code>222.3µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">mount+umount</font></th>
<td bgcolor="#57a773" title="c / mount_umount: 3202 ns/op" align="right"><code>3.2µs</code></td>
<td bgcolor="#f5b041" title="go / mount_umount: 5010 ns/op" align="right"><code>5.0µs</code></td>
<td bgcolor="#c0392b" title="lua / mount_umount: 94000 ns/op" align="right"><code>94.0µs</code></td>
<td bgcolor="#e67e22" title="nodejs / mount_umount: 11779 ns/op" align="right"><code>11.8µs</code></td>
<td bgcolor="#c7e89a" title="python / mount_umount: 3823 ns/op" align="right"><code>3.8µs</code></td>
<td bgcolor="#1b7f4e" title="rust / mount_umount: 3056 ns/op" align="right"><code>3.1µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">mkdir</font></th>
<td bgcolor="#57a773" title="c / mkdir: 366485 ns/op" align="right"><code>366.5µs</code></td>
<td bgcolor="#f5b041" title="go / mkdir: 504670 ns/op" align="right"><code>504.7µs</code></td>
<td bgcolor="#c0392b" title="lua / mkdir: 49491500 ns/op" align="right"><code>49.49ms</code></td>
<td bgcolor="#e67e22" title="nodejs / mkdir: 890233 ns/op" align="right"><code>890.2µs</code></td>
<td bgcolor="#1b7f4e" title="python / mkdir: 340322 ns/op" align="right"><code>340.3µs</code></td>
<td bgcolor="#c7e89a" title="rust / mkdir: 437640 ns/op" align="right"><code>437.6µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">chdir+getcwd</font></th>
<td bgcolor="#1b7f4e" title="c / chdir_getcwd: 1014 ns/op" align="right"><code>1.0µs</code></td>
<td bgcolor="#f5b041" title="go / chdir_getcwd: 1958 ns/op" align="right"><code>2.0µs</code></td>
<td bgcolor="#e67e22" title="lua / chdir_getcwd: 2000 ns/op" align="right"><code>2.0µs</code></td>
<td bgcolor="#c0392b" title="nodejs / chdir_getcwd: 26283 ns/op" align="right"><code>26.3µs</code></td>
<td bgcolor="#c7e89a" title="python / chdir_getcwd: 1537 ns/op" align="right"><code>1.5µs</code></td>
<td bgcolor="#57a773" title="rust / chdir_getcwd: 1181 ns/op" align="right"><code>1.2µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">open(w)+close</font></th>
<td bgcolor="#1b7f4e" title="c / open_write_close: 253513 ns/op" align="right"><code>253.5µs</code></td>
<td bgcolor="#f5b041" title="go / open_write_close: 398876 ns/op" align="right"><code>398.9µs</code></td>
<td bgcolor="#c0392b" title="lua / open_write_close: 94507500 ns/op" align="right"><code>94.51ms</code></td>
<td bgcolor="#e67e22" title="nodejs / open_write_close: 740912 ns/op" align="right"><code>740.9µs</code></td>
<td bgcolor="#57a773" title="python / open_write_close: 254674 ns/op" align="right"><code>254.7µs</code></td>
<td bgcolor="#c7e89a" title="rust / open_write_close: 356582 ns/op" align="right"><code>356.6µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">write 4KiB</font></th>
<td bgcolor="#57a773" title="c / write_4kib: 596540 ns/op" align="right"><code>596.5µs</code></td>
<td bgcolor="#f5b041" title="go / write_4kib: 943380 ns/op" align="right"><code>943.4µs</code></td>
<td bgcolor="#c0392b" title="lua / write_4kib: 342861500 ns/op" align="right"><code>342.86ms</code></td>
<td bgcolor="#e67e22" title="nodejs / write_4kib: 1820865 ns/op" align="right"><code>1.82ms</code></td>
<td bgcolor="#1b7f4e" title="python / write_4kib: 574859 ns/op" align="right"><code>574.9µs</code></td>
<td bgcolor="#c7e89a" title="rust / write_4kib: 823546 ns/op" align="right"><code>823.5µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">read 4KiB</font></th>
<td bgcolor="#1b7f4e" title="c / read_4kib: 3266 ns/op" align="right"><code>3.3µs</code></td>
<td bgcolor="#f5b041" title="go / read_4kib: 10200 ns/op" align="right"><code>10.2µs</code></td>
<td bgcolor="#c0392b" title="lua / read_4kib: 79000 ns/op" align="right"><code>79.0µs</code></td>
<td bgcolor="#e67e22" title="nodejs / read_4kib: 28866 ns/op" align="right"><code>28.9µs</code></td>
<td bgcolor="#57a773" title="python / read_4kib: 4231 ns/op" align="right"><code>4.2µs</code></td>
<td bgcolor="#c7e89a" title="rust / read_4kib: 6262 ns/op" align="right"><code>6.3µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">seek+tell+rewind</font></th>
<td bgcolor="#57a773" title="c / seek_tell_rewind: 3050 ns/op" align="right"><code>3.0µs</code></td>
<td bgcolor="#f5b041" title="go / seek_tell_rewind: 9290 ns/op" align="right"><code>9.3µs</code></td>
<td bgcolor="#1b7f4e" title="lua / seek_tell_rewind: 2000 ns/op" align="right"><code>2.0µs</code></td>
<td bgcolor="#c0392b" title="nodejs / seek_tell_rewind: 48958 ns/op" align="right"><code>49.0µs</code></td>
<td bgcolor="#c7e89a" title="python / seek_tell_rewind: 3894 ns/op" align="right"><code>3.9µs</code></td>
<td bgcolor="#e67e22" title="rust / seek_tell_rewind: 13494 ns/op" align="right"><code>13.5µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">copy_file</font></th>
<td bgcolor="#57a773" title="c / copy_file: 592318 ns/op" align="right"><code>592.3µs</code></td>
<td bgcolor="#c7e89a" title="go / copy_file: 897706 ns/op" align="right"><code>897.7µs</code></td>
<td bgcolor="#c0392b" title="lua / copy_file: 373428000 ns/op" align="right"><code>373.43ms</code></td>
<td bgcolor="#e67e22" title="nodejs / copy_file: 2852616 ns/op" align="right"><code>2.85ms</code></td>
<td bgcolor="#1b7f4e" title="python / copy_file: 570060 ns/op" align="right"><code>570.1µs</code></td>
<td bgcolor="#f5b041" title="rust / copy_file: 984406 ns/op" align="right"><code>984.4µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">rename</font></th>
<td bgcolor="#1b7f4e" title="c / rename: 33150 ns/op" align="right"><code>33.1µs</code></td>
<td bgcolor="#e67e22" title="go / rename: 1864782 ns/op" align="right"><code>1.86ms</code></td>
<td bgcolor="#c0392b" title="lua / rename: 601521500 ns/op" align="right"><code>601.52ms</code></td>
<td bgcolor="#f5b041" title="nodejs / rename: 1678255 ns/op" align="right"><code>1.68ms</code></td>
<td bgcolor="#57a773" title="python / rename: 815150 ns/op" align="right"><code>815.1µs</code></td>
<td bgcolor="#c7e89a" title="rust / rename: 1146432 ns/op" align="right"><code>1.15ms</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">remove_file</font></th>
<td bgcolor="#1b7f4e" title="c / remove_file: 257132 ns/op" align="right"><code>257.1µs</code></td>
<td bgcolor="#f5b041" title="go / remove_file: 802108 ns/op" align="right"><code>802.1µs</code></td>
<td bgcolor="#c0392b" title="lua / remove_file: 404070500 ns/op" align="right"><code>404.07ms</code></td>
<td bgcolor="#e67e22" title="nodejs / remove_file: 1348636 ns/op" align="right"><code>1.35ms</code></td>
<td bgcolor="#57a773" title="python / remove_file: 502216 ns/op" align="right"><code>502.2µs</code></td>
<td bgcolor="#c7e89a" title="rust / remove_file: 773766 ns/op" align="right"><code>773.8µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">opendir+readdir</font></th>
<td bgcolor="#1b7f4e" title="c / readdir: 2629 ns/op" align="right"><code>2.6µs</code></td>
<td bgcolor="#57a773" title="go / readdir: 2970 ns/op" align="right"><code>3.0µs</code></td>
<td bgcolor="#f5b041" title="lua / readdir: 14000 ns/op" align="right"><code>14.0µs</code></td>
<td bgcolor="#c0392b" title="nodejs / readdir: 26531 ns/op" align="right"><code>26.5µs</code></td>
<td bgcolor="#e67e22" title="python / readdir: 14096 ns/op" align="right"><code>14.1µs</code></td>
<td bgcolor="#c7e89a" title="rust / readdir: 3558 ns/op" align="right"><code>3.6µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">file/dir exists</font></th>
<td bgcolor="#57a773" title="c / exists: 2670 ns/op" align="right"><code>2.7µs</code></td>
<td bgcolor="#e67e22" title="go / exists: 4678 ns/op" align="right"><code>4.7µs</code></td>
<td bgcolor="#1b7f4e" title="lua / exists: 2000 ns/op" align="right"><code>2.0µs</code></td>
<td bgcolor="#c0392b" title="nodejs / exists: 20969 ns/op" align="right"><code>21.0µs</code></td>
<td bgcolor="#f5b041" title="python / exists: 3024 ns/op" align="right"><code>3.0µs</code></td>
<td bgcolor="#c7e89a" title="rust / exists: 2719 ns/op" align="right"><code>2.7µs</code></td>
</tr>
</tbody></table>
<tr>
<th bgcolor="#34495e"><font color="#ecf0f1">begin+write+commit</font></th>
<td bgcolor="#1b7f4e" title="c / txn_commit: 218426 ns/op" align="right"><code>218.4µs</code></td>
<td bgcolor="#c7e89a" title="go / txn_commit: 459015 ns/op" align="right"><code>459.0µs</code></td>
<td bgcolor="#c0392b" title="lua / txn_commit: 322930500 ns/op" align="right"><code>322.93ms</code></td>
<td bgcolor="#e67e22" title="nodejs / txn_commit: 675432 ns/op" align="right"><code>675.4µs</code></td>
<td bgcolor="#57a773" title="python / txn_commit: 339124 ns/op" align="right"><code>339.1µs</code></td>
<td bgcolor="#f5b041" title="rust / txn_commit: 473641 ns/op" align="right"><code>473.6µs</code></td>
</tr>
</tbody></table>

</details>

Regenerate:

```bash
python3 bench/run_all.py
```

Raw results: [`bench/results/latest.json`](bench/results/latest.json) · unix=1784875412.
Harness details: [`bench/README.md`](bench/README.md).
<!-- BENCH_MATRIX_END -->
