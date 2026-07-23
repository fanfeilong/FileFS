# FileFS (Python)

Python standard package wrapping the C FileFS implementation in [`../c/`](../c/).

## Layout

```
python/
  filefs/
    __init__.py   # public API
    binding.c     # CPython extension
    py.typed
  tests/
    test_filefs.py
  setup.py
  pyproject.toml
  README.md
```

## Install

From the repository root (needs the sibling `c/` sources):

```bash
cd python
pip install -e .
```

## Test

```bash
cd python
python -m unittest discover -s tests -v
```

## API sketch

```python
import filefs

ffs = filefs.create()
filefs.mkfs("demo.ffs")
filefs.mount(ffs, "demo.ffs")

f = filefs.fopen(ffs, "/hello.txt", "w")
filefs.fwrite(ffs, b"hi", 1, 2, f)
filefs.fclose(ffs, f)

filefs.umount(ffs)
filefs.destroy(ffs)
```

`opendir` returns `(dir_handle, absolute_path)`.
