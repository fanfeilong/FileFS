# Kotlin FileFS

Pure Kotlin/JVM FileFS port for the shared 512-byte block image format used by the other language ports in this repository.

## Layout

- `src/main/kotlin/filefs/` - public API and implementation
- `src/main/kotlin/filefs/internal/` - image-format helpers and tree serializer/parser
- `src/test/kotlin/filefs/` - executable regression tests
- `build.sh` - one-command compile and test runner

## Requirements

- Kotlin compiler: `/usr/local/bin/kotlinc`
- Java 21

## Run tests

```bash
cd /workspace/kotlin
./build.sh
```

The script compiles the main sources and tests into a single runnable jar, then executes the six regression scenarios that mirror the existing ports.
