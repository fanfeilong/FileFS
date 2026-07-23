from pathlib import Path

from setuptools import Extension, setup

ROOT = Path(__file__).resolve().parent
# setuptools requires sources/include_dirs relative to setup.py
C_DIR = Path("..") / "c"

ext_modules = [
    Extension(
        "filefs._filefs",
        sources=[
            str(C_DIR / "FileFS.c"),
            str(Path("filefs") / "binding.c"),
        ],
        include_dirs=[str(C_DIR)],
        language="c",
        extra_compile_args=["-std=c11"],
    )
]

setup(
    name="filefs",
    version="0.1.0",
    description="Python bindings for FileFS (C virtual filesystem in a single file)",
    long_description=(ROOT / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    packages=["filefs"],
    package_data={"filefs": ["py.typed"]},
    ext_modules=ext_modules,
    python_requires=">=3.8",
    zip_safe=False,
)
