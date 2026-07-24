# Swift FileFS bench runner

The Swift benchmark lives inside the language package so SwiftPM can link it:

- sources: `swift/Sources/FileFsBench/main.swift`
- run via: `python3 -m bench.run_all --only swift`

(or `cd swift && swift run -c release FileFsBench <iters> <warmup>`)
