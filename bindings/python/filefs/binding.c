#include <Python.h>
#include "FileFS.h"  // Include the FileFS header file

// Helper function to convert Python string to C string
static const char* get_string_arg(PyObject* arg) {
    if (!PyUnicode_Check(arg)) {
        PyErr_SetString(PyExc_TypeError, "Expected string argument");
        return NULL;
    }
    return PyUnicode_AsUTF8(arg);
}

// Wrapper functions
static PyObject* _create(PyObject* self) {
    FileFS* ffs = FileFS_create();
    return PyCapsule_New(ffs, "FileFS", NULL);
}

static PyObject* _destroy(PyObject* self, PyObject* args) {
    PyObject* capsule;
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FileFS_destroy(ffs);
    Py_RETURN_NONE;
}

static PyObject* _mkfs(PyObject* self, PyObject* args) {
    const char* filename;
    if (!PyArg_ParseTuple(args, "s", &filename))
        return NULL;
    
    unsigned char result = FileFS_mkfs(filename);
    return PyBool_FromLong(result);
}

static PyObject* _mount(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* filename;
    if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_mount(ffs, filename);
    return PyBool_FromLong(result);
}


static PyObject* _umount(PyObject* self, PyObject* args) {
    PyObject* capsule;
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FileFS_umount(ffs);
    Py_RETURN_NONE;
}
static PyObject* _ismount(PyObject* self, PyObject* args) {
    PyObject* capsule;
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_ismount(ffs);
    return PyBool_FromLong(result);
}
static PyObject* _fopen(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* filename;
    const char* mode;
    if (!PyArg_ParseTuple(args, "Oss", &capsule, &filename, &mode))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = FileFS_fopen(ffs, filename, mode);
    if (!file) {
        Py_RETURN_NONE;
    }
    return PyCapsule_New(file, "FFS_FILE", NULL);
}
static PyObject* _fread(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    Py_ssize_t size;
    Py_ssize_t nmemb;
    
    if (!PyArg_ParseTuple(args, "Onn0", &capsule, &size, &nmemb, &file_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    void* buffer = malloc(size * nmemb);
    if (!buffer) {
        PyErr_SetString(PyExc_MemoryError, "Failed to allocate memory");
        return NULL;
    }
    
    size_t read = FileFS_fread(ffs, buffer, size, nmemb, file);
    PyObject* result = PyBytes_FromStringAndSize(buffer, read * size);
    free(buffer);
    
    return result;
}
static PyObject* _fwrite(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    Py_buffer buffer;
    Py_ssize_t size;
    Py_ssize_t nmemb;
    
    if (!PyArg_ParseTuple(args, "Oy*nnO", &capsule, &buffer, &size, &nmemb, &file_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    size_t written = FileFS_fwrite(ffs, buffer.buf, size, nmemb, file);
    PyBuffer_Release(&buffer);
    
    return PyLong_FromSize_t(written);
}
static PyObject* _fclose(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    
    if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    FileFS_fclose(ffs, file);
    Py_RETURN_NONE;
}
static PyObject* _fseek(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    long long offset;
    int whence;
    
    if (!PyArg_ParseTuple(args, "OOLi", &capsule, &file_capsule, &offset, &whence))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    unsigned char result = FileFS_fseek(ffs, file, offset, whence);
    return PyBool_FromLong(result);
}
static PyObject* _ftell(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    
    if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    unsigned long long position = FileFS_ftell(ffs, file);
    return PyLong_FromUnsignedLongLong(position);
}
static PyObject* _rewind(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* file_capsule;
    
    if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_FILE* file = (FFS_FILE*)PyCapsule_GetPointer(file_capsule, "FFS_FILE");
    
    FileFS_rewind(ffs, file);
    Py_RETURN_NONE;
}
static PyObject* _file_exist(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* filename;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_file_exist(ffs, filename);
    return PyBool_FromLong(result);
}
static PyObject* _dir_exist(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* pathname;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_dir_exist(ffs, pathname);
    return PyBool_FromLong(result);
}
static PyObject* _remove(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* filename;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_remove(ffs, filename);
    return PyLong_FromLong(result);
}
static PyObject* _rename(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* old_name;
    const char* new_name;
    
    if (!PyArg_ParseTuple(args, "Oss", &capsule, &old_name, &new_name))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_rename(ffs, old_name, new_name);
    return PyLong_FromLong(result);
}
static PyObject* _move(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* from_name;
    const char* to_path;
    
    if (!PyArg_ParseTuple(args, "Oss", &capsule, &from_name, &to_path))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_move(ffs, from_name, to_path);
    return PyLong_FromLong(result);
}
static PyObject* _copy(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* from_filename;
    const char* to_filename;
    
    if (!PyArg_ParseTuple(args, "Oss", &capsule, &from_filename, &to_filename))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_copy(ffs, from_filename, to_filename);
    return PyLong_FromLong(result);
}
static PyObject* _chdir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* pathname;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_chdir(ffs, pathname);
    return PyBool_FromLong(result);
}
static PyObject* _getcwd(PyObject* self, PyObject* args) {
    PyObject* capsule;
    
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    char* cwd = FileFS_getcwd(ffs);
    if (!cwd) {
        Py_RETURN_NONE;
    }
    PyObject* result = PyUnicode_FromString(cwd);
    free(cwd);  // Free the C string after converting to Python string
    return result;
}
static PyObject* _mkdir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* pathname;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_mkdir(ffs, pathname);
    return PyLong_FromLong(result);
}
static PyObject* _rmdir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* pathname;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    int result = FileFS_rmdir(ffs, pathname);
    return PyLong_FromLong(result);
}
static PyObject* _opendir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    const char* path;
    
    if (!PyArg_ParseTuple(args, "Os", &capsule, &path))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    char* absolute_path = NULL;
    FFS_DIR* dir = FileFS_opendir(ffs, path, &absolute_path);
    
    if (!dir) {
        if (absolute_path) free(absolute_path);
        Py_RETURN_NONE;
    }

    PyObject* result = PyCapsule_New(dir, "FFS_DIR", NULL);
    if (absolute_path) free(absolute_path);
    return result;
}

static PyObject* _readdir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* dir_capsule;
    
    if (!PyArg_ParseTuple(args, "OO", &capsule, &dir_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_DIR* dir = (FFS_DIR*)PyCapsule_GetPointer(dir_capsule, "FFS_DIR");
    
    FFS_dirent* entry = FileFS_readdir(ffs, dir);
    if (!entry) {
        Py_RETURN_NONE;
    }

    // Create a dictionary with the directory entry information
    PyObject* dict = PyDict_New();
    PyDict_SetItemString(dict, "name", PyUnicode_FromString(entry->d_name));
    PyDict_SetItemString(dict, "type", PyLong_FromLong(entry->d_type));
    PyDict_SetItemString(dict, "namlen", PyLong_FromSize_t(entry->d_namlen));
    
    return dict;
}

static PyObject* _closedir(PyObject* self, PyObject* args) {
    PyObject* capsule;
    PyObject* dir_capsule;
    
    if (!PyArg_ParseTuple(args, "OO", &capsule, &dir_capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FFS_DIR* dir = (FFS_DIR*)PyCapsule_GetPointer(dir_capsule, "FFS_DIR");
    
    FileFS_closedir(ffs, dir);
    Py_RETURN_NONE;
}


static PyObject* _begin(PyObject* self, PyObject* args) {
    PyObject* capsule;
    
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_begin(ffs);
    return PyBool_FromLong(result);
}

static PyObject* _commit(PyObject* self, PyObject* args) {
    PyObject* capsule;
    
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    unsigned char result = FileFS_commit(ffs);
    return PyBool_FromLong(result);
}

static PyObject* _rollback(PyObject* self, PyObject* args) {
    PyObject* capsule;
    
    if (!PyArg_ParseTuple(args, "O", &capsule))
        return NULL;
    
    FileFS* ffs = (FileFS*)PyCapsule_GetPointer(capsule, "FileFS");
    FileFS_rollback(ffs);
    Py_RETURN_NONE;
}



static PyMethodDef methods[] = {
    {"create", (PyCFunction)_create, METH_NOARGS, "Create a new FileFS instance"},
    {"destroy", _destroy, METH_VARARGS, "Destroy a FileFS instance"},
    {"mkfs", _mkfs, METH_VARARGS, "Create a new filesystem"},
    {"mount", _mount, METH_VARARGS, "Mount a filesystem"},
    {"umount", _umount, METH_VARARGS, "Unmount a filesystem"},
    {"ismount", _ismount, METH_VARARGS, "Check if filesystem is mounted"},
    {"fopen", _fopen, METH_VARARGS, "Open a file"},
    {"fread", _fread, METH_VARARGS, "Read from a file"},
    {"fwrite", _fwrite, METH_VARARGS, "Write to a file"},
    {"fclose", _fclose, METH_VARARGS, "Close a file"},
    {"fseek", _fseek, METH_VARARGS, "Seek in a file"},
    {"ftell", _ftell, METH_VARARGS, "Get current position in file"},
    {"rewind", _rewind, METH_VARARGS, "Rewind file position"},
    {"file_exist", _file_exist, METH_VARARGS, "Check if file exists"},
    {"dir_exist", _dir_exist, METH_VARARGS, "Check if directory exists"},
    {"remove", _remove, METH_VARARGS, "Remove a file"},
    {"rename", _rename, METH_VARARGS, "Rename a file"},
    {"move", _move, METH_VARARGS, "Move a file"},
    {"copy", _copy, METH_VARARGS, "Copy a file"},
    {"chdir", _chdir, METH_VARARGS, "Change current directory"},
    {"getcwd", _getcwd, METH_VARARGS, "Get current working directory"},
    {"mkdir", _mkdir, METH_VARARGS, "Create a directory"},
    {"rmdir", _rmdir, METH_VARARGS, "Remove a directory"},
    {"opendir", _opendir, METH_VARARGS, "Open a directory"},
    {"readdir", _readdir, METH_VARARGS, "Read directory entry"},
    {"closedir", _closedir, METH_VARARGS, "Close a directory"},
    {"begin", _begin, METH_VARARGS, "Begin a transaction"},
    {"commit", _commit, METH_VARARGS, "Commit a transaction"},
    {"rollback", _rollback, METH_VARARGS, "Rollback a transaction"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT,
    "_filefs",
    "Python bindings for FileFS",
    -1,
    methods
};

PyMODINIT_FUNC PyInit__filefs(void) {
    PyObject *m = PyModule_Create(&module);
    if (m == NULL) return NULL;
    
    // Add constants
    PyModule_AddIntConstant(m, "DT_FILE", FFS_DT_FILE);
    PyModule_AddIntConstant(m, "DT_DIR", FFS_DT_DIR);
    PyModule_AddIntConstant(m, "DT_ROOT", FFS_DT_ROOT);
    PyModule_AddIntConstant(m, "SEEK_CUR", FFS_SEEK_CUR);
    PyModule_AddIntConstant(m, "SEEK_END", FFS_SEEK_END);
    PyModule_AddIntConstant(m, "SEEK_SET", FFS_SEEK_SET);
    
    return m;
}
