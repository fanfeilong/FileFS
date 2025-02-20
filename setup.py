from setuptools import setup, Extension
import os

# 编译和安装命令:
# python setup.py build     # 编译
# python setup.py install   # 安装到系统
# python setup.py develop   # 开发模式安装
# python setup.py sdist     # 创建源代码分发包
# python setup.py bdist_wheel  # 创建wheel分发包
# pip install .            # 从当前目录安装
# pip install -e .         # 以可编辑模式安装

# 定义 C++ 扩展模块
filefs_module = Extension(
    'filefs._filefs',  # 生成的模块名称
    sources=['FileFS.c', 'bindings/python/filefs/binding.c'],
    include_dirs=['.', './include'],  # 包含头文件目录
    language='c',  # Changed to 'c' since source files are .c
    extra_compile_args=['-std=c11']  # Ensure C11 standard is used
)

setup(
    name='filefs',
    version='0.1.0',
    packages=['filefs'],
    package_dir={'': 'bindings/python'},
    ext_modules=[filefs_module],
    author='Your Name',
    author_email='your.email@example.com',
    description='A file system implementation in C++ with Python bindings',
    long_description=open('README.md').read() if os.path.exists('README.md') else '',
    long_description_content_type='text/markdown',
    url='https://github.com/yourusername/filefs',
    classifiers=[
        'Development Status :: 3 - Alpha',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: MIT License',
        'Programming Language :: Python :: 3',
        'Programming Language :: C++',
    ],
    python_requires='>=3.6',
)